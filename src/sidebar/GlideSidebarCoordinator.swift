import Cocoa

struct GlideSidebarDisplaySetting {
    let identifier: String
    let title: String
    let placement: GlideSidebarPlacement
}

final class GlideSidebarCoordinator: NSObject {
    static let shared = GlideSidebarCoordinator()

    private static let preferencePrefix = "glide.sidebar.placement."
    private var panels = [String: GlideSidebarPanel]()
    private weak var rootMenuItem: NSMenuItem?
    private var refreshWorkItem: DispatchWorkItem?

    private override init() {}

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
        reloadScreens()
    }

    func stop() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
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
        for screen in NSScreen.screens {
            guard let identifier = screenIdentifier(screen) else { continue }
            let placement = placement(for: screen)
            guard let frame = GlideSidebarLayout.frame(in: screen.visibleFrame, placement: placement) else {
                panels.removeValue(forKey: identifier)?.orderOut(nil)
                continue
            }
            let panel = panels[identifier] ?? GlideSidebarPanel()
            panels[identifier] = panel
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
        refreshNow()
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
            let visibleSpaces = Set((screen.cachedUuid().flatMap { Spaces.screenSpacesMap[$0] }) ?? [])
            let windows = Windows.list.filter {
                !$0.isWindowlessApp && !$0.isTabbed && !$0.isPhantom && $0.shouldShowTheUser
                    && $0.screenId == screen.cachedUuid()
                    && ($0.isMinimized || $0.isOnAllSpaces || !$0.spaceIds.allSatisfy { !visibleSpaces.contains($0) })
            }.sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            panel.update(windows)
        }
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
    private static let headerHeight: CGFloat = 42
    private static let rowHeight: CGFloat = 48
    private static let rowSpacing: CGFloat = 4

    private let header = NSTextField(labelWithString: "Windows")
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()

    override var canBecomeKey: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilitySubrole(.unknown)
        setAccessibilityLabel("Taab windows sidebar")

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 13
        background.layer?.masksToBounds = true
        contentView = background

        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(header)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            header.heightAnchor.constraint(equalToConstant: 18),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.headerHeight),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
        ])
    }

    func update(_ windows: [Window]) {
        header.stringValue = "Windows  \(windows.count)"
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let contentWidth = max(0, frame.width - 20)
        for (index, window) in windows.enumerated() {
            let button = GlideSidebarWindowButton(window)
            button.target = self
            button.action = #selector(focusWindow(_:))
            button.frame = CGRect(x: 2, y: CGFloat(index) * (Self.rowHeight + Self.rowSpacing),
                width: contentWidth, height: Self.rowHeight)
            documentView.addSubview(button)
        }
        let contentHeight = max(scrollView.contentSize.height,
            CGFloat(windows.count) * (Self.rowHeight + Self.rowSpacing))
        documentView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    }

    @objc private func focusWindow(_ sender: GlideSidebarWindowButton) {
        sender.windowModel?.focus()
    }
}

private final class GlideSidebarWindowButton: NSButton {
    let windowModel: Window?

    init(_ window: Window) {
        windowModel = window
        super.init(frame: .zero)
        title = window.title.isEmpty ? (window.application.localizedName ?? "Window") : window.title
        if window.isMinimized { title += "  —" }
        toolTip = title
        font = .systemFont(ofSize: 12, weight: .medium)
        alignment = .left
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        if let icon = window.application.runningApplication.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 28, height: 28)
            image = icon
        }
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        layer?.cornerRadius = 8
        let isFocused = Applications.frontmostPid == window.application.pid
            && window.application.focusedWindow === window
        layer?.backgroundColor = isFocused ? NSColor.selectedControlColor.withAlphaComponent(0.22).cgColor : nil
        setAccessibilityLabel("\(window.application.localizedName ?? "Application"), \(title)")
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }
}
