import XCTest

final class GlideSidebarLayoutTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 50, width: 1440, height: 900)

    func testOffHasNoFrame() {
        XCTAssertNil(GlideSidebarLayout.frame(in: screen, placement: .off))
    }

    func testLeftAnchorsInsideVisibleFrame() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .left),
            CGRect(x: 108, y: 58, width: 260, height: 884))
    }

    func testRightAnchorsInsideVisibleFrame() {
        XCTAssertEqual(GlideSidebarLayout.frame(in: screen, placement: .right),
            CGRect(x: 1272, y: 58, width: 260, height: 884))
    }

    func testNarrowScreenKeepsBothMargins() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 300)
        XCTAssertEqual(GlideSidebarLayout.frame(in: narrow, placement: .right),
            CGRect(x: 8, y: 8, width: 184, height: 284))
    }
}
