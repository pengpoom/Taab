import Cocoa

private extension NSPasteboard.PasteboardType {
    static let glideSidebarPinnedApp = NSPasteboard.PasteboardType(
        "com.pengxiangyang.Glide.sidebar-pinned-app")
}

struct GlideSidebarDisplaySetting {
    let identifier: String
    let title: String
    let placement: GlideSidebarPlacement
}

private struct GlideSidebarItem {
    let title: String
    let accessibilityLabel: String
    let icon: NSImage?
    let isFocused: Bool
    let isRunning: Bool
    let activate: () -> Void
    let pinAction: GlideSidebarPinAction?
    let reorderIdentifier: String?
}

private struct GlideSidebarPinAction {
    let title: String
    let perform: () -> Void
}

private struct GlideSidebarHeaderAction {
    let accessibilityLabel: String
    let perform: (NSButton) -> Void
}

private struct GlideSidebarSection {
    let title: String
    let items: [GlideSidebarItem]
    let headerAction: GlideSidebarHeaderAction?
    let reorderAction: ((String, Int) -> Void)?

    init(title: String, items: [GlideSidebarItem],
         headerAction: GlideSidebarHeaderAction? = nil,
         reorderAction: ((String, Int) -> Void)? = nil) {
        self.title = title
        self.items = items
        self.headerAction = headerAction
        self.reorderAction = reorderAction
    }
}

final class GlideSidebarCoordinator: NSObject {
    static let shared = GlideSidebarCoordinator()
    static let idleModePreferenceKey = "taab.sidebar.idle-mode"

    private static let preferencePrefix = "glide.sidebar.placement."
    private let pinnedAppsStore = GlideSidebarPinnedAppsStore(
        didSave: { Preferences.invalidateAllCache() })
    private var panels = [String: GlideSidebarPanel]()
    private weak var rootMenuItem: NSMenuItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?

    private override init() {}

    var currentIdleMode: GlideSidebarIdleMode {
        let rawValue = UserDefaults.standard.string(forKey: Self.idleModePreferenceKey)
        return rawValue.flatMap(GlideSidebarIdleMode.init(rawValue:)) ?? .icons
    }

