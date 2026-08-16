import Cocoa
import ApplicationServices

/// Resolves a Dock click against the Dock's live accessibility tree. Icon frames are deliberately not cached:
/// magnification moves neighbouring icons during the click, so even a recently-captured rectangle can name the
/// wrong app. The inexpensive screen-edge guard keeps ordinary clicks from making any AX calls.
private final class GlideDockHitTester {
    static let shared = GlideDockHitTester()

    private static let dockBundleIdentifier = "com.apple.dock"
    private static let maximumDockDepth: CGFloat = 192
    private static let messagingTimeout: Float = 0.012

    private var dockApplication: NSRunningApplication?
    private var dockElement: AXUIElement?
    private var displayBounds = [CGRect]()
    private var screenObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard screenObserver == nil else { return }
        refreshDisplayBounds()
        _ = currentDockElement()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.refreshDisplayBounds()
            }
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dockApplication = nil
        dockElement = nil
        displayBounds.removeAll()
    }

    func bundleIdentifier(at point: CGPoint) -> String? {
        guard isNearPossibleDockArea(point), let dockElement = currentDockElement() else { return nil }
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hitElement)
        guard result == .success, let hitElement else {
            if result == .invalidUIElement { invalidateDockElement() }
            return nil
        }
        return applicationBundleIdentifier(from: hitElement)
    }

    private func currentDockElement() -> AXUIElement? {
        if let dockApplication, !dockApplication.isTerminated, let dockElement { return dockElement }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.dockBundleIdentifier).first else {
            invalidateDockElement()
            return nil
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        dockApplication = application
        dockElement = element
        return element
    }

    private func invalidateDockElement() {
        dockApplication = nil
        dockElement = nil
    }

    private func applicationBundleIdentifier(from hitElement: AXUIElement) -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        var current: AXUIElement? = hitElement
        for _ in 0..<5 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let element = current else { return nil }
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            if copyString(element, kAXSubroleAttribute as CFString) == kAXApplicationDockItemSubrole {
                return bundleIdentifier(of: element)
            }
            current = copyElement(element, kAXParentAttribute as CFString)
        }
        return nil
    }

    private func bundleIdentifier(of element: AXUIElement) -> String? {
        if let direct = copyString(element, "AXBundleIdentifier" as CFString), !direct.isEmpty {
            return direct
        }
        guard let url = copyURL(element, kAXURLAttribute as CFString) else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) {
            return running.bundleIdentifier
        }
        return Bundle(url: url)?.bundleIdentifier
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func copyURL(_ element: AXUIElement, _ attribute: CFString) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let path = value as? String { return URL(fileURLWithPath: path) }
        return nil
    }

    private func refreshDisplayBounds() {
        guard let mainScreen = NSScreen.screens.first else {
            displayBounds.removeAll()
            return
        }
        let quartzOriginY = mainScreen.frame.maxY
        displayBounds = NSScreen.screens.map { screen in
            CGRect(
                x: screen.frame.minX,
                y: quartzOriginY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height)
        }
    }

    private func isNearPossibleDockArea(_ point: CGPoint) -> Bool {
        displayBounds.contains { bounds in
            guard bounds.insetBy(dx: -1, dy: -1).contains(point) else { return false }
            return point.x - bounds.minX <= Self.maximumDockDepth
                || bounds.maxX - point.x <= Self.maximumDockDepth
                || bounds.maxY - point.y <= Self.maximumDockDepth
        }
    }
}

private struct GlideDockLiveWindow {
    let window: Window
    let element: AXUIElement
    let isMinimized: Bool
    let isFullscreen: Bool
}

final class GlideDockClickMonitor {
    static let shared = GlideDockClickMonitor()

    private static let messagingTimeout: Float = 0.015
    private static let normalTransactionDuration: TimeInterval = 0.45
    private static let fullscreenTransactionDuration: TimeInterval = 1.35

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transactionGate = GlideDockClickTransactionGate()

