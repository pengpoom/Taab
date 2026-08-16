import XCTest

final class GlideProductDefaultsTests: XCTestCase {
    func testPrimarySwitcherDefaultsToCommandTab() {
        XCTAssertEqual(GlideProductDefaults.switcherHoldShortcut, "⌘")
        XCTAssertEqual(GlideProductDefaults.switcherNextWindowShortcut, "⇥")
    }

    func testLocalBuildHidesLicenseSurfaces() {
        XCTAssertFalse(GlideProductDefaults.showsLicenseUI)
        XCTAssertFalse(GlideProductDefaults.showsFeatureTierBadges)
    }
}