    func installMenuItem(in menu: NSMenu) {
        let item = NSMenuItem(title: "Sidebars by Display", action: nil, keyEquivalent: "")
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        }
        rootMenuItem = item
        menu.addItem(item)
        refreshMenu()
    }

    func start() {
        startPointerMonitoring()
        reloadScreens()
    }

    func stop() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        stopPointerMonitoring()
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    func reloadScreens() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reloadScreens() }
            return
        }
        let connected = Set(NSScreen.screens.compactMap(screenIdentifier))
        for identifier in panels.keys where !connected.contains(identifier) {
            panels.removeValue(forKey: identifier)?.orderOut(nil)
        }
        var activePanels = [GlideSidebarPanel]()
        for screen in NSScreen.screens {
            guard let identifier = screenIdentifier(screen) else { continue }
            let placement = placement(for: screen)
            guard placement != .off else {
                panels.removeValue(forKey: identifier)?.orderOut(nil)
                continue
            }
            let panel = panels[identifier] ?? GlideSidebarPanel()
            panels[identifier] = panel
            panel.configure(
                visibleFrame: screen.visibleFrame,
                placement: placement,
                idleMode: currentIdleMode)
            activePanels.append(panel)
        }
        refreshNow()
        for panel in activePanels {
            panel.orderFrontRegardless()
            panel.updatePointerLocation(NSEvent.mouseLocation)
        }
        refreshMenu()
    }

    func displaySettings() -> [GlideSidebarDisplaySetting] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let identifier = screenIdentifier(screen) else { return nil }
            return GlideSidebarDisplaySetting(
                identifier: identifier,
                title: displayName(screen, index),
                placement: placement(for: screen))
        }
    }

    func setPlacement(_ placement: GlideSidebarPlacement, for displayIdentifier: String) {
        UserDefaults.standard.set(placement.rawValue,
            forKey: Self.preferencePrefix + displayIdentifier)
        reloadScreens()
    }

    func preferenceDidChange() {
        reloadScreens()
    }

    func scheduleRefresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleRefresh() }
            return
        }
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.refreshNow() }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }

    func refreshMenu() {
        guard let rootMenuItem else { return }
        let menu = NSMenu(title: "Sidebars by Display")
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let identifier = screenIdentifier(screen) else { continue }
            let displayItem = NSMenuItem(title: displayName(screen, index), action: nil, keyEquivalent: "")
            let displayMenu = NSMenu(title: displayItem.title)
            for placement in GlideSidebarPlacement.allCases {
                let selection = GlideSidebarMenuSelection(identifier, placement)
                let item = NSMenuItem(title: title(for: placement), action: #selector(selectPlacement(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = selection
                item.state = self.placement(for: screen) == placement ? .on : .off
                displayMenu.addItem(item)
            }
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)
        }
        rootMenuItem.submenu = menu
    }

    @objc private func selectPlacement(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? GlideSidebarMenuSelection else { return }
        setPlacement(selection.placement, for: selection.screenIdentifier)
    }

    private func refreshNow() {
        for screen in NSScreen.screens {
            guard let identifier = screenIdentifier(screen), let panel = panels[identifier] else { continue }
            panel.update(sidebarSections(for: screen))
        }
    }

    private func sidebarSections(for screen: NSScreen) -> [GlideSidebarSection] {
        let screenId = screen.cachedUuid()
        let isMainScreen = NSScreen.main === screen
        let pinnedApplications = pinnedAppsStore.applications()
        let pinnedBundleIdentifiers = Set(pinnedApplications.map(\.bundleIdentifier))
        let windows = Windows.list.filter { window in
            guard !window.isTabbed, !window.isPhantom, window.shouldShowTheUser else { return false }
            if window.screenId == screenId { return true }
            return isMainScreen && window.screenId == nil
                && (window.isWindowlessApp || window.isMinimized || window.isHidden || window.isOnAllSpaces)
        }.sorted { $0.lastFocusOrder < $1.lastFocusOrder }

        let appWindows = windows.filter {
            $0.isWindowlessApp || $0.isMinimized || $0.isHidden || $0.isOnAllSpaces
        }
        var seenApplications = Set<pid_t>()
        let appItems = appWindows.compactMap { window -> GlideSidebarItem? in
            guard seenApplications.insert(window.application.pid).inserted else { return nil }
            if let bundleIdentifier = window.application.bundleIdentifier,
               pinnedBundleIdentifiers.contains(bundleIdentifier) {
                return nil
            }
            return sidebarItem(
                for: window,
                title: window.application.localizedName ?? window.title,
                highlightsApplication: true,
                pinnedBundleIdentifiers: pinnedBundleIdentifiers)
        }

        let ordinaryWindows = windows.filter {
            !$0.isWindowlessApp && !$0.isMinimized && !$0.isHidden && !$0.isOnAllSpaces
        }
        let fullscreenItems = ordinaryWindows.filter(\.isFullscreen).map {
            sidebarItem(
                for: $0,
                title: sidebarTitle(for: $0),
                highlightsApplication: false,
                pinnedBundleIdentifiers: pinnedBundleIdentifiers)
        }
        let desktopWindows = ordinaryWindows.filter { !$0.isFullscreen }
        let desktopGroups = Dictionary(grouping: desktopWindows) { window in
            window.spaceIndexes.first ?? Spaces.currentSpaceIndex
        }

        // Keep the stable top-level buckets visible even when empty. Besides matching Contexts'
        // hierarchy, their reserved header rows stop icons below them from jumping between refreshes.
        var sections = [
            GlideSidebarSection(
                title: NSLocalizedString("Pinned", comment: "Sidebar section"),
                items: pinnedApplications.map(sidebarItem(for:)),
                headerAction: GlideSidebarHeaderAction(
                    accessibilityLabel: NSLocalizedString("Add App…", comment: "Sidebar action"),
                    perform: { [weak self] button in self?.showAddPinnedAppsMenu(near: button) }),
                reorderAction: { [weak self] bundleIdentifier, finalIndex in
                    guard self?.pinnedAppsStore.move(
                        bundleIdentifier: bundleIdentifier, to: finalIndex) == true else { return }
                    DispatchQueue.main.async { [weak self] in self?.refreshNow() }
                }),
            GlideSidebarSection(
                title: NSLocalizedString("Other Apps", comment: "Sidebar section"),
                items: appItems),
            GlideSidebarSection(
                title: NSLocalizedString("Full Screen", comment: "Sidebar section"),
                items: fullscreenItems),
        ]
        for index in desktopGroups.keys.sorted() {
            let items = (desktopGroups[index] ?? []).map {
                sidebarItem(
                    for: $0,
                    title: sidebarTitle(for: $0),
                    highlightsApplication: false,
                    pinnedBundleIdentifiers: pinnedBundleIdentifiers)
            }
            sections.append(GlideSidebarSection(
                title: String(format: NSLocalizedString("Desktop %d", comment: "Sidebar section"), index),
                items: items))
        }
        return sections
    }

    private func sidebarItem(
        for window: Window,
        title: String,
        highlightsApplication: Bool,
        pinnedBundleIdentifiers: Set<String>
    ) -> GlideSidebarItem {
        let application = window.application
        let applicationName = application.localizedName ?? title
        let isFocused = Applications.frontmostPid == application.pid
            && (highlightsApplication || application.focusedWindow === window)
        let pinAction: GlideSidebarPinAction?
        if let bundleIdentifier = application.bundleIdentifier {
            let pinnedApplication = GlideSidebarPinnedApp(
                bundleIdentifier: bundleIdentifier,
                displayName: applicationName,
                bundlePath: application.bundleURL?.path)
            let isPinned = pinnedBundleIdentifiers.contains(bundleIdentifier)
            pinAction = GlideSidebarPinAction(
                title: NSLocalizedString(isPinned ? "Unpin App" : "Pin App", comment: "Sidebar context menu"),
                perform: { [weak self] in self?.togglePinnedApplication(pinnedApplication) })
        } else {
            pinAction = nil
        }
        return GlideSidebarItem(
            title: title,
            accessibilityLabel: "\(applicationName), \(title)",
            icon: application.runningApplication.icon,
            isFocused: isFocused,
            isRunning: !application.runningApplication.isTerminated,
            activate: { window.focus() },
            pinAction: pinAction,
            reorderIdentifier: nil)
    }

    private func sidebarItem(for pinnedApplication: GlideSidebarPinnedApp) -> GlideSidebarItem {
        let runningApplication = preferredRunningApplication(pinnedApplication.bundleIdentifier)
        let bundleURL = resolvedBundleURL(for: pinnedApplication)
        let title = runningApplication?.localizedName
            ?? bundleDisplayName(at: bundleURL)
            ?? pinnedApplication.displayName
        let icon = runningApplication?.icon
            ?? bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        return GlideSidebarItem(
            title: title,
            accessibilityLabel: title,
            icon: icon,
            isFocused: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == pinnedApplication.bundleIdentifier,
            isRunning: runningApplication != nil,
            activate: { [weak self] in self?.activatePinnedApplication(pinnedApplication) },
            pinAction: GlideSidebarPinAction(
                title: NSLocalizedString("Unpin App", comment: "Sidebar context menu"),
                perform: { [weak self] in self?.togglePinnedApplication(pinnedApplication) }),
            reorderIdentifier: pinnedApplication.bundleIdentifier)
    }

    private func togglePinnedApplication(_ application: GlideSidebarPinnedApp) {
        if pinnedAppsStore.isPinned(application.bundleIdentifier) {
            pinnedAppsStore.unpin(bundleIdentifier: application.bundleIdentifier)
        } else {
            pinnedAppsStore.pin(
                bundleIdentifier: application.bundleIdentifier,
                displayName: application.displayName,
                bundlePath: application.bundlePath)
        }
        refreshNow()
    }

    private func activatePinnedApplication(_ pinnedApplication: GlideSidebarPinnedApp) {
        let candidates = Windows.list.filter {
            $0.application.bundleIdentifier == pinnedApplication.bundleIdentifier
                && !$0.isTabbed && !$0.isPhantom && $0.shouldShowTheUser
        }
        let realWindows = candidates.filter { !$0.isWindowlessApp }
        if let window = (realWindows.isEmpty ? candidates : realWindows)
            .min(by: { $0.lastFocusOrder < $1.lastFocusOrder }) {
            window.focus()
            scheduleRefresh()
            return
        }

        if let runningApplication = preferredRunningApplication(pinnedApplication.bundleIdentifier) {
            if runningApplication.isHidden { runningApplication.unhide() }
            runningApplication.activate(options: .activateAllWindows)
            scheduleRefresh()
            return
        }

        guard let bundleURL = resolvedBundleURL(for: pinnedApplication),
              (try? NSWorkspace.shared.launchApplication(at: bundleURL, configuration: [:])) != nil else {
            NSSound.beep()
            return
        }
        scheduleRefresh()
    }

    private func preferredRunningApplication(_ bundleIdentifier: String) -> NSRunningApplication? {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        return applications.first(where: \.isActive) ?? applications.first
    }

    private func resolvedBundleURL(for pinnedApplication: GlideSidebarPinnedApp) -> URL? {
        if let current = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: pinnedApplication.bundleIdentifier) {
            return current
        }
        guard let path = pinnedApplication.bundlePath else { return nil }
        let stored = URL(fileURLWithPath: path)
        guard Bundle(url: stored)?.bundleIdentifier == pinnedApplication.bundleIdentifier else { return nil }
        return stored
    }

    private func bundleDisplayName(at url: URL?) -> String? {
        guard let url, let bundle = Bundle(url: url) else { return nil }
        return (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
    }

    private func showAddPinnedAppsMenu(near sender: NSButton) {
        let menu = NSMenu()
        if let panel = sender.window as? GlideSidebarPanel { menu.delegate = panel }
        let runningApplicationsItem = NSMenuItem(
            title: NSLocalizedString("Add a running app", comment: ""),
            action: nil,
            keyEquivalent: "")
        let runningApplicationsMenu = NSMenu()
        runningApplicationsForPinMenu().forEach { runningApplicationsMenu.addItem(pinMenuItem(for: $0)) }
        runningApplicationsItem.submenu = runningApplicationsMenu
        runningApplicationsItem.isEnabled = !runningApplicationsMenu.items.isEmpty
        menu.addItem(runningApplicationsItem)

        let diskItem = NSMenuItem(
            title: NSLocalizedString("Add an app from disk", comment: ""),
            action: #selector(addPinnedApplicationFromDisk(_:)),
            keyEquivalent: "")
        diskItem.target = self
        menu.addItem(diskItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func runningApplicationsForPinMenu() -> [NSRunningApplication] {
        let pinnedBundleIdentifiers = Set(pinnedAppsStore.applications().map(\.bundleIdentifier))
        var applicationsByBundleIdentifier = [String: NSRunningApplication]()
        let candidates = Windows.list.map { $0.application.runningApplication }
            + NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for application in candidates {
            guard let bundleIdentifier = application.bundleIdentifier,
                  !application.isTerminated,
                  !pinnedBundleIdentifiers.contains(bundleIdentifier),
                  applicationsByBundleIdentifier[bundleIdentifier] == nil else { continue }
            applicationsByBundleIdentifier[bundleIdentifier] = application
        }
        return applicationsByBundleIdentifier.values.sorted {
            ($0.localizedName ?? $0.bundleIdentifier ?? "").localizedStandardCompare(
                $1.localizedName ?? $1.bundleIdentifier ?? "") == .orderedAscending
        }
    }

    private func pinMenuItem(for application: NSRunningApplication) -> NSMenuItem {
        let item = NSMenuItem(
            title: application.localizedName ?? application.bundleIdentifier ?? "",
            action: #selector(addRunningPinnedApplication(_:)),
            keyEquivalent: "")
        if let icon = application.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        item.representedObject = application.bundleIdentifier
        item.target = self
        return item
    }

    @objc private func addRunningPinnedApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String,
              let application = preferredRunningApplication(bundleIdentifier) else { return }
        pinApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier,
            bundleURL: application.bundleURL)
    }

    @objc private func addPinnedApplicationFromDisk(_ sender: NSMenuItem) {
        let dialog = NSOpenPanel()
        dialog.allowsMultipleSelection = false
        dialog.allowedFileTypes = ["app"]
        dialog.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        dialog.begin { [weak self] response in
            guard response == .OK, let url = dialog.url,
                  let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return }
            let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            self?.pinApplication(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                bundleURL: url)
        }
    }

    private func pinApplication(bundleIdentifier: String, displayName: String, bundleURL: URL?) {
        pinnedAppsStore.pin(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            bundlePath: bundleURL?.path)
        refreshNow()
    }

    private func sidebarTitle(for window: Window) -> String {
        window.title.isEmpty ? (window.application.localizedName ?? "Window") : window.title
    }

    private func placement(for screen: NSScreen) -> GlideSidebarPlacement {
        guard let identifier = screenIdentifier(screen) else { return .off }
        if let raw = UserDefaults.standard.string(forKey: Self.preferencePrefix + identifier),
           let saved = GlideSidebarPlacement(rawValue: raw) {
            return saved
        }
        return NSScreen.screens.first === screen ? .right : .left
    }

    private func screenIdentifier(_ screen: NSScreen) -> String? {
        screen.cachedUuid().map { $0 as String }
    }

    private func displayName(_ screen: NSScreen, _ index: Int) -> String {
        let resolution = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        if #available(macOS 10.15, *) {
            return "\(screen.localizedName) · \(resolution)"
        }
        return "Display \(index + 1) · \(resolution)"
    }

    private func title(for placement: GlideSidebarPlacement) -> String {
        switch placement {
        case .off: return "Off"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    private func startPointerMonitoring() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.pointerLocationDidChange()
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            DispatchQueue.main.async { self?.pointerLocationDidChange() }
        }
    }

    private func stopPointerMonitoring() {
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
    }

    private func pointerLocationDidChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pointerLocationDidChange() }
            return
        }
        let location = NSEvent.mouseLocation
        panels.values.forEach { $0.updatePointerLocation(location) }
    }
}