    private init() {}

    func start() {
        guard eventTap == nil else { return }
        GlideDockHitTester.shared.start()
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            GlideDockHitTester.shared.stop()
            Logger.error { "Taab Dock click event tap could not be created" }
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.info { "Taab Dock click toggle started" }
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        transactionGate.reset()
        GlideDockHitTester.shared.stop()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<GlideDockClickMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return monitor.handle(type, event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .leftMouseDown, Thread.isMainThread,
              let bundleIdentifier = GlideDockHitTester.shared.bundleIdentifier(at: event.location) else {
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if transactionGate.isLocked(bundleIdentifier, at: now) {
            return nil
        }
        guard let application = preferredApplication(bundleIdentifier),
              let liveWindow = liveWindow(for: application) else {
            return Unmanaged.passUnretained(event)
        }
        let runningApplication = application.runningApplication
        let decision = GlideDockClickResolver.resolve(GlideDockClickContext(
            targetIsRunning: !runningApplication.isTerminated,
            targetIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == application.pid,
            targetIsHidden: runningApplication.isHidden,
            hasActionableWindow: true,
            targetWindowIsMinimized: liveWindow.isMinimized))
        let duration: TimeInterval?
        let expectedMinimized: Bool
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .restoreWindow:
            expectedMinimized = false
            duration = restore(liveWindow, application)
        case .minimizeWindow:
            expectedMinimized = true
            duration = minimize(liveWindow)
        }
        guard let duration else {
            return Unmanaged.passUnretained(event)
        }
        transactionGate.lock(bundleIdentifier, at: now, for: duration)
        confirmTransaction(
            bundleIdentifier,
            liveWindow: liveWindow,
            applicationPid: application.pid,
            expectedMinimized: expectedMinimized,
            deadline: now + duration,
            after: liveWindow.isFullscreen && expectedMinimized ? 1.05 : 0.08)
        return nil
    }

    private func preferredApplication(_ bundleIdentifier: String) -> Application? {
        let candidates = Applications.list.filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.runningApplication.isTerminated
        }
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frontmost = candidates.first(where: { $0.pid == frontmostPid }) {
            return frontmost
        }
        return candidates.first(where: { $0.runningApplication.isActive }) ?? candidates.first
    }

    private func liveWindow(for application: Application) -> GlideDockLiveWindow? {
        let candidates = actionableWindows(for: application)
        guard !candidates.isEmpty else { return nil }

        let appElement = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let element = copyElement(appElement, attribute as CFString),
               let window = matchingWindow(element, among: candidates),
               let snapshot = snapshot(window, element) {
                if window.axUiElement != element { window.rebindAxElement(element) }
                return snapshot
            }
        }

