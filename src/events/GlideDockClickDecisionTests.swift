import XCTest

final class GlideDockClickDecisionTests: XCTestCase {
    func testInactiveRunningAppKeepsNativeDockActivation() {
        XCTAssertEqual(resolve(frontmost: false), .passThrough)
    }

    func testFrontmostAppMinimizesItsFocusedWindow() {
        XCTAssertEqual(resolve(frontmost: true), .minimizeWindow)
    }

    func testFrontmostAppRestoresAChosenMinimizedWindow() {
        XCTAssertEqual(resolve(frontmost: true, minimized: true), .restoreWindow)
    }

    func testInactiveAppRestoresAChosenMinimizedWindow() {
        XCTAssertEqual(resolve(frontmost: false, minimized: true), .restoreWindow)
    }

    func testHiddenAppKeepsNativeDockActivationWhenItsWindowIsNotMinimized() {
        XCTAssertEqual(resolve(frontmost: true, hidden: true), .passThrough)
    }

    func testHiddenAppStillRestoresAMinimizedWindow() {
        XCTAssertEqual(resolve(frontmost: false, hidden: true, minimized: true), .restoreWindow)
    }

    func testAppWithoutActionableWindowKeepsNativeDockBehavior() {
        XCTAssertEqual(resolve(frontmost: false, hasWindow: false), .passThrough)
    }

    func testAppThatIsNotRunningKeepsNativeDockBehavior() {
        XCTAssertEqual(resolve(frontmost: false, running: false), .passThrough)
    }

    func testTransactionGateLocksOnlyTheTargetApplicationUntilItsDeadline() {
        var gate = GlideDockClickTransactionGate()
        gate.lock("com.example.Edge", at: 10, for: 0.45)

        XCTAssertTrue(gate.isLocked("com.example.Edge", at: 10.2))
        XCTAssertFalse(gate.isLocked("com.example.Ghostty", at: 10.2))
        XCTAssertFalse(gate.isLocked("com.example.Edge", at: 10.46))
    }

    func testTransactionGateCanBeReset() {
        var gate = GlideDockClickTransactionGate()
        gate.lock("com.example.ChatGPT", at: 20, for: 1)
        gate.reset()

        XCTAssertFalse(gate.isLocked("com.example.ChatGPT", at: 20.1))
    }

    func testTransactionGateCanUnlockAfterSystemConfirmation() {
        var gate = GlideDockClickTransactionGate()
        gate.lock("com.example.Edge", at: 30, for: 1)
        gate.unlock("com.example.Edge")

        XCTAssertFalse(gate.isLocked("com.example.Edge", at: 30.1))
    }

    private func resolve(frontmost: Bool, running: Bool = true, hidden: Bool = false,
                         hasWindow: Bool = true, minimized: Bool = false) -> GlideDockClickDecision {
        GlideDockClickResolver.resolve(GlideDockClickContext(
            targetIsRunning: running,
            targetIsFrontmost: frontmost,
            targetIsHidden: hidden,
            hasActionableWindow: hasWindow,
            targetWindowIsMinimized: minimized))
    }
}