private final class GlideSidebarMenuSelection: NSObject {
    let screenIdentifier: String
    let placement: GlideSidebarPlacement

    init(_ screenIdentifier: String, _ placement: GlideSidebarPlacement) {
        self.screenIdentifier = screenIdentifier
        self.placement = placement
    }
}

private protocol GlideSidebarPinnedDropDelegate: AnyObject {
    func pinnedDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation
    func pinnedDraggingExited(_ sender: NSDraggingInfo?)
    func performPinnedDrag(_ sender: NSDraggingInfo) -> Bool
}

private final class GlideSidebarDocumentView: FlippedView {
    weak var pinnedDropDelegate: GlideSidebarPinnedDropDelegate?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.glideSidebarPinnedApp])
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pinnedDropDelegate?.pinnedDraggingUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pinnedDropDelegate?.pinnedDraggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pinnedDropDelegate?.pinnedDraggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pinnedDropDelegate?.performPinnedDrag(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        pinnedDropDelegate?.pinnedDraggingExited(sender)
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }
}

private struct GlideSidebarPendingPinnedDrop {
    let sectionIndex: Int
    let bundleIdentifier: String
    let finalIndex: Int
}

private final class GlideSidebarPanel: NSPanel, NSMenuDelegate, GlideSidebarPinnedDropDelegate {
    private static let outerInset: CGFloat = 4
    private static let contentInset: CGFloat = 4
    private static let sectionHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 32
    private static let minimumHeight: CGFloat = 44
    private static let collapseDelay: TimeInterval = 0.14
    private static let expansionDuration: TimeInterval = 0.16
    private static let collapseDuration: TimeInterval = 0.18
    private static let cornerRadius: CGFloat = 8

