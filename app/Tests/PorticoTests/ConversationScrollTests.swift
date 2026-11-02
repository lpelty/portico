import XCTest

@testable import Portico

/// v0.11 decision 6 (item 67): opening a file keeps the conversation where
/// it was: at the bottom stays at the bottom. Scrolled up, the scroll view
/// keeps the place itself (v0.14 fix; `ConversationRoundTripTests`).
final class ConversationScrollTests: XCTestCase {
    func testAtTheBottomStaysAtTheBottomWhenTheViewerNarrowsTheColumn() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: true, width: 900)
        XCTAssertEqual(memory.widthChanged(to: 460), .bottom)
    }

    func testScrolledUpIsLeftToTheScrollView() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: false, width: 900)
        XCTAssertNil(memory.widthChanged(to: 460), "no jump to the start of a remembered message (v0.14 fix)")
    }

    func testTheWidthChangeItselfIsNotTakenAsWhereThePersonIs() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: true, width: 900)
        _ = memory.widthChanged(to: 460)
        // The reflow put the view mid-transcript for a moment; that is not
        // recorded, so the next change still goes to the bottom.
        XCTAssertEqual(memory.widthChanged(to: 900), .bottom)
    }

    /// Fix round 1 (Important 2): scrolled up near the end, a frame of the
    /// column's reflow can read as "at the bottom". That reading is the
    /// reflow's, not the person's: the next width change must not snap
    /// the conversation to its end.
    func testAReadingDuringTheReflowIsNotTakenAsWhereThePersonIs() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: false), "the person, scrolled up")
        XCTAssertNil(memory.observe(width: 820, atBottom: true), "a reflow step that happens to read as the bottom")
        XCTAssertNil(memory.observe(width: 640, atBottom: true), "still the reflow: no snap to the end")
        XCTAssertNil(memory.observe(width: 900, atBottom: false), "and back: still none")
        // Settled at an unchanged width, the person's own readings count again.
        XCTAssertNil(memory.observe(width: 900, atBottom: true))
        XCTAssertEqual(memory.observe(width: 640, atBottom: false), .bottom, "at the bottom by the person's own scroll")
    }

    func testNoWidthChangeNoScroll() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.widthChanged(to: 900), "nothing is known before the first look")
        memory.seen(atBottom: false, width: 900)
        XCTAssertNil(memory.widthChanged(to: 900.4))
    }

    func testAtBottomAllowsALittleSlackAndShortContent() {
        XCTAssertTrue(ConversationScrollMemory.isAtBottom(offset: 0, visible: 600, content: 400))
        XCTAssertTrue(ConversationScrollMemory.isAtBottom(offset: 1390, visible: 600, content: 2000))
        XCTAssertFalse(ConversationScrollMemory.isAtBottom(offset: 1000, visible: 600, content: 2000))
    }

    /// v0.15 fix (task 2b): at the bottom, the narrowing scrolled to the
    /// end of the lazy stack's estimate; the stack then resolved its rows
    /// at the new width and the end moved, at an unchanged width. That
    /// reading is the layout's, not the person leaving the bottom.
    func testAtTheBottomAContentChangeAtTheSameWidthGoesBackToTheBottom() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, content: 7097))
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, content: 10098), .bottom, "the width step")
        XCTAssertEqual(
            memory.observe(width: 640, atBottom: false, content: 9075), .bottom,
            "the rows resolved, the end moved: back to it")
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, content: 9300), .bottom, "grew: back to it")
        XCTAssertTrue(memory.atBottom, "not recorded as scrolled up")
    }

    func testAtTheBottomThePersonScrollingUpIsRecorded() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, content: 7097))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, content: 7097), "the person scrolled up")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.widthChanged(to: 640), "and the scroll view keeps that place")
    }

    func testScrolledUpAContentChangeIsLeftAlone() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: false, content: 7097))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, content: 7400), "a new message below: no jump")
        XCTAssertNil(
            memory.observe(width: 900, atBottom: true, content: 7300),
            "a layout reading that happens to be at the end is not the person's")
        XCTAssertFalse(memory.atBottom, "still scrolled up")
    }
}
