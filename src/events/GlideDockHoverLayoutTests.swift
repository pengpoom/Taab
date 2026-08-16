import XCTest

final class GlideDockHoverLayoutTests: XCTestCase {
    func testAllAppsModeAllowsOneOrMoreWindows() {
        XCTAssertFalse(GlideDockHoverPreviewMode.allApps.shouldShowPreview(windowCount: 0))
        XCTAssertTrue(GlideDockHoverPreviewMode.allApps.shouldShowPreview(windowCount: 1))
        XCTAssertTrue(GlideDockHoverPreviewMode.allApps.shouldShowPreview(windowCount: 2))
    }

    func testMultipleWindowsModeRequiresAtLeastTwoWindows() {
        XCTAssertFalse(GlideDockHoverPreviewMode.multipleWindowsOnly.shouldShowPreview(windowCount: 0))
        XCTAssertFalse(GlideDockHoverPreviewMode.multipleWindowsOnly.shouldShowPreview(windowCount: 1))
        XCTAssertTrue(GlideDockHoverPreviewMode.multipleWindowsOnly.shouldShowPreview(windowCount: 2))
    }

    func testDisabledModeNeverShowsPreview() {
        XCTAssertFalse(GlideDockHoverPreviewMode.disabled.shouldShowPreview(windowCount: 0))
        XCTAssertFalse(GlideDockHoverPreviewMode.disabled.shouldShowPreview(windowCount: 10))
    }

    func testQuartzToAppKitPointUsesPrimaryScreenTop() {
        XCTAssertEqual(
            GlideDockHoverLayout.appKitPoint(fromQuartz: CGPoint(x: -200, y: 140), primaryMaxY: 1080),
            CGPoint(x: -200, y: 940))
    }

    func testQuartzRectRoundTripsAcrossCoordinateSystems() {
        let original = CGRect(x: 120, y: 900, width: 64, height: 64)
        let appKit = GlideDockHoverLayout.appKitRect(fromQuartz: original, primaryMaxY: 1080)
        XCTAssertEqual(appKit, CGRect(x: 120, y: 116, width: 64, height: 64))
        XCTAssertEqual(GlideDockHoverLayout.quartzRect(fromAppKit: appKit, primaryMaxY: 1080), original)
    }

    func testResolvesAllThreeDockEdges() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(GlideDockHoverLayout.edge(for: CGRect(x: 680, y: 4, width: 64, height: 64), in: screen), .bottom)
        XCTAssertEqual(GlideDockHoverLayout.edge(for: CGRect(x: 4, y: 400, width: 64, height: 64), in: screen), .left)
        XCTAssertEqual(GlideDockHoverLayout.edge(for: CGRect(x: 1372, y: 400, width: 64, height: 64), in: screen), .right)
    }

    func testBottomPanelStaysInsideVisibleFrameNearScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 806)
        let frame = GlideDockHoverLayout.panelFrame(
            iconFrame: CGRect(x: 8, y: 4, width: 64, height: 64),
            screenFrame: screen,
            visibleFrame: visible,
            panelSize: CGSize(width: 700, height: 180),
            edge: .bottom)
        XCTAssertEqual(frame.minX, 10)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 10)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - 10)
    }

    func testTransitionRegionConnectsIconAndPanel() {
        let icon = CGRect(x: 500, y: 8, width: 64, height: 64)
        let panel = CGRect(x: 380, y: 82, width: 320, height: 180)
        let region = GlideDockHoverLayout.transitionRegion(iconFrame: icon, panelFrame: panel)
        XCTAssertTrue(region.contains(CGPoint(x: icon.midX, y: icon.midY)))
        XCTAssertTrue(region.contains(CGPoint(x: panel.midX, y: panel.midY)))
        XCTAssertTrue(region.contains(CGPoint(x: icon.midX, y: 77)))
    }
}
