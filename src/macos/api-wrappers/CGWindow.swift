import Cocoa

typealias CGWindow = [CFString: Any]

extension CGWindow {
    static let normalLevel = CGWindowLevelForKey(.normalWindow)
    static let floatingWindow = CGWindowLevelForKey(.floatingWindow)

    static func windows(_ option: CGWindowListOption) -> [CGWindow] {
        return CGWindowListCopyWindowInfo([.excludeDesktopElements, option], kCGNullWindowID) as! [CGWindow]
    }

    /// Whether `targetWid` is the frontmost on-screen normal-level window. This is a one-shot post-focus read;
    /// the returned dictionaries are not cached, so verification adds no idle-memory footprint.
    static func isVisuallyFront(_ targetWid: CGWindowID) -> Bool {
        for window in windows(.optionOnScreenOnly) where window.layer() == 0 {
            guard let wid = window.id() else { continue }
            return wid == targetWid
        }
        return false
    }

    // periphery:ignore
    // workaround: filtering this criteria seems to remove non-windows UI elements
    func isNotMenubarOrOthers() -> Bool {
        return layer() == 0
    }

    // periphery:ignore
    func id() -> CGWindowID? {
        return value(kCGWindowNumber, CGWindowID.self)
    }

    func layer() -> Int? {
        return value(kCGWindowLayer, Int.self)
    }

    // periphery:ignore
    func bounds() -> NSRect? {
        if let cfDictionary = value(kCGWindowBounds, CFDictionary.self) {
            return NSRect(dictionaryRepresentation: cfDictionary)
        }
        return nil
    }

    func ownerPID() -> pid_t? {
        return value(kCGWindowOwnerPID, pid_t.self)
    }

    func ownerName() -> String? {
        return value(kCGWindowOwnerName, String.self)
    }

    func title() -> String? {
        return value(kCGWindowName, String.self)
    }

    private func value<T>(_ key: CFString, _ type: T.Type) -> T? {
        return self[key] as? T
    }
}
