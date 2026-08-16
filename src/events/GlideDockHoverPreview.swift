import Cocoa
import ApplicationServices

struct GlideDockTarget {
    let bundleIdentifier: String
    let quartzFrame: CGRect
    let quartzPoint: CGPoint
}

/// Event-driven Dock hover previews. Mouse movement is sampled at most every 50ms and the AX tree is queried
/// only near a possible Dock edge. There is no timer that scans apps or windows while the pointer is elsewhere.
final class GlideDockHoverPreviewController: NSObject {
    static let shared = GlideDockHoverPreviewController()

    static let preferenceKey = "taab.dock-hover-previews.mode"
    static let legacyPreferenceKey = "taab.dock-hover-previews.enabled"
    private static let showDelay: TimeInterval = 0.28
    private static let hideDelay: TimeInterval = 0.16

    private let hoverMonitor = GlideDockHoverMonitor()
    private let previewPanel = GlideDockPreviewPanel()
    private weak var menuItem: NSMenuItem?
    private var modeMenuItems = [GlideDockHoverPreviewMode: NSMenuItem]()
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var refreshWorkItem: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var workspaceObservers = [NSObjectProtocol]()
    private var candidateTarget: GlideDockTarget?
    private var visibleTarget: GlideDockTarget?
    private var transitionRegion = CGRect.null
    private var isStarted = false

    private override init() {
        super.init()
        migrateLegacyPreferenceIfNeeded()
        hoverMonitor.onMove = { [weak self] point, target in
            self?.pointerMoved(to: point, target: target)
        }
        previewPanel.onSelect = { [weak self] window in
            self?.activate(window)
        }
    }

    var currentMode: GlideDockHoverPreviewMode {
        let rawValue = UserDefaults.standard.string(forKey: Self.preferenceKey)
        return rawValue.flatMap(GlideDockHoverPreviewMode.init(rawValue:)) ?? .multipleWindowsOnly
    }

