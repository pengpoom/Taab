import Foundation

enum GlideDockClickDecision: Equatable {
    case passThrough
    case restoreWindow
    case minimizeWindow
}

struct GlideDockClickContext: Equatable {
    let targetIsRunning: Bool
    let targetIsFrontmost: Bool
    let targetIsHidden: Bool
    let hasActionableWindow: Bool
    let targetWindowIsMinimized: Bool
}

enum GlideDockClickResolver {
    static func resolve(_ context: GlideDockClickContext) -> GlideDockClickDecision {
        guard context.targetIsRunning, context.hasActionableWindow else { return .passThrough }
        if context.targetWindowIsMinimized { return .restoreWindow }
        guard context.targetIsFrontmost, !context.targetIsHidden else { return .passThrough }
        return .minimizeWindow
    }
}

/// Prevents a second click from observing the half-finished state of the first Dock action and choosing the
/// opposite action. The monitor owns OS confirmation; this small value type only owns the bounded fail-safe.
struct GlideDockClickTransactionGate {
    private var lockedUntil = [String: TimeInterval]()

    mutating func isLocked(_ bundleIdentifier: String, at now: TimeInterval) -> Bool {
        lockedUntil = lockedUntil.filter { $0.value > now }
        return lockedUntil[bundleIdentifier] != nil
    }

    mutating func lock(_ bundleIdentifier: String, at now: TimeInterval, for duration: TimeInterval) {
        lockedUntil[bundleIdentifier] = now + duration
    }

    mutating func unlock(_ bundleIdentifier: String) {
        lockedUntil.removeValue(forKey: bundleIdentifier)
    }

    mutating func reset() {
        lockedUntil.removeAll()
    }
}
