import XCTest

/// Pins the activation-focus decisions (`ActivationFocusResolver`) — which 808s bump the MRU around an app
/// activation, and when the AX backstop yields — against the recorded ground truth that produced them
/// (TextEdit storm, iTerm single-808, #5596). See ActivationFocusResolverSpecs.md.
final class ActivationFocusResolverTests: XCTestCase {

    private func entry(wids: Set<CGWindowID> = [1, 2], until: TimeInterval = 100, focusBumped: Bool = false) -> ActivationEntry {
        ActivationEntry(wids: wids, until: until, focusBumped: focusBumped)
    }

    // MARK: - onFocusEvent

    func testFirstFocusOfActivationBumpsEvenWhileInactive() {
        // the iTerm case (#5596): a single 808 arrives right after activation, while
        // NSRunningApplication.isActive can still read false — it IS the focus, it must bump.
        let d = ActivationFocusResolver.onFocusEvent(entry(), wid: 2, now: 50, wasJustCreated: false, appIsActive: false)
        XCTAssertTrue(d.bump)
        XCTAssertEqual(d.entry, entry(wids: [1], focusBumped: true))
    }

    func testRaiseTailSwallowed() {
        // the TextEdit storm: after the focus 808, the remaining windows' raises must NOT re-front
        // (bumping each would reverse the app's MRU).
        let d = ActivationFocusResolver.onFocusEvent(entry(focusBumped: true), wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertFalse(d.bump)
        XCTAssertEqual(d.entry, entry(wids: [2], focusBumped: true))
    }

    func testSecondFocusOfSameWidBumps() {
        // a wid's SECOND 808 (its raise already consumed its snapshot entry) is a genuine re-focus.
        let d = ActivationFocusResolver.onFocusEvent(entry(wids: [2], focusBumped: true), wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertTrue(d.bump)
        XCTAssertEqual(d.entry, entry(wids: [2], focusBumped: true))
    }

    func testExpiredEntryPrunedAndNormalRulesApply() {
        // past `until` the activation is over: the entry is pruned and the plain isActive rule decides.
        let d = ActivationFocusResolver.onFocusEvent(entry(until: 10), wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertTrue(d.bump)
        XCTAssertNil(d.entry)
    }

    func testNoActivationActiveAppBumps() {
        let d = ActivationFocusResolver.onFocusEvent(nil, wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertTrue(d.bump)
        XCTAssertNil(d.entry)
    }

    func testNoActivationInactiveAppDropped() {
        // a background app re-focusing one of its windows: ignore to avoid MRU churn.
        let d = ActivationFocusResolver.onFocusEvent(nil, wid: 1, now: 50, wasJustCreated: false, appIsActive: false)
        XCTAssertFalse(d.bump)
    }

    func testJustCreatedAlwaysBumps() {
        // a brand-new window's first focus is honored even inactive and even mid-raise-tail (cmd-N spam).
        XCTAssertTrue(ActivationFocusResolver.onFocusEvent(nil, wid: 1, now: 50, wasJustCreated: true, appIsActive: false).bump)
        XCTAssertTrue(ActivationFocusResolver.onFocusEvent(entry(focusBumped: true), wid: 1, now: 50, wasJustCreated: true, appIsActive: false).bump)
    }

    // MARK: - onActivation

    func testGlideInitiatedActivationDefersKnownTargetUntilVisualVerification() {
        // App activation alone is only half of the requested operation: the selected window may still be
        // behind another app. Mark the focus spoken and mask its 808 so neither can win before verification.
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2)
        XCTAssertNil(a.bumpWid)
        XCTAssertEqual(a.entry, ActivationEntry(wids: [2], until: 100, focusBumped: true))
    }

    func testGlideInitiatedActivationMutesNothing() {
        // Glide raises ONE window, so this activation has no raise tail: the snapshot is empty and a later
        // 808 for another window of the same app is a real focus (#5785's stuck switcher).
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2)
        let d = ActivationFocusResolver.onFocusEvent(a.entry, wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertTrue(d.bump)
    }

    func testRestoringAMinimizedTargetMutesTheDeminiaturizeTail() {
        // Deminiaturize is the one Glide focus that stirs the app's other windows, so this activation DOES
        // have a tail. Live (QA I-11, 2026-07-31): restoring #90112 drew a focus 808 for sibling #90106 38ms
        // later, which with an empty snapshot took the front off the window just restored (#5439's shape).
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2,
                                                     targetWasMinimized: true)
        XCTAssertNil(a.bumpWid)
        XCTAssertEqual(a.entry, ActivationEntry(wids: [1, 2], until: 100, focusBumped: true, raiseTail: [1]))
        let d = ActivationFocusResolver.onFocusEvent(a.entry, wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertFalse(d.bump)
    }

    func testRestoringAMinimizedTargetWaitsForVisualVerification() {
        // The target is never part of the tail: subtracted from the snapshot regardless of how the caller
        // built it, so its own 808 is not read as a raise.
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2,
                                                     targetWasMinimized: true)
        let d = ActivationFocusResolver.onFocusEvent(a.entry, wid: 2, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertFalse(d.bump)
    }

    func testRestoringAMinimizedTargetMutesEachSiblingOnlyOnce() {
        // The tail consumes its entry per wid, so a genuine later switch to that sibling still bumps — the
        // muting is one event deep, not a 0.5s blackout on the window.
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2,
                                                     targetWasMinimized: true)
        let first = ActivationFocusResolver.onFocusEvent(a.entry, wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        XCTAssertFalse(first.bump)
        let second = ActivationFocusResolver.onFocusEvent(first.entry, wid: 1, now: 60, wasJustCreated: false, appIsActive: true)
        XCTAssertTrue(second.bump)
    }

    func testExternalActivationWaitsForFocusSignal() {
        // no known target (Cmd+Tab, click): plain entry — the first 808 or the AX backstop decides.
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: nil)
        XCTAssertNil(a.bumpWid)
        XCTAssertEqual(a.entry, ActivationEntry(wids: [1, 2], until: 100, focusBumped: false, raiseTail: [1, 2]))
    }

    // MARK: - raiseTail (the undrained copy the 815 path reads)

    func testRaiseTailSurvivesTheFocusEventsThatDrainTheSnapshot() {
        // The whole point: 808s spend `wids`, and the tail's 815s arrive after that — so only this copy can
        // still say "this wid was a candidate of this activation" when the order-in finally lands (#5596).
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: nil)
        let first = ActivationFocusResolver.onFocusEvent(a.entry, wid: 1, now: 50, wasJustCreated: false, appIsActive: true)
        let second = ActivationFocusResolver.onFocusEvent(first.entry, wid: 2, now: 51, wasJustCreated: false, appIsActive: true)
        XCTAssertEqual(second.entry?.wids, [])
        XCTAssertEqual(second.entry?.raiseTail, [1, 2])
    }

    func testGlideInitiatedActivationHasAnEmptyRaiseTail() {
        // Nothing was snapshotted, so nothing this app orders in during the 0.5s is a raise of OURS: the
        // user's own Cmd+` a beat after an alt-tab is a real focus (#5875).
        let a = ActivationFocusResolver.onActivation(snapshotWids: [1, 2], until: 100, altTabTarget: 2)
        XCTAssertEqual(a.entry.raiseTail, [])
    }

    // MARK: - the Glide focus intent

    func testIntentIsRecordedWhenAnActivationIsComing() {
        let i = ActivationFocusResolver.altTabIntentToRecord(wid: 7, pid: 500, frontmostPid: 700, at: 10)
        XCTAssertEqual(i, ActivationFocusResolver.GlideFocusIntent(wid: 7, pid: 500, at: 10))
    }

    func testNoIntentWhenTheAppIsAlreadyFrontmost() {
        // Focusing a window of the frontmost app raises no app, so no didActivate follows to consume the
        // record. Left behind, it would tell the NEXT activation of that app both a stale target and "no raise
        // tail to mute", and the real burst would re-front each window in turn (#5596).
        XCTAssertNil(ActivationFocusResolver.altTabIntentToRecord(wid: 7, pid: 500, frontmostPid: 500, at: 10))
    }

    func testIntentAppliesOnlyToItsOwnAppAndOnlyWhileFresh() {
        let intent = ActivationFocusResolver.GlideFocusIntent(wid: 7, pid: 500, at: 10)
        XCTAssertTrue(ActivationFocusResolver.altTabIntentApplies(intent, activatedPid: 500, now: 10.05))
        XCTAssertFalse(ActivationFocusResolver.altTabIntentApplies(intent, activatedPid: 700, now: 10.05),
                       "another app's activation is not the one we caused")
        XCTAssertFalse(ActivationFocusResolver.altTabIntentApplies(
            intent, activatedPid: 500, now: 10 + ActivationFocusResolver.altTabIntentFailsafe),
                       "past the failsafe it is a later, unrelated activation")
        XCTAssertFalse(ActivationFocusResolver.altTabIntentApplies(nil, activatedPid: 500, now: 10))
    }

    // MARK: - axBackstopShouldApply

    func testBackstopAppliesBeforeFocus808() {
        // no 808 arrived yet (some activations emit none): the AX read is the only signal — apply it.
        XCTAssertTrue(ActivationFocusResolver.axBackstopShouldApply(entry()))
        XCTAssertTrue(ActivationFocusResolver.axBackstopShouldApply(nil))
    }

    func testBackstopYieldsAfterFocus808() {
        // the AX read races the app's internal focus update and can return the PREVIOUS window (iTerm,
        // #5596) — once the activation's focus 808 has spoken, the backstop must yield.
        XCTAssertFalse(ActivationFocusResolver.axBackstopShouldApply(entry(focusBumped: true)))
    }

    // MARK: - bounded focus recovery

    func testVisualFrontIsVerifiedEvenWhenAxFocusReadIsStale() {
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: true, focusedWid: 1, targetWid: 2,
            targetIsVisuallyFront: true, attempt: 0), .verified)
    }

    func testHalfSuccessRetriesExactlyOnce() {
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: true, focusedWid: 2, targetWid: 2,
            targetIsVisuallyFront: false, attempt: 0), .retry)
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: true, focusedWid: 2, targetWid: 2,
            targetIsVisuallyFront: false, attempt: 1), .failed)
    }

    func testUnknownAxFocusMayRetryOnce() {
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: true, focusedWid: nil, targetWid: 2,
            targetIsVisuallyFront: false, attempt: 0), .retry)
    }

    func testVerificationCancelsAfterUserMovesElsewhere() {
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: false, focusedWid: 2, targetWid: 2,
            targetIsVisuallyFront: false, attempt: 0), .cancelled)
        XCTAssertEqual(WindowFocusRetryPolicy.decide(appIsFrontmost: true, focusedWid: 3, targetWid: 2,
            targetIsVisuallyFront: false, attempt: 0), .cancelled)
    }
}