    func installMenuItem(in menu: NSMenu) {
        let item = NSMenuItem(
            title: NSLocalizedString("Dock hover previews", comment: ""),
            action: nil,
            keyEquivalent: "")
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: nil)
        }
        let submenu = NSMenu(title: item.title)
        for mode in GlideDockHoverPreviewMode.allCases {
            let modeItem = NSMenuItem(
                title: mode.localizedTitle,
                action: #selector(selectMode(_:)),
                keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            submenu.addItem(modeItem)
            modeMenuItems[mode] = modeItem
        }
        item.submenu = submenu
        menuItem = item
        menu.addItem(item)
        refreshMenuState()
    }

    func start() {
        guard !isStarted, currentMode != .disabled else { return }
        isStarted = true
        GlideDockHitTester.shared.start()
        hoverMonitor.start()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            DispatchQueue.main.async { self?.hideImmediately() }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in self?.hideImmediately() })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in self?.hideImmediately() })
        Logger.info { "Taab Dock hover previews started" }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        hoverMonitor.stop()
        GlideDockHitTester.shared.stop()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        globalClickMonitor = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        hideImmediately()
    }

    func hideImmediately() {
        showWorkItem?.cancel()
        hideWorkItem?.cancel()
        refreshWorkItem?.cancel()
        showWorkItem = nil
        hideWorkItem = nil
        refreshWorkItem = nil
        candidateTarget = nil
        visibleTarget = nil
        transitionRegion = .null
        previewPanel.hide()
    }

    /// Window lifecycle events already flow through App.refreshOpenUiAfterExternalEvent. If a preview is open,
    /// coalesce those bursts and rebuild only its app's cards.
    func scheduleRefresh() {
        guard isStarted, visibleTarget != nil else { return }
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshVisiblePreview() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Capture delivery happens on main. Updating one card avoids rebuilding the panel for every screenshot.
    func thumbnailDidRefresh(_ window: Window) {
        guard visibleTarget?.bundleIdentifier == window.application.bundleIdentifier else { return }
        previewPanel.updateThumbnail(for: window)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = GlideDockHoverPreviewMode(rawValue: rawValue) else { return }
        Preferences.set(Self.preferenceKey, mode.rawValue)
    }

    func preferenceDidChange() {
        refreshMenuState()
        if currentMode == .disabled {
            stop()
        } else {
            start()
            refreshVisiblePreview()
        }
    }

    private func pointerMoved(to quartzPoint: CGPoint, target: GlideDockTarget?) {
        guard isStarted else { return }
        let appKitPoint = GlideDockHoverLayout.appKitPoint(
            fromQuartz: quartzPoint,
            primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0)

        if let target {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            if visibleTarget?.bundleIdentifier == target.bundleIdentifier {
                visibleTarget = target
                updateTransitionRegion(target)
                return
            }
            armShow(for: target)
            return
        }

        if previewPanel.isVisible,
           previewPanel.frame.insetBy(dx: -2, dy: -2).contains(appKitPoint)
                || transitionRegion.contains(appKitPoint) {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            return
        }

        showWorkItem?.cancel()
        showWorkItem = nil
        candidateTarget = nil
        armHide()
    }

    private func armShow(for target: GlideDockTarget) {
        if candidateTarget?.bundleIdentifier == target.bundleIdentifier {
            candidateTarget = target
            return
        }
        showWorkItem?.cancel()
        candidateTarget = target
        if visibleTarget != nil { previewPanel.hide(); visibleTarget = nil; transitionRegion = .null }
        let expectedBundle = target.bundleIdentifier
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted,
                  let latest = self.candidateTarget,
                  latest.bundleIdentifier == expectedBundle else { return }
            self.show(latest)
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func armHide() {
        guard previewPanel.isVisible, hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.hideImmediately() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    private func show(_ target: GlideDockTarget) {
        let windows = previewWindows(for: target.bundleIdentifier)
        guard currentMode.shouldShowPreview(windowCount: windows.count) else {
            hideImmediately()
            return
        }
        visibleTarget = target
        previewPanel.show(windows: windows, target: target)
        updateTransitionRegion(target)
        WindowThumbnails.refreshForDockPreview(windows)
    }

    private func refreshVisiblePreview() {
        guard let target = visibleTarget else { return }
        let windows = previewWindows(for: target.bundleIdentifier)
        guard currentMode.shouldShowPreview(windowCount: windows.count) else {
            hideImmediately()
            return
        }
        previewPanel.show(windows: windows, target: target)
        updateTransitionRegion(target)
        WindowThumbnails.refreshForDockPreview(windows.filter { $0.thumbnail == nil })
    }

    private func previewWindows(for bundleIdentifier: String) -> [Window] {
        Windows.list.filter {
            $0.application.bundleIdentifier == bundleIdentifier
                && !$0.isWindowlessApp && !$0.isTabbed && !$0.isPhantom && $0.shouldShowTheUser
        }.sorted {
            if $0.application.pid == Applications.frontmostPid,
               $1.application.pid != Applications.frontmostPid { return true }
            if $1.application.pid == Applications.frontmostPid,
               $0.application.pid != Applications.frontmostPid { return false }
            return $0.lastFocusOrder < $1.lastFocusOrder
        }
    }

    private func updateTransitionRegion(_ target: GlideDockTarget) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        var iconFrame = GlideDockHoverLayout.appKitRect(fromQuartz: target.quartzFrame, primaryMaxY: primaryMaxY)
        if iconFrame.isEmpty {
            let point = GlideDockHoverLayout.appKitPoint(fromQuartz: target.quartzPoint, primaryMaxY: primaryMaxY)
            iconFrame = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        }
        transitionRegion = GlideDockHoverLayout.transitionRegion(
            iconFrame: iconFrame,
            panelFrame: previewPanel.frame)
    }

    private func activate(_ window: Window) {
        hideImmediately()
        window.focus()
    }

    private func refreshMenuState() {
        let selectedMode = currentMode
        for (mode, item) in modeMenuItems {
            item.state = mode == selectedMode ? .on : .off
        }
        menuItem?.isEnabled = true
    }

    /// v0.0.2 stored this preference as a boolean. Preserve an explicit "off" choice while
    /// mapping the old enabled state to the new, less intrusive multi-window default.
    private func migrateLegacyPreferenceIfNeeded() {
        let domain = UserDefaults.standard.persistentDomain(forName: App.bundleIdentifier) ?? [:]
        guard domain[Self.preferenceKey] == nil,
              let legacyValue = domain[Self.legacyPreferenceKey] else { return }
        let wasEnabled: Bool
        switch legacyValue {
        case let value as Bool: wasEnabled = value
        case let value as NSNumber: wasEnabled = value.boolValue
        case let value as String: wasEnabled = NSString(string: value).boolValue
        default: wasEnabled = true
        }
        Preferences.set(Self.preferenceKey,
            wasEnabled ? GlideDockHoverPreviewMode.multipleWindowsOnly.rawValue
                : GlideDockHoverPreviewMode.disabled.rawValue,
            false)
        Preferences.remove(Self.legacyPreferenceKey, false)
    }
}

private final class GlideDockHoverMonitor {
    private static let sampleInterval: TimeInterval = 0.05

    var onMove: ((CGPoint, GlideDockTarget?) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingSample: DispatchWorkItem?
    private var latestPoint = CGPoint.zero
    private var lastSampleAt: TimeInterval = -.infinity

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Logger.error { "Taab Dock hover event tap could not be created" }
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        pendingSample?.cancel()
        pendingSample = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlideDockHoverMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .mouseMoved { monitor.receive(event.location) }
        return Unmanaged.passUnretained(event)
    }

    private func receive(_ point: CGPoint) {
        latestPoint = point
        let now = ProcessInfo.processInfo.systemUptime
        let wait = Self.sampleInterval - (now - lastSampleAt)
        if wait <= 0 {
            sample()
        } else if pendingSample == nil {
            let work = DispatchWorkItem { [weak self] in self?.sample() }
            pendingSample = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    private func sample() {
        pendingSample = nil
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        let point = latestPoint
        onMove?(point, GlideDockHitTester.shared.target(at: point))
    }
}

private final class GlideDockPreviewPanel: NSPanel {
    private static let cardWidth: CGFloat = 216
    private static let cardHeight: CGFloat = 154
    private static let spacing: CGFloat = 8
    private static let padding: CGFloat = 10
    private static let panelHeight: CGFloat = 174
    private static let maximumWidth: CGFloat = 780

    var onSelect: ((Window) -> Void)?
    private let effectView = NSVisualEffectView()
    private let scrollView = GlideDockPreviewScrollView()
    private let documentView = FlippedView()
    private var cards = [CGWindowID: GlideDockPreviewCard]()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        setAccessibilitySubrole(.unknown)
        setAccessibilityLabel("Taab Dock window previews")

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        contentView = effectView

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        scrollView.autoresizingMask = [.width, .height]
        effectView.addSubview(scrollView)
    }

    func show(windows: [Window], target: GlideDockTarget) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        var iconFrame = GlideDockHoverLayout.appKitRect(fromQuartz: target.quartzFrame, primaryMaxY: primaryMaxY)
        if iconFrame.isEmpty {
            let point = GlideDockHoverLayout.appKitPoint(fromQuartz: target.quartzPoint, primaryMaxY: primaryMaxY)
            iconFrame = CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
        }
        let screen = screen(containing: CGPoint(x: iconFrame.midX, y: iconFrame.midY))
            ?? NSScreen.screens.first
        guard let screen else { return }
        let contentWidth = Self.padding * 2
            + CGFloat(windows.count) * Self.cardWidth
            + CGFloat(max(0, windows.count - 1)) * Self.spacing
        let maximumWidth = min(Self.maximumWidth, max(240, screen.visibleFrame.width - 20))
        let panelSize = CGSize(width: min(maximumWidth, contentWidth), height: Self.panelHeight)
        let edge = GlideDockHoverLayout.edge(for: iconFrame, in: screen.frame)
        let frame = GlideDockHoverLayout.panelFrame(
            iconFrame: iconFrame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            panelSize: panelSize,
            edge: edge)
        setFrame(frame, display: true)
        update(windows)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
        cards.removeAll()
        documentView.subviews.forEach { $0.removeFromSuperview() }
    }

    func updateThumbnail(for window: Window) {
        guard let wid = window.cgWindowId else { return }
        cards[wid]?.updateImage()
    }

    private func update(_ windows: [Window]) {
        cards.removeAll()
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let documentWidth = Self.padding * 2
            + CGFloat(windows.count) * Self.cardWidth
            + CGFloat(max(0, windows.count - 1)) * Self.spacing
        scrollView.frame = effectView.bounds.insetBy(dx: 0, dy: 4)
        documentView.frame = CGRect(x: 0, y: 0, width: documentWidth, height: Self.cardHeight + Self.padding * 2)
        for (index, window) in windows.enumerated() {
            let card = GlideDockPreviewCard(window)
            card.onSelect = { [weak self, weak window] in
                guard let window else { return }
                self?.onSelect?(window)
            }
            card.frame = CGRect(
                x: Self.padding + CGFloat(index) * (Self.cardWidth + Self.spacing),
                y: Self.padding,
                width: Self.cardWidth,
                height: Self.cardHeight)
            documentView.addSubview(card)
            if let wid = window.cgWindowId { cards[wid] = card }
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return exact }
        return NSScreen.screens.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y)
                < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
    }
}

