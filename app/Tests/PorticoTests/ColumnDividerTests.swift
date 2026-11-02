import XCTest
@testable import Portico

/// v0.14 (§6b.2): the viewer divider's grip sits wholly on the
/// conversation side, so the web view beside it can't take half of it.
/// The sidebar divider keeps its grip centred on the line.
final class ColumnDividerTests: XCTestCase {
    /// The grip's span across the 1-point line, in the line's own
    /// coordinates (the line runs 0...1).
    func testCentredGripStraddlesTheLine() {
        let span = ColumnDivider.gripSpan(.centred)
        XCTAssertEqual(span.lowerBound, -6.5)
        XCTAssertEqual(span.upperBound, 7.5)
        XCTAssertEqual(span.upperBound - span.lowerBound, 14)
    }

    func testLeadingGripEndsAtTheLinesFarEdge() {
        let span = ColumnDivider.gripSpan(.leading)
        XCTAssertEqual(span.upperBound, 1, "nothing past the line, over the viewer")
        XCTAssertEqual(span.lowerBound, -13, "the rest over the conversation")
        XCTAssertEqual(span.upperBound - span.lowerBound, 14, "the same 14-point grip")
    }

    func testTrailingGripStartsAtTheLinesNearEdge() {
        let span = ColumnDivider.gripSpan(.trailing)
        XCTAssertEqual(span.lowerBound, 0)
        XCTAssertEqual(span.upperBound, 14)
    }

    func testDefaultIsCentred() {
        let divider = ColumnDivider(onDrag: { _ in }, onEnd: {}, onReset: {})
        XCTAssertEqual(divider.gripSide, .centred, "the sidebar divider is unchanged")
    }

    func testTheViewerDividerGripsOnTheConversationSide() {
        XCTAssertEqual(MainWindow.viewerDividerGripSide, .leading)
    }
}