    private let scrollView = NSScrollView()
    private let documentView = GlideSidebarDocumentView()
    private let background = GlideSidebarTrackingView()
    private let materialTint = NSView()
    private let reorderIndicator = NSView()
    private var sections = [GlideSidebarSection]()
    private var sectionHeaders = [NSTextField]()
    private var sectionHeaderButtons = [NSButton?]()
    private var sectionButtons = [[GlideSidebarWindowButton]]()
    private var collapseWorkItem: DispatchWorkItem?
    private var visibleFrame = CGRect.zero
    private var placement = GlideSidebarPlacement.right
    private var idleMode = GlideSidebarIdleMode.icons
    private var isPointerInside = false
    private var presentationGeneration = 0
    private var presentedExpanded: Bool?
    private var presentedHiddenTrigger: Bool?
    private var trackedMenuCount = 0
    private var isPinnedDragActive = false
    private var pendingSections: [GlideSidebarSection]?
    private var pendingPinnedDrop: GlideSidebarPendingPinnedDrop?

    override var canBecomeKey: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilitySubrole(.unknown)
        setAccessibilityLabel("Taab windows sidebar")

        documentView.pinnedDropDelegate = self
        reorderIndicator.wantsLayer = true
        reorderIndicator.layer?.backgroundColor = NSColor.selectedControlColor
            .withAlphaComponent(0.9).cgColor
        reorderIndicator.layer?.cornerRadius = 1
        reorderIndicator.isHidden = true

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.borderWidth = 0
        background.layer?.borderColor = nil
        background.layer?.masksToBounds = true
        background.onHoverChange = { [weak self] _ in
            self?.updatePointerLocation(NSEvent.mouseLocation)
        }
        contentView = background