        // Some background apps expose neither focused nor main window. Fall back to Glide's MRU ordering, but
        // accept it only after a live minimized-state read succeeds; stale AX elements therefore fail open.
        for window in candidates.sorted(by: { $0.lastFocusOrder < $1.lastFocusOrder }) {
            guard let element = window.axUiElement, let snapshot = snapshot(window, element) else { continue }
            return snapshot
        }
        return nil
    }

    private func actionableWindows(for application: Application) -> [Window] {
        Windows.list.filter {
            $0.application.pid == application.pid && !$0.isWindowlessApp && !$0.isTabbed && !$0.isPhantom
                && $0.canBeMinDeminOrFullscreened()
        }
    }

    private func matchingWindow(_ element: AXUIElement, among candidates: [Window]) -> Window? {
        var wid = CGWindowID(0)
        let result = _AXUIElementGetWindow(element, &wid)
        let liveWid: CGWindowID? = result == .success && wid != 0 ? wid : nil
        return candidates.first { $0.isEqualRobust(element, liveWid) }
    }

    private func snapshot(_ window: Window, _ element: AXUIElement) -> GlideDockLiveWindow? {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard let isMinimized = copyBool(element, kAXMinimizedAttribute as CFString) else { return nil }
        let isFullscreen = copyBool(element, kAXFullscreenAttribute as CFString) ?? window.isFullscreen
        return GlideDockLiveWindow(
            window: window,
            element: element,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen)
    }

    private func restore(_ liveWindow: GlideDockLiveWindow, _ application: Application) -> TimeInterval? {
        let result = AXUIElementSetAttributeValue(
            liveWindow.element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        guard result == .success else {
            Logger.debug { "Dock restore failed pid=\(application.pid) axError=\(result.rawValue); passing click through" }
            return nil
        }
        if application.runningApplication.isHidden { application.runningApplication.unhide() }
        liveWindow.window.focus()
        return Self.normalTransactionDuration
    }

    private func minimize(_ liveWindow: GlideDockLiveWindow) -> TimeInterval? {
        if liveWindow.isFullscreen {
            let result = AXUIElementSetAttributeValue(
                liveWindow.element, kAXFullscreenAttribute as CFString, false as CFTypeRef)
            guard result == .success else {
                Logger.debug { "Dock de-fullscreen failed wid=\(liveWindow.window.cgWindowId ?? 0) axError=\(result.rawValue); passing click through" }
                return nil
            }
            minimizeAfterFullscreenTransition(liveWindow)
            return Self.fullscreenTransactionDuration
        }
        let result = AXUIElementSetAttributeValue(
            liveWindow.element, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        guard result == .success else {
            Logger.debug { "Dock minimize failed wid=\(liveWindow.window.cgWindowId ?? 0) axError=\(result.rawValue); passing click through" }
            return nil
        }
        return Self.normalTransactionDuration
    }

    private func minimizeAfterFullscreenTransition(_ liveWindow: GlideDockLiveWindow) {
        let originalElement = liveWindow.element
        BackgroundWork.accessibilityCommandsQueue.addOperationAfter(deadline: .now() + .seconds(1)) { [weak window = liveWindow.window] in
            AXUIElementSetMessagingTimeout(originalElement, Self.messagingTimeout)
            var result = AXUIElementSetAttributeValue(
                originalElement, kAXMinimizedAttribute as CFString, true as CFTypeRef)
            if result == .invalidUIElement, let fresh = window?.refreshedAxElement() {
                AXUIElementSetMessagingTimeout(fresh, Self.messagingTimeout)
                result = AXUIElementSetAttributeValue(fresh, kAXMinimizedAttribute as CFString, true as CFTypeRef)
                if result == .success {
                    DispatchQueue.main.async { window?.rebindAxElement(fresh) }
                }
            }
            if result != .success {
                Logger.debug { "Dock fullscreen minimize failed wid=\(window?.cgWindowId ?? 0) axError=\(result.rawValue)" }
            }
        }
    }

    /// Releases the per-app transaction as soon as the OS confirms the requested state. Restore additionally
    /// waits for activation: `kAXMinimized == false` can become true before the app has actually reached front.
    private func confirmTransaction(_ bundleIdentifier: String, liveWindow: GlideDockLiveWindow,
                                    applicationPid: pid_t, expectedMinimized: Bool,
                                    deadline: TimeInterval, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard self.transactionGate.isLocked(bundleIdentifier, at: now) else { return }
            let actualMinimized = self.copyBool(liveWindow.element, kAXMinimizedAttribute as CFString)
            let activationConfirmed = expectedMinimized
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPid
            if actualMinimized == expectedMinimized, activationConfirmed {
                self.transactionGate.unlock(bundleIdentifier)
                return
            }
            guard now < deadline else {
                self.transactionGate.unlock(bundleIdentifier)
                return
            }
            self.confirmTransaction(
                bundleIdentifier,
                liveWindow: liveWindow,
                applicationPid: applicationPid,
                expectedMinimized: expectedMinimized,
                deadline: deadline,
                after: min(0.08, deadline - now))
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }
}