private final class GlideDockPreviewScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        let origin = contentView.bounds.origin
        let maximumX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: CGPoint(x: min(maximumX, max(0, origin.x - event.scrollingDeltaY)), y: origin.y))
        reflectScrolledClipView(contentView)
    }
}

private final class GlideDockPreviewCard: NSControl {
    let windowModel: Window
    var onSelect: (() -> Void)?
    private let imageLayer = CALayer()
    private let appIconLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateBorder() } }
    private var isPressed = false { didSet { updateBorder() } }

    init(_ window: Window) {
        windowModel = window
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 1

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        imageLayer.cornerRadius = 7
        imageLayer.masksToBounds = true
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .trilinear
        layer?.addSublayer(imageLayer)

        appIconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(appIconLayer)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        addSubview(detailLabel)

        titleLabel.stringValue = window.title.isEmpty
            ? (window.application.localizedName ?? "Window") : window.title
        detailLabel.stringValue = window.isMinimized
            ? "\(window.application.localizedName ?? "Application") · Minimized"
            : (window.application.localizedName ?? "Application")
        toolTip = titleLabel.stringValue
        setAccessibilityLabel("\(detailLabel.stringValue), \(titleLabel.stringValue)")
        updateImage()
        updateBorder()
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func layout() {
        super.layout()
        let imageHeight = max(0, bounds.height - 44)
        imageLayer.frame = CGRect(x: 7, y: bounds.height - imageHeight - 7,
            width: bounds.width - 14, height: imageHeight)
        appIconLayer.frame = CGRect(x: 12, y: 9, width: 25, height: 25)
        titleLabel.frame = CGRect(x: 43, y: 21, width: bounds.width - 50, height: 17)
        detailLabel.frame = CGRect(x: 43, y: 7, width: bounds.width - 50, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onSelect?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func updateImage() {
        if let thumbnail = windowModel.thumbnail {
            apply(thumbnail, to: imageLayer)
        } else {
            imageLayer.contents = windowModel.icon
        }
        appIconLayer.contents = windowModel.icon
    }

    private func apply(_ contents: CALayerContents, to layer: CALayer) {
        switch contents {
        case .cgImage(let image): layer.contents = image
        case .pixelBuffer(let pixelBuffer):
            layer.contents = pixelBuffer.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
        }
    }

    private func updateBorder() {
        let isFocused = Applications.frontmostPid == windowModel.application.pid
            && windowModel.application.focusedWindow === windowModel
        layer?.borderColor = (isHovered || isPressed || isFocused
            ? NSColor.selectedControlColor.withAlphaComponent(isPressed ? 0.95 : 0.7)
            : NSColor.gridColor.withAlphaComponent(0.45)).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(isHovered ? 0.5 : 0.28).cgColor
    }
}