        // Contexts uses a substantially darker neutral material than AppKit's stock popover on
        // this desktop. Keep the live blur, then darken only its backdrop; controls remain crisp.
        materialTint.wantsLayer = true
        materialTint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        materialTint.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(materialTint)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            materialTint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            materialTint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            materialTint.topAnchor.constraint(equalTo: background.topAnchor),
            materialTint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.outerInset),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.outerInset),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.outerInset),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.outerInset),
        ])
    }

    func configure(visibleFrame: CGRect, placement: GlideSidebarPlacement,
                   idleMode: GlideSidebarIdleMode) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        self.visibleFrame = visibleFrame
        self.placement = placement
        self.idleMode = idleMode
        isPointerInside = false
        presentedExpanded = nil
        presentedHiddenTrigger = nil
        applyPresentation(animated: false)
    }

    func update(_ sections: [GlideSidebarSection]) {
        guard !isPinnedDragActive else {
            pendingSections = sections
            return
        }
        rebuild(sections)
    }

    private func rebuild(_ sections: [GlideSidebarSection]) {
        pendingSections = nil
        pendingPinnedDrop = nil
        reorderIndicator.isHidden = true
        self.sections = sections
        documentView.subviews.forEach { $0.removeFromSuperview() }
        sectionHeaders.removeAll()
        sectionHeaderButtons.removeAll()
        sectionButtons.removeAll()
        for section in sections {
            let header = NSTextField(labelWithString: section.title)
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = NSColor.white.withAlphaComponent(0.34)
            header.lineBreakMode = .byTruncatingTail
            documentView.addSubview(header)
            sectionHeaders.append(header)

            let headerButton = section.headerAction.map { action -> NSButton in
                let button = NSButton(title: "+", target: nil, action: nil)
                button.font = .systemFont(ofSize: 17, weight: .regular)
                button.isBordered = false
                button.toolTip = action.accessibilityLabel
                button.setAccessibilityLabel(action.accessibilityLabel)
                button.onAction = { control in
                    guard let button = control as? NSButton else { return }
                    action.perform(button)
                }
                documentView.addSubview(button)
                return button
            }
            sectionHeaderButtons.append(headerButton)

            let buttons = section.items.map { item -> GlideSidebarWindowButton in
                let button = GlideSidebarWindowButton(item)
                button.target = self
                button.action = #selector(activateItem(_:))
                button.menu?.delegate = self
                button.onReorderDragBegan = { [weak self] in self?.pinnedDragBegan() }
                button.onReorderDragEnded = { [weak self] in self?.pinnedDragEnded() }
                documentView.addSubview(button)
                return button
            }
            sectionButtons.append(buttons)
        }
        documentView.addSubview(reorderIndicator)
        applyPresentation(animated: false)
    }

    func updatePointerLocation(_ screenPoint: CGPoint) {
        let isInside = pointerIsInActivationRegion(screenPoint)
        guard isInside != isPointerInside else { return }
        pointerHoverDidChange(isInside)
    }

    private func pointerIsInActivationRegion(_ screenPoint: CGPoint) -> Bool {
        if frame.contains(screenPoint) { return true }
        guard idleMode == .hidden,
              let activationFrame = GlideSidebarLayout.hiddenActivationFrame(
                  in: visibleFrame, placement: placement) else { return false }
        return activationFrame.contains(screenPoint)
    }

    @objc private func activateItem(_ sender: GlideSidebarWindowButton) {
        sender.activate()
    }

    private func pinnedDragBegan() {
        guard !isPinnedDragActive else { return }
        isPinnedDragActive = true
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func pinnedDragEnded() {
        guard isPinnedDragActive else { return }
        isPinnedDragActive = false
        clearPinnedDropState()
        if let pendingSections {
            rebuild(pendingSections)
        }
        updatePointerLocation(NSEvent.mouseLocation)
    }

    func pinnedDraggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isPinnedDragActive,
              let source = sender.draggingSource as? GlideSidebarPinnedDragHandle,
              source.window === self,
              sender.draggingPasteboard.string(forType: .glideSidebarPinnedApp)
                == source.bundleIdentifier,
              let sectionIndex = sections.firstIndex(where: { $0.reorderAction != nil }),
              sectionButtons.indices.contains(sectionIndex) else {
            clearPinnedDropState()
            return []
        }
        let bundleIdentifier = source.bundleIdentifier
        let buttons = sectionButtons[sectionIndex]
        guard let firstButton = buttons.first,
              let sourceIndex = buttons.firstIndex(where: {
                  $0.reorderIdentifier == bundleIdentifier
              }) else {
            clearPinnedDropState()
            return []
        }
        let location = documentView.convert(sender.draggingLocation, from: nil)
        let rowsFrame = buttons.dropFirst().reduce(firstButton.frame) {
            $0.union($1.frame)
        }
        guard rowsFrame.contains(location) else {
            clearPinnedDropState()
            return []
        }

        let insertionIndex = buttons.firstIndex(where: {
            location.y < $0.frame.midY
        }) ?? buttons.count
        guard let finalIndex = GlideSidebarPinnedReorder.finalIndex(
            itemCount: buttons.count,
            sourceIndex: sourceIndex,
            insertionIndex: insertionIndex) else {
            clearPinnedDropState()
            return []
        }
        pendingPinnedDrop = GlideSidebarPendingPinnedDrop(
            sectionIndex: sectionIndex,
            bundleIdentifier: bundleIdentifier,
            finalIndex: finalIndex)

        if finalIndex == sourceIndex {
            reorderIndicator.isHidden = true
        } else {
            let indicatorY = insertionIndex == buttons.count
                ? buttons[buttons.count - 1].frame.maxY
                : buttons[insertionIndex].frame.minY
            reorderIndicator.frame = CGRect(
                x: firstButton.frame.minX + 4,
                y: indicatorY - 1,
                width: max(0, firstButton.frame.width - 8),
                height: 2)
            reorderIndicator.isHidden = false
        }
        return .move
    }

    func pinnedDraggingExited(_ sender: NSDraggingInfo?) {
        clearPinnedDropState()
    }

    func performPinnedDrag(_ sender: NSDraggingInfo) -> Bool {
        guard pinnedDraggingUpdated(sender).contains(.move),
              let drop = pendingPinnedDrop,
              sections.indices.contains(drop.sectionIndex),
              let reorderAction = sections[drop.sectionIndex].reorderAction else {
            clearPinnedDropState()
            return false
        }
        clearPinnedDropState()
        reorderAction(drop.bundleIdentifier, drop.finalIndex)
        return true
    }

    private func clearPinnedDropState() {
        pendingPinnedDrop = nil
        reorderIndicator.isHidden = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        trackedMenuCount += 1
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        trackedMenuCount = max(0, trackedMenuCount - 1)
        guard trackedMenuCount == 0 else { return }
        updatePointerLocation(NSEvent.mouseLocation)
    }

    private func pointerHoverDidChange(_ isInside: Bool) {
        guard isInside || (trackedMenuCount == 0 && !isPinnedDragActive) else { return }
        guard isInside != isPointerInside else { return }
        isPointerInside = isInside
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if isInside {
            applyPresentation(animated: true)
        } else if idleMode != .expanded {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isPointerInside else { return }
                self.applyPresentation(animated: true)
            }
            collapseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: workItem)
        }
    }

    private func applyPresentation(animated: Bool) {
        let isExpanded = isPointerInside || idleMode == .expanded
        let width = GlideSidebarLayout.width(for: idleMode, isPointerInside: isPointerInside)
        let isHiddenTrigger = idleMode == .hidden && !isExpanded
        // Hidden mode remains flush with the screen edge while both collapsed and expanded. If the
        // expanded panel moved inward, the cursor would briefly fall into the gap and immediately
        // retrigger a collapse, which is the source of the edge flicker.
        let margin: CGFloat = idleMode == .hidden ? 0 : GlideSidebarLayout.edgeMargin
        let requestedHeight = preferredPanelHeight()
        guard let targetFrame = GlideSidebarLayout.frame(
            in: visibleFrame,
            placement: placement,
            width: width,
            height: requestedHeight,
            margin: margin) else { return }

        let stateChanged = presentedExpanded != isExpanded
            || presentedHiddenTrigger != isHiddenTrigger
        presentedExpanded = isExpanded
        presentedHiddenTrigger = isHiddenTrigger
        presentationGeneration += 1
        let generation = presentationGeneration

        guard animated, stateChanged, !frame.isEmpty else {
            finishPresentation(
                frame: targetFrame,
                isExpanded: isExpanded,
                isHiddenTrigger: isHiddenTrigger)
            return
        }

        // Prepare expanded content before growing so it is progressively revealed by the window.
        // While shrinking, retain expanded row geometry until completion so labels are clipped by
        // the moving edge instead of disappearing one frame before the panel moves.
        if isExpanded {
            scrollView.isHidden = false
            updateRowsLayout(isExpanded: true, panelWidth: targetFrame.width)
            hasShadow = true
        }

        // Keep the material fully opaque while its width changes. This makes the panel read as a
        // drawer whose inner edge moves, rather than a window that fades in and out. The hidden
        // trigger becomes transparent only after it has finished shrinking to the screen edge.
        background.alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isExpanded ? Self.expansionDuration : Self.collapseDuration
            context.timingFunction = CAMediaTimingFunction(
                name: isExpanded ? .easeOut : .easeInEaseOut)
            self.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.presentationGeneration else { return }
            self.finishPresentation(
                frame: targetFrame,
                isExpanded: isExpanded,
                isHiddenTrigger: isHiddenTrigger)
        }
    }

    private func finishPresentation(frame targetFrame: CGRect,
                                    isExpanded: Bool,
                                    isHiddenTrigger: Bool) {
        setFrame(targetFrame, display: true, animate: false)
        background.alphaValue = isHiddenTrigger ? 0.01 : 1
        background.layer?.cornerRadius = isHiddenTrigger ? 0 : Self.cornerRadius
        background.layer?.borderWidth = 0
        scrollView.isHidden = isHiddenTrigger
        hasShadow = !isHiddenTrigger
        background.layoutSubtreeIfNeeded()
        updateRowsLayout(isExpanded: isExpanded, panelWidth: targetFrame.width)
        invalidateShadow()
    }

    private func preferredPanelHeight() -> CGFloat {
        let rowCount = sectionButtons.reduce(0) { $0 + $1.count }
        let headersHeight = CGFloat(sectionHeaders.count) * Self.sectionHeight
        let contentHeight = Self.contentInset * 2 + headersHeight + CGFloat(rowCount) * Self.rowHeight
        return max(Self.minimumHeight, contentHeight + Self.outerInset * 2)
    }

    private func updateRowsLayout(isExpanded: Bool, panelWidth: CGFloat) {
        let contentWidth = max(0, panelWidth - Self.outerInset * 2)
        var y = Self.contentInset
        for index in sections.indices {
            let header = sectionHeaders[index]
            let headerButton = sectionHeaderButtons[index]
            header.isHidden = !isExpanded
            headerButton?.isHidden = !isExpanded
            if isExpanded {
                let headerButtonWidth: CGFloat = headerButton == nil ? 0 : 24
                header.frame = CGRect(x: 8, y: y + 4,
                    width: max(0, contentWidth - 16 - headerButtonWidth), height: Self.sectionHeight - 4)
                headerButton?.frame = CGRect(
                    x: max(0, contentWidth - 26), y: y + 1, width: 22, height: Self.sectionHeight - 2)
            }
            // Reserve header space in every idle mode. Icons therefore keep the same vertical
            // coordinates before, during, and after expansion instead of jumping between groups.
            y += Self.sectionHeight
            for button in sectionButtons[index] {
                button.setExpanded(isExpanded)
                button.frame = CGRect(x: 0, y: y, width: contentWidth, height: Self.rowHeight)
                y += Self.rowHeight
            }
        }
        let contentHeight = max(scrollView.contentSize.height, y + Self.contentInset)
        documentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    }
}

