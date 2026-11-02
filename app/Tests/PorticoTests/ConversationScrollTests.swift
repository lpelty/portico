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
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true), "the person, scrolled up")
        XCTAssertNil(memory.observe(width: 820, atBottom: true, userPositioned: false), "a reflow step that happens to read as the bottom")
        XCTAssertNil(memory.observe(width: 640, atBottom: true, userPositioned: false), "still the reflow: no snap to the end")
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false), "and back: still none")
        // The person's own scroll at an unchanged width counts again.
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: true))
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, userPositioned: false), .bottom, "at the bottom by the person's own scroll")
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

    /// v0.15 fix (task 2b), the hosted readings at 640: the width step
    /// scrolled to the end of the lazy stack's estimate; the rows then
    /// resolved at the new width and the end moved, at an unchanged width.
    /// That reading is the layout's, not the person leaving the bottom.
    func testAtTheBottomTheLayoutMovingTheEndGoesBackToTheBottom() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 673, atBottom: true, userPositioned: false), "the first look")
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, userPositioned: false), .bottom, "the width step")
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, userPositioned: false), .bottom, "the rows resolved: back to the end")
        XCTAssertTrue(memory.atBottom, "not recorded as scrolled up")
        XCTAssertEqual(memory.observe(width: 900, atBottom: false, userPositioned: false), .bottom, "and back to Work")
    }

    func testAtTheBottomThePersonScrollingUpIsRecorded() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true), "the person scrolled up")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.widthChanged(to: 640), "and the scroll view keeps that place")
    }

    /// Fix round 1 (Important 2): a reply streams while the person scrolls
    /// up; the reading is theirs (the scroll phase), however the content moved.
    func testAtTheBottomThePersonScrollingUpWhileAReplyStreamsIsRecorded() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true), "streamed and scrolled up: no pull back")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false), "the next streamed rows: left alone")
    }

    func testAtTheBottomStreamingGoesBackToTheBottom() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false))
        XCTAssertEqual(memory.observe(width: 900, atBottom: false, userPositioned: false), .bottom, "the reply grew past the end")
        XCTAssertTrue(memory.atBottom)
    }

    func testScrolledUpALayoutReadingIsLeftAlone() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false), "a new message below: no jump")
        // A re-estimate that happens to put the view at the end is the
        // layout's, like a reflow step (fix round 1). The app's own jumps
        // to the end are recorded through `followed()`.
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false))
        XCTAssertFalse(memory.atBottom, "still scrolled up")
    }

    /// Fix round 1 (Important 1): the app's own follow to the end (the
    /// person's send) is recorded, so the next narrowing keeps it there.
    func testScrolledUpThenTheAppFollowsToTheBottomTheNextWidthChangeGoesToTheBottom() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true))
        memory.followed()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false), "the jump's reading")
        XCTAssertTrue(memory.atBottom)
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, userPositioned: false), .bottom)
    }

    /// Fix round 3 (I2): back at the end while a reply streams, a reading
    /// still marked as the person's lands off the end because the content
    /// grew. It moved down, not up: the layout's, so back to the bottom.
    func testThePersonsReadingMovingDownWhileTheContentGrowsGoesBackToTheBottom() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: true, offset: 6595))
        XCTAssertEqual(
            memory.observe(width: 900, atBottom: false, userPositioned: true, offset: 6610), .bottom, "moved down, streamed past")
        XCTAssertEqual(memory.observe(width: 900, atBottom: false, userPositioned: true, offset: 6610), .bottom, "did not move")
        XCTAssertTrue(memory.atBottom, "still following")
    }

    func testThePersonsReadingMovingUpIsRecorded() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: true, offset: 6595))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true, offset: 6400), "scrolled up")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true, offset: 6500), "down a little: still up")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: true, offset: 6595), "back at the end")
        XCTAssertTrue(memory.atBottom)
    }

    /// Fix round 4 (N1): an up mark (Page Up, a wheel toward the top) counts
    /// for every reading moving up within its span, and ignores readings
    /// moving down or not at all (a reply delta, SwiftUI's settling): no
    /// go-back-to-the-bottom, and the mark is not spent by them.
    func testAnUpMarkIgnoresReadingsMovingDownAndRecordsThoseMovingUp() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false, offset: 6595))
        XCTAssertNil(
            memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .up, offset: 6620),
            "a delta before the key's first frame: ignored, not .bottom")
        XCTAssertTrue(memory.atBottom, "not recorded")
        XCTAssertNil(
            memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .up, offset: 6620), "nor one not moving")
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .up, offset: 6400), "the key's frame")
        XCTAssertFalse(memory.atBottom, "scrolled up")
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .up, offset: 6450), "settling down")
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .up, offset: 6100), "the next frame")
        XCTAssertFalse(memory.atBottom)
    }

    /// Fix round 4 (N1): a down mark (Page Down, End, a wheel toward the
    /// end) reaching the end over several animated frames goes back to
    /// following; a reading moving up under it (SwiftUI putting its own
    /// offset back) is the layout's, never the person's.
    func testADownMarkReachingTheEndFollowsAgain() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: true, offset: 5000))
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .down, offset: 5300), "first frame")
        XCTAssertNil(
            memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .down, offset: 5250), "settling up: not the person's")
        XCTAssertFalse(memory.atBottom)
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false, marked: .down, offset: 5595), "at the end")
        XCTAssertTrue(memory.atBottom, "following again")
        XCTAssertEqual(
            memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .down, offset: 5595), .bottom,
            "the reply grew past the end")
        XCTAssertEqual(
            memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .down, offset: 5550), .bottom,
            "SwiftUI putting its own offset back: the layout's, back to the end")
        XCTAssertTrue(memory.atBottom, "not taken for the person scrolling up")
        XCTAssertEqual(memory.observe(width: 640, atBottom: false, userPositioned: false, offset: 5595), .bottom, "a width change")
    }

    /// Fix round 4 (N1): VoiceOver's cursor marks `.either`: readings either way are the person's.
    func testAnEitherMarkAcceptsBothWays() {
        var memory = ConversationScrollMemory()
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false, offset: 6595))
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, marked: .either, offset: 6000))
        XCTAssertFalse(memory.atBottom, "up")
        XCTAssertNil(memory.observe(width: 900, atBottom: true, userPositioned: false, marked: .either, offset: 6595))
        XCTAssertTrue(memory.atBottom, "down to the end")
    }

    /// v0.16 §5: a place put back is scrolled up until the person scrolls;
    /// a layout reading off the end does not send it to the bottom.
    func testAPlacePutBackScrolledUpIsLeftAlone() {
        var memory = ConversationScrollMemory()
        memory.restored(atBottom: false)
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, offset: 3500), "the first look")
        XCTAssertNil(memory.observe(width: 900, atBottom: false, userPositioned: false, offset: 3600), "the restore's correction")
        XCTAssertFalse(memory.atBottom)
    }

    /// v0.16 §5: each conversation keeps its own place in the model.
    @MainActor
    func testEachConversationsPlaceIsKeptApart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-place-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        XCTAssertNil(model.place(of: 3), "never shown")
        model.notePlace(ConversationPlace(atBottom: false, topItem: "assistant:17", topOffset: -40), chat: 3)
        model.notePlace(ConversationPlace(atBottom: true, topItem: nil), chat: 5)
        XCTAssertEqual(model.place(of: 3), ConversationPlace(atBottom: false, topItem: "assistant:17", topOffset: -40))
        XCTAssertEqual(model.place(of: 5)?.atBottom, true)
    }
}
