import XCTest

final class GlideSidebarLayoutTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)

    func testOffHasNoFrame() {
        XCTAssertNil(GlideSidebarLayout.frame(in: screen, placement: .off))
    }

    func testLeftAnchorsInsideVisibleFrame() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .left),
            CGRect(x: 104, y: 54, width: 188, height: 892))
    }

    func testRightAnchorsInsideVisibleFrame() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .right),
            CGRect(x: 1348, y: 54, width: 188, height: 892))
    }

    func testNarrowScreenKeepsBothMargins() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertEqual(GlideSidebarLayout.frame(in: narrow, placement: .right),
            CGRect(x: 8, y: 4, width: 188, height: 292))
    }

    func testIdleModeWidths() {
        XCTAssertEqual(GlideSidebarLayout.width(for: .hidden, isPointerInside: false), 4)
        XCTAssertEqual(GlideSidebarLayout.width(for: .icons, isPointerInside: false), 48)
        XCTAssertEqual(GlideSidebarLayout.width(for: .expanded, isPointerInside: false), 188)
        XCTAssertEqual(GlideSidebarLayout.width(for: .hidden, isPointerInside: true), 188)
        XCTAssertEqual(GlideSidebarLayout.width(for: .icons, isPointerInside: true), 188)
    }

    func testRowHoverDoesNotReplaceTheFocusedState() {
        XCTAssertEqual(GlideSidebarLayout.rowVisualState(isFocused: false, isHovered: false), .normal)
        XCTAssertEqual(GlideSidebarLayout.rowVisualState(isFocused: false, isHovered: true), .hovered)
        XCTAssertEqual(GlideSidebarLayout.rowVisualState(isFocused: true, isHovered: false), .focused)
        XCTAssertEqual(GlideSidebarLayout.rowVisualState(isFocused: true, isHovered: true), .focusedHovered)
    }

    func testHiddenTriggerStaysFlushAndCenteredAtThePanelsFixedHeight() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .left,
            width: 4, height: 300, margin: 0),
            CGRect(x: 100, y: 350, width: 4, height: 300))
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .right,
            width: 4, height: 300, margin: 0),
            CGRect(x: 1536, y: 350, width: 4, height: 300))
    }

    func testHiddenActivationRegionCoversTheFixedScreenEdgeWithoutMovingThePanel() {
        XCTAssertEqual(GlideSidebarLayout.hiddenActivationFrame(in: screen, placement: .left),
            CGRect(x: 100, y: 50, width: 4, height: 900))
        XCTAssertEqual(GlideSidebarLayout.hiddenActivationFrame(in: screen, placement: .right),
            CGRect(x: 1536, y: 50, width: 4, height: 900))
        XCTAssertNil(GlideSidebarLayout.hiddenActivationFrame(in: screen, placement: .off))
    }

    func testContentHeightIsCenteredIdenticallyOnBothEdges() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .left,
            width: 188, height: 300),
            CGRect(x: 104, y: 350, width: 188, height: 300))
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .right,
            width: 188, height: 300),
            CGRect(x: 1348, y: 350, width: 188, height: 300))
    }
}