private final class GlideSidebarTrackingView: NSVisualEffectView {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

private final class GlideSidebarPinnedDragHandle: NSView, NSDraggingSource {
    let bundleIdentifier: String
    private weak var owner: GlideSidebarWindowButton?
    private var isHovered = false
    private var isDragging = false
    private var hoverTrackingArea: NSTrackingArea?

    init(bundleIdentifier: String, owner: GlideSidebarWindowButton) {
        self.bundleIdentifier = bundleIdentifier
        self.owner = owner
        super.init(frame: .zero)
        let accessibilityLabel = NSLocalizedString(
            "Drag to reorder", comment: "Pinned app drag handle")
        toolTip = accessibilityLabel
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityRole(.button)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        guard !isDragging, let owner else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(bundleIdentifier, forType: .glideSidebarPinnedApp)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(
            convert(owner.bounds, from: owner),
            contents: owner.reorderDraggingImage())
        isDragging = true
        window?.invalidateCursorRects(for: self)
        owner.onReorderDragBegan?()
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func showContextMenu(with event: NSEvent) {
        guard let owner, let menu = owner.menu else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: owner)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = NSColor.labelColor.withAlphaComponent(isHovered ? 0.58 : 0.24)
        color.setFill()
        let lineWidth = min(10, max(0, bounds.width - 8))
        let x = (bounds.width - lineWidth) / 2
        for offset: CGFloat in [-4, 0, 4] {
            NSBezierPath(roundedRect: CGRect(
                x: x, y: bounds.midY + offset - 0.75,
                width: lineWidth, height: 1.5),
                xRadius: 0.75, yRadius: 0.75).fill()
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        window?.invalidateCursorRects(for: self)
        owner?.onReorderDragEnded?()
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }
}

private final class GlideSidebarWindowButton: NSButton {
    // A muted steel blue keeps the current window easy to locate without competing with app icons.
    private static let focusedBackgroundColor = NSColor(
        srgbRed: 49 / 255,
        green: 90 / 255,
        blue: 134 / 255,
        alpha: 0.88)
    private let displayTitle: String
    private let isFocused: Bool
    private let isRunning: Bool
    private let activationHandler: () -> Void
    private let pinAction: GlideSidebarPinAction?
    let reorderIdentifier: String?
    var onReorderDragBegan: (() -> Void)?
    var onReorderDragEnded: (() -> Void)?
    private var reorderDragHandle: GlideSidebarPinnedDragHandle?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateBackground()
        }
    }

