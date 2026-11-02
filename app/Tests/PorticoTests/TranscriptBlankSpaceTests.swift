import XCTest

@testable import Portico

final class TranscriptBlankSpaceTests: XCTestCase {
    private let clip = CGRect(x: 0, y: 500, width: 600, height: 400)

    func testRowsInViewAreNotBlank() {
        let rows = [CGRect(x: 0, y: 100, width: 600, height: 80)]
        XCTAssertFalse(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows, clip: clip, documentHeight: 2000))
    }

    func testNoRowInViewIsBlank() {
        let rows = [CGRect(x: 0, y: -300, width: 600, height: 80), CGRect(x: 0, y: 450, width: 600, height: 80)]
        XCTAssertTrue(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows, clip: clip, documentHeight: 2000))
    }

    func testNoReportedRowsWithRowsToDrawIsBlank() {
        XCTAssertTrue(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: [], clip: clip, documentHeight: 2000))
    }

    func testAnEmptyConversationIsNeverBlank() {
        XCTAssertFalse(TranscriptBlankSpace.isBlank(hasRows: false, rowFrames: [], clip: clip, documentHeight: 0))
    }

    func testClipPastTheDocumentsEndIsBlankEvenWithARowInView() {
        let rows = [CGRect(x: 0, y: 10, width: 600, height: 80)]
        XCTAssertTrue(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows, clip: clip, documentHeight: 700))
        XCTAssertFalse(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows, clip: clip, documentHeight: 900))
        // Within the slack (rounding) is not past the end.
        XCTAssertFalse(TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows, clip: clip, documentHeight: 899.5))
    }

    /// A view that shows only the calling cards and the working line under
    /// rows scrolled out of view is not blank: those report their frames
    /// too, but never become the place a conversation keeps.
    @MainActor
    func testCallingCardsAndTheWorkingLineCountAsDrawnButNotAsThePlace() {
        let rows = TranscriptRowFrames()
        rows.note(CGRect(x: 0, y: -400, width: 600, height: 80), id: "item-1")
        rows.note(CGRect(x: 0, y: 900, width: 600, height: 80), id: "item-2")
        rows.noteOther(CGRect(x: 0, y: 20, width: 600, height: 120), id: "calling:card-1")
        rows.noteOther(CGRect(x: 0, y: 160, width: 600, height: 24), id: "working")
        XCTAssertEqual(rows.allFrames.count, 4)
        XCTAssertFalse(
            TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows.allFrames, clip: clip, documentHeight: 2000),
            "calling cards and the working line in view are not blank space")
        XCTAssertEqual(rows.top()?.id, "item-2", "the kept place is a transcript row, never a calling card")
        rows.forgetOther("calling:card-1")
        rows.forgetOther("working")
        XCTAssertTrue(
            TranscriptBlankSpace.isBlank(hasRows: true, rowFrames: rows.allFrames, clip: clip, documentHeight: 2000))
    }

    func testWatchReportsOncePerOccurrenceAfterTheGrace() {
        var watch = TranscriptBlankSpace.Watch()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0))
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0 + 1))  // exactly the grace: not over it
        XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: t0 + 1.5))
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0 + 5))  // same occurrence
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: t0 + 6))  // clears
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0 + 7))
        XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: t0 + 8.5))  // a new occurrence
    }

    func testAScrollPhaseEndsTheOccurrence() {
        var watch = TranscriptBlankSpace.Watch()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0))
        XCTAssertFalse(watch.observe(blank: true, scrolling: true, now: t0 + 2))
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: t0 + 2.5))  // the clock restarts
        XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: t0 + 4))
    }

    func testTheLineNamesWhatTheFieldReportNeeds() {
        let line = TranscriptBlankSpace.line(
            chat: 3, documentHeight: 1234.6, clip: clip, lastRow: CGRect(x: 0, y: 600, width: 580, height: 90),
            phase: "idle", atBottomEdge: true)
        XCTAssertEqual(
            line,
            "blank space under the conversation: chat 3, document height 1234, clip (x 0, y 500, w 600, h 400), "
                + "last row (x 0, y 600, w 580, h 90), scroll phase idle, position at bottom edge yes")
        XCTAssertTrue(
            TranscriptBlankSpace.line(chat: 1, documentHeight: 0, clip: .zero, lastRow: nil, phase: "idle", atBottomEdge: false)
                .contains("last row none"))
    }
}
