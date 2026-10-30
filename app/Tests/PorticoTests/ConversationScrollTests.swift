import XCTest

@testable import Portico

/// v0.11 decision 6 (item 67): opening a file keeps the conversation where
/// it was: at the bottom stays at the bottom, otherwise the same message
/// stays at the top.
final class ConversationScrollTests: XCTestCase {
    func testAtTheBottomStaysAtTheBottomWhenTheViewerNarrowsTheColumn() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: true, topItem: "assistant:7", width: 900)
        XCTAssertEqual(memory.widthChanged(to: 460), .bottom)
    }

    func testScrolledUpKeepsTheSameTopMessage() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: false, topItem: "tool:toolu_3", width: 900)
        XCTAssertEqual(memory.widthChanged(to: 460), .item("tool:toolu_3"))
    }

    func testTheWidthChangeItselfIsNotTakenAsWhereThePersonIs() {
        var memory = ConversationScrollMemory()
        memory.seen(atBottom: true, topItem: "assistant:7", width: 900)
        _ = memory.widthChanged(to: 460)
        // The reflow put the view mid-transcript for a moment; that is not
        // recorded, so the next change still goes to the bottom.
        XCTAssertEqual(memory.widthChanged(to: 900), .bottom)
    }

    func testNoWidthChangeNoScroll() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.widthChanged(to: 900), "nothing is known before the first look")
        memory.seen(atBottom: false, topItem: "user:1:2", width: 900)
        XCTAssertNil(memory.widthChanged(to: 900.4))
    }

    func testAtBottomAllowsALittleSlackAndShortContent() {
        XCTAssertTrue(ConversationScrollMemory.isAtBottom(offset: 0, visible: 600, content: 400))
        XCTAssertTrue(ConversationScrollMemory.isAtBottom(offset: 1390, visible: 600, content: 2000))
        XCTAssertFalse(ConversationScrollMemory.isAtBottom(offset: 1000, visible: 600, content: 2000))
    }
}