    init(_ item: GlideSidebarItem) {
        displayTitle = item.title
        isFocused = item.isFocused
        isRunning = item.isRunning
        activationHandler = item.activate
        pinAction = item.pinAction
        reorderIdentifier = item.reorderIdentifier
        super.init(frame: .zero)
        toolTip = item.title
        font = .systemFont(ofSize: 13, weight: .regular)
        alignment = .left
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        if let icon = item.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 24, height: 24)
            image = icon
        }
        if let pinAction {
            let menu = NSMenu()
            let menuItem = NSMenuItem(
                title: pinAction.title,
                action: #selector(performPinAction(_:)),
                keyEquivalent: "")
            menuItem.target = self
            menu.addItem(menuItem)
            self.menu = menu
        }
        if let reorderIdentifier {
            let handle = GlideSidebarPinnedDragHandle(
                bundleIdentifier: reorderIdentifier,
                owner: self)
            reorderDragHandle = handle
            addSubview(handle)
        }
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 4
        updateBackground()
        setExpanded(true)
        setAccessibilityLabel(item.accessibilityLabel)
    }

    func activate() {
        activationHandler()
    }

    @objc private func performPinAction(_ sender: NSMenuItem) {
        pinAction?.perform()
    }

    func reorderDraggingImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: representation)
        image.addRepresentation(representation)
        return image
    }

    override func layout() {
        super.layout()
        reorderDragHandle?.frame = CGRect(
            x: max(0, bounds.width - 22),
            y: 0,
            width: min(22, bounds.width),
            height: bounds.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies hit-test points in the superview's coordinate system. Reject points
        // outside this row before testing the nested handle, otherwise the first pinned row can
        // intercept the adjacent header's add button.
        guard frame.contains(point) else { return nil }
        if let reorderDragHandle, !reorderDragHandle.isHidden {
            let pointInButton = convert(point, from: superview)
            if reorderDragHandle.frame.contains(pointInButton) {
                return reorderDragHandle
            }
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    func setExpanded(_ isExpanded: Bool) {
        attributedTitle = NSAttributedString(
            string: isExpanded ? displayTitle : "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: isFocused ? NSColor.white : NSColor.labelColor,
            ])
        imagePosition = isExpanded ? .imageLeading : .imageOnly
        alignment = isExpanded ? .left : .center
        reorderDragHandle?.isHidden = !isExpanded
    }

    private func updateBackground() {
        alphaValue = isRunning || isHovered ? 1 : 0.58
        let color: NSColor?
        switch GlideSidebarLayout.rowVisualState(isFocused: isFocused, isHovered: isHovered) {
        case .normal:
            color = nil
        case .hovered:
            color = NSColor.white.withAlphaComponent(0.10)
        case .focused:
            color = Self.focusedBackgroundColor
        case .focusedHovered:
            color = Self.focusedBackgroundColor.blended(withFraction: 0.12, of: .white)
                ?? Self.focusedBackgroundColor
        }
        layer?.backgroundColor = color?.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }
}
