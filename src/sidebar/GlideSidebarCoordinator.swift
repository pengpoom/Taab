import Cocoa

struct GlideSidebarDisplaySetting {
    let identifier: String
    let title: String
    let placement: GlideSidebarPlacement
}

private struct GlideSidebarItem {
    let window: Window
    let title: String
    let highlightsApplication: Bool
}

private struct GlideSidebarSection {
    let title: String
    let items: [GlideSidebarItem]
}

final class GlideSidebarCoordinator: NSObject {
    static let shared = GlideSidebarCoordinator()
    static let idleModePreferenceKey = "taab.sidebar.idle-mode"

    private static let preferencePrefix = "glide.sidebar.placement."
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
            return GlideSidebarItem(
                window: window,
                title: window.application.localizedName ?? window.title,
                highlightsApplication: true)
        }

        let ordinaryWindows = windows.filter {
            !$0.isWindowlessApp && !$0.isMinimized && !$0.isHidden && !$0.isOnAllSpaces
        }
        let fullscreenItems = ordinaryWindows.filter(\.isFullscreen).map {
            GlideSidebarItem(window: $0, title: sidebarTitle(for: $0), highlightsApplication: false)
        }
        let desktopWindows = ordinaryWindows.filter { !$0.isFullscreen }
        let desktopGroups = Dictionary(grouping: desktopWindows) { window in
            window.spaceIndexes.first ?? Spaces.currentSpaceIndex
        }

        // Contexts keeps these two buckets visible even when one is empty. Besides matching its
        // visual hierarchy, the stable headers stop the panel from jumping when the last app or
        // full-screen window moves back to a desktop.
        var sections = [
            GlideSidebarSection(title: "Apps", items: appItems),
            GlideSidebarSection(title: "Full Screen", items: fullscreenItems),
        ]
        for index in desktopGroups.keys.sorted() {
            let items = (desktopGroups[index] ?? []).map {
                GlideSidebarItem(window: $0, title: sidebarTitle(for: $0), highlightsApplication: false)
            }
            sections.append(GlideSidebarSection(title: "Desktop \(index)", items: items))
        }
        return sections
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

private final class GlideSidebarPanel: NSPanel {
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
    private let documentView = FlippedView()
    private let background = GlideSidebarTrackingView()
    private let materialTint = NSView()
    private var sections = [GlideSidebarSection]()
    private var sectionHeaders = [NSTextField]()
    private var sectionButtons = [[GlideSidebarWindowButton]]()
    private var collapseWorkItem: DispatchWorkItem?
    private var visibleFrame = CGRect.zero
    private var placement = GlideSidebarPlacement.right
    private var idleMode = GlideSidebarIdleMode.icons
    private var isPointerInside = false
    private var presentationGeneration = 0
    private var presentedExpanded: Bool?
    private var presentedHiddenTrigger: Bool?

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
        self.sections = sections
        documentView.subviews.forEach { $0.removeFromSuperview() }
        sectionHeaders.removeAll()
        sectionButtons.removeAll()
        for section in sections {
            let header = NSTextField(labelWithString: section.title)
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = NSColor.white.withAlphaComponent(0.34)
            header.lineBreakMode = .byTruncatingTail
            documentView.addSubview(header)
            sectionHeaders.append(header)

            let buttons = section.items.map { item -> GlideSidebarWindowButton in
                let button = GlideSidebarWindowButton(item)
                button.target = self
                button.action = #selector(focusWindow(_:))
                documentView.addSubview(button)
                return button
            }
            sectionButtons.append(buttons)
        }
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

    @objc private func focusWindow(_ sender: GlideSidebarWindowButton) {
        sender.windowModel?.focus()
    }

    private func pointerHoverDidChange(_ isInside: Bool) {
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
            header.isHidden = !isExpanded
            if isExpanded {
                header.frame = CGRect(x: 8, y: y + 4,
                    width: max(0, contentWidth - 16), height: Self.sectionHeight - 4)
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

private final class GlideSidebarWindowButton: NSButton {
    // A muted steel blue keeps the current window easy to locate without competing with app icons.
    private static let focusedBackgroundColor = NSColor(
        srgbRed: 49 / 255,
        green: 90 / 255,
        blue: 134 / 255,
        alpha: 0.88)

    let windowModel: Window?
    private let displayTitle: String
    private let isFocused: Bool
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateBackground()
        }
    }

    init(_ item: GlideSidebarItem) {
        let window = item.window
        windowModel = window
        displayTitle = item.title
        isFocused = Applications.frontmostPid == window.application.pid
            && (item.highlightsApplication || window.application.focusedWindow === window)
        super.init(frame: .zero)
        toolTip = item.title
        font = .systemFont(ofSize: 13, weight: .regular)
        alignment = .left
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        if let icon = window.application.runningApplication.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 24, height: 24)
            image = icon
        }
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 4
        updateBackground()
        setExpanded(true)
        setAccessibilityLabel("\(window.application.localizedName ?? "Application"), \(item.title)")
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
    }

    private func updateBackground() {
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
