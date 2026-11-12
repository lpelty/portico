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
        let others = Array(rows.others.values)
        XCTAssertFalse(
            TranscriptBlankSpace.isBlank(
                hasRows: true, rowFrames: Array(rows.frames.values), otherFrames: others, clip: clip,
                documentHeight: 2000),
            "calling cards and the working line in view are not blank space")
        XCTAssertEqual(rows.top()?.id, "item-2", "the kept place is a transcript row, never a calling card")
        rows.forgetOther("calling:card-1")
        rows.forgetOther("working")
        XCTAssertTrue(
            TranscriptBlankSpace.isBlank(
                hasRows: true, rowFrames: Array(rows.frames.values), otherFrames: Array(rows.others.values),
                clip: clip, documentHeight: 2000))
    }

    /// v0.26.4 (a field trace, 11-12): every transcript row was dropped by
    /// the lazy stack and the view sat at its estimated end; the cards drawn
    /// under the rows were still "in view", so the watch stayed quiet for
    /// seven minutes. With rows to draw and not one of them laid out, the
    /// view is blank whatever else reports a frame.
    func testNoTranscriptRowLaidOutIsBlankEvenWithACardInView() {
        let cards = [CGRect(x: 0, y: 20, width: 600, height: 120)]
        XCTAssertTrue(TranscriptBlankSpace.isBlank(
            hasRows: true, rowFrames: [], otherFrames: cards, clip: clip, documentHeight: 2000))
    }

    /// Rows laid out but scrolled out of view, a card in view: not blank
    /// (the person is looking at the cards under the conversation).
    func testACardInViewWithRowsLaidOutElsewhereIsNotBlank() {
        let rows = [CGRect(x: 0, y: -300, width: 600, height: 80)]
        let cards = [CGRect(x: 0, y: 20, width: 600, height: 120)]
        XCTAssertFalse(TranscriptBlankSpace.isBlank(
            hasRows: true, rowFrames: rows, otherFrames: cards, clip: clip, documentHeight: 2000))
    }

    /// The heal is for rows that were laid out and then all dropped: a
    /// conversation still opening has reported no row yet and is left alone.
    @MainActor
    func testRowFramesRememberThatARowWasEverReported() {
        let rows = TranscriptRowFrames()
        XCTAssertFalse(rows.hasReported)
        rows.noteOther(CGRect(x: 0, y: 20, width: 600, height: 24), id: "working")
        XCTAssertFalse(rows.hasReported, "a card or the working line is not a row")
        rows.note(CGRect(x: 0, y: 100, width: 600, height: 80), id: "item-1")
        rows.forget("item-1")
        XCTAssertTrue(rows.frames.isEmpty)
        XCTAssertTrue(rows.hasReported)
    }

    /// A heal that did not bring a row back is tried again after another
    /// grace, three times at most.
    func testTheWatchAllowsThreeHeals() {
        var watch = TranscriptBlankSpace.Watch()
        var now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: now))
        for attempt in 1...3 {
            now += 1.5
            XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: now), "report \(attempt)")
            XCTAssertTrue(watch.mayHeal, "heal \(attempt)")
            watch.healed(now: now)
            XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: now + 0.5), "within the grace again")
        }
        now += 1.5
        XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: now), "still reported")
        XCTAssertFalse(watch.mayHeal, "no fourth heal")
    }

    /// Review round 2: a row that comes back for one reading and drops again
    /// (the heal's own id scroll could do that) does not start the count
    /// again; three heals are the limit however the readings alternate.
    func testARowBackForAMomentDoesNotBuyMoreHeals() {
        var watch = TranscriptBlankSpace.Watch()
        var now = Date(timeIntervalSince1970: 1000)
        var heals = 0
        for _ in 1...10 {
            XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: now))
            now += 1.5
            XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: now))
            if watch.mayHeal { watch.healed(now: now); heals += 1 }
            now += 0.5
            XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now), "a row for one reading")
            now += 0.5
        }
        XCTAssertEqual(heals, 3)
        XCTAssertFalse(watch.mayHeal)
    }

    /// The count starts again once rows have been shown for ten seconds on
    /// end; a blank reading in between starts those ten seconds over.
    func testTheHealCountStartsAgainOnceTheViewHasSettled() {
        var watch = TranscriptBlankSpace.Watch()
        var now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: now))
        for _ in 1...3 {
            now += 1.5
            XCTAssertTrue(watch.observe(blank: true, scrolling: false, now: now))
            watch.healed(now: now)
        }
        XCTAssertFalse(watch.mayHeal)
        now += 0.5
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now))
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now + 9))
        XCTAssertFalse(watch.mayHeal, "nine seconds is not settled")
        XCTAssertFalse(watch.observe(blank: true, scrolling: false, now: now + 9.5))
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now + 10))
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now + 19))
        XCTAssertFalse(watch.mayHeal, "the blank reading started the ten seconds over")
        XCTAssertFalse(watch.observe(blank: false, scrolling: false, now: now + 20))
        XCTAssertTrue(watch.mayHeal, "rows shown for ten seconds on end")
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

    /// v0.26.2: a view left past the document's end goes back to the end.
    func testAViewPastTheEndGoesBackToTheEnd() {
        let clip = CGRect(x: 0, y: 10017, width: 792, height: 700)
        XCTAssertEqual(TranscriptBlankSpace.pastEnd(clip: clip, documentHeight: 7754), 7054)
    }

    func testAViewInsideTheContentStays() {
        XCTAssertNil(TranscriptBlankSpace.pastEnd(clip: CGRect(x: 0, y: 1300, width: 792, height: 700), documentHeight: 2000))
        // Rubber-banding and rounding: within the slack.
        XCTAssertNil(TranscriptBlankSpace.pastEnd(clip: CGRect(x: 0, y: 1300.5, width: 792, height: 700), documentHeight: 2000))
    }

    func testShortContentGoesToTheTop() {
        XCTAssertEqual(TranscriptBlankSpace.pastEnd(clip: CGRect(x: 0, y: 900, width: 792, height: 700), documentHeight: 400), 0)
    }
}
