import XCTest
@testable import Portico

/// v0.26 (PORT-12, ZG3): the conversation markers' layout.
final class ConversationMarkersTests: XCTestCase {
    private func user(_ turn: Int, _ text: String, ts: String = "2026-11-08T14:05:00Z", noTime: Bool? = nil) -> TranscriptEntry {
        var u = UserText(chat: 1, turn: turn, text: text)
        u.ts = ts
        u.noTime = noTime
        return .item(.userText(u))
    }

    private func reply(_ id: String) -> TranscriptEntry { .item(.assistantText(id: id, text: "Reply \(id)")) }

    func testOneMarkerPerPersonMessageAndNoneForReplies() {
        let entries = [user(1, "One"), reply("a"), user(2, "Two"), reply("b"), user(3, "Three"), reply("c")]
        let markers = ConversationMarkers.markers(entries, briefID: nil)
        XCTAssertEqual(markers.map(\.id), [entries[0].id, entries[2].id, entries[4].id])
        XCTAssertEqual(markers.map(\.snippet), ["One", "Two", "Three"])
        XCTAssertEqual(markers.map(\.reply), ["Reply a", "Reply b", "Reply c"])
    }

    /// The tip's second part: the first two lines of the agent's reply to that message,
    /// none while there is no reply yet; the person's message is one line.
    func testEachMarkerCarriesTheStartOfItsReply() {
        let entries = [user(1, "Rewrite step 2\nso it says why"), .item(.assistantText(id: "a", text: "Two drafts.\n\nOne is short.\nThird line")),
                       .item(.assistantText(id: "b", text: "Later text")), user(2, "Two"), user(3, "Three")]
        let markers = ConversationMarkers.markers(entries, briefID: nil)
        XCTAssertEqual(markers.map(\.snippet), ["Rewrite step 2 so it says why", "Two", "Three"])
        XCTAssertEqual(markers.map(\.reply), ["Two drafts. One is short.", nil, nil])
    }

    func testTheBriefHasNoMarker() {
        let entries = [user(1, "Review the pricing page."), reply("a"), user(2, "Two")]
        let markers = ConversationMarkers.markers(entries, briefID: entries[0].id)
        XCTAssertEqual(markers.map(\.id), [entries[2].id])
    }

    func testHiddenBelowThreeMessages() {
        let entries = [user(1, "One"), reply("a"), user(2, "Two")]
        XCTAssertEqual(ConversationMarkers.markers(entries, briefID: nil).count, 2)
        XCTAssertFalse(ConversationMarkers.shown(count: 2))
        XCTAssertTrue(ConversationMarkers.shown(count: 3))
    }

    /// A tight stack, 8 pt apart, centred on the chat's height (Larry's reference).
    func testMarksAreATightStackCentred() {
        let s = ConversationMarkers.slots(count: 5, height: 424, inView: [], hovered: nil)
        XCTAssertEqual(s.map(\.y), [196, 204, 212, 220, 228])
        XCTAssertTrue(s.allSatisfy(\.drawn))
    }

    /// Past 40% of the height (169.6 pt at 424): every other, then every fourth …
    func testThinningEveryOtherThenEveryFourth() {
        XCTAssertEqual(ConversationMarkers.stride(count: 20, height: 424), 1)   // 152 pt
        XCTAssertEqual(ConversationMarkers.stride(count: 30, height: 424), 2)   // 232 → 112
        XCTAssertEqual(ConversationMarkers.stride(count: 50, height: 424), 4)
        XCTAssertEqual(ConversationMarkers.stride(count: 100, height: 424), 8)
        let s = ConversationMarkers.slots(count: 50, height: 424, inView: [], hovered: nil).filter(\.drawn)
        for (a, b) in zip(s, s.dropFirst()) { XCTAssertEqual(b.y - a.y, 8, accuracy: 0.001) }
        XCTAssertLessThanOrEqual(s.last!.y - s.first!.y, 424 * 0.4)
        XCTAssertEqual((s.first!.y + s.last!.y) / 2, 212, accuracy: 8)
    }

    func testHoveredAndInViewMarksAreAlwaysDrawn() {
        let s = ConversationMarkers.slots(count: 200, height: 424, inView: [37], hovered: 101)
        XCTAssertTrue(s[37].drawn); XCTAssertEqual(s[37].style, .inView)
        XCTAssertTrue(s[101].drawn); XCTAssertEqual(s[101].style, .hovered)
        XCTAssertFalse(s[1].drawn)
        XCTAssertTrue(s[32].drawn); XCTAssertEqual(s[32].style, .normal)  // stride 16 at 200 marks
        XCTAssertEqual(MarkerSlot.Style.normal.length, 10)
        XCTAssertEqual(MarkerSlot.Style.inView.length, 14)
        XCTAssertEqual(MarkerSlot.Style.hovered.length, 22)
    }

    func testNearestIsADrawnMark() {
        let s = ConversationMarkers.slots(count: 200, height: 424, inView: [], hovered: nil)
        // Index 1 isn't drawn: the nearest drawn mark to its y is index 0.
        XCTAssertEqual(ConversationMarkers.nearest(s[1].y, in: s), 0)
        XCTAssertEqual(ConversationMarkers.nearest(500, in: s), s.last { $0.drawn }?.index)
        XCTAssertNil(ConversationMarkers.nearest(10, in: []))
    }

    func testSnippetIsTheFirstTwoLines() {
        XCTAssertEqual(ConversationMarkers.snippet("Rewrite step 2\n\nso it says why\nthird"), "Rewrite step 2 so it says why")
        XCTAssertEqual(ConversationMarkers.snippet("  One line  "), "One line")
    }

    func testMarkerTipHasNoTimeWhenTheMessageHasNone() throws {
        let now = try XCTUnwrap(SessionTime.parse("2026-11-08T15:00:00Z"))
        XCTAssertEqual(ConversationMarkers.tipFooter(nil, now: now), "Click to go back")
        let markers = ConversationMarkers.markers([user(1, "Hi", noTime: true), user(2, "There")], briefID: nil)
        XCTAssertNil(markers[0].at)
        XCTAssertNotNil(markers[1].at)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let at = try XCTUnwrap(SessionTime.parse("2026-11-07T14:05:00Z"))
        XCTAssertEqual(
            ConversationMarkers.tipFooter(at, now: now, calendar: calendar, locale: Locale(identifier: "en_US")),
            "Yesterday 2:05 PM · Click to go back")
    }

    func testAJumpLeavesTheBottom() {
        var memory = ConversationScrollMemory()
        memory.followed()
        memory.jumped()
        XCTAssertFalse(memory.atBottom)
    }

    func testTheHighlightIsTheSoftAccentForABriefMoment() {
        XCTAssertEqual(UserBubble.fill(highlighted: true), Theme.accentSoft)
        XCTAssertEqual(UserBubble.fill(highlighted: false), Theme.surface)
        XCTAssertEqual(ConversationView.highlightDuration, .milliseconds(1200))
    }

    func testMarkColoursAreTheReferences() {
        XCTAssertEqual(MarkerRail.colour(.normal), Theme.text3)
        XCTAssertEqual(MarkerRail.colour(.inView), Theme.text2)
        XCTAssertEqual(MarkerRail.colour(.hovered), Theme.text)
    }

    /// Larry 2026-11-08 (ZG3/ZG3b): 10 pt from the pane's edge, the hovered mark ending at the
    /// 32 pt side margin, so the rail never covers the reading column.
    func testTheRailSitsInTheSideMargin() {
        XCTAssertEqual(ConversationView.railLeading, 10)
        XCTAssertEqual(ConversationView.railLeading + MarkerSlot.Style.hovered.length, ConversationView.sideInset)
    }

    // MARK: - review H2: cheap on long conversations

    @MainActor
    func testFiveThousandExchangesStayCheap() {
        let reply = String(repeating: "A long reply line that goes on for a while.\n", count: 120)  // ~5 KB
        var entries: [TranscriptEntry] = []
        for turn in 1...5_000 {
            entries.append(user(turn, "Question \(turn)\nwith a second line\nand a third"))
            entries.append(.item(.assistantText(id: "a\(turn)", text: reply)))
        }
        let index = MarkerIndex()
        var asked = 0
        let first = Date()
        let markers = index.markers(key: "r1", entries: { asked += 1; return entries }, briefID: nil)
        let built = Date().timeIntervalSince(first)
        XCTAssertEqual(markers.count, 5_000)
        XCTAssertLessThan(built, 0.25, "one pass over 10,000 items, no text split")
        // A scroll reading or a redraw at the same revision does no work.
        let again = Date()
        for _ in 0..<100 {
            _ = index.markers(key: "r1", entries: { asked += 1; return entries }, briefID: nil)
        }
        let frames = Dictionary(uniqueKeysWithValues: (0..<40).map { (markers[$0 * 10].id, CGRect(x: 0, y: CGFloat($0) * 20, width: 10, height: 18)) })
        for _ in 0..<100 { _ = index.inView(frames: frames, visible: 600) }
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.05)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(index.builds, 1)
        _ = index.markers(key: "r2", entries: { asked += 1; return entries }, briefID: nil)
        XCTAssertEqual(index.builds, 2, "a new revision rebuilds")
    }

    func testTheSnippetReadsOnlyTheStart() {
        let huge = String(repeating: "word ", count: 400_000)  // 2 MB on one line
        let start = Date()
        let snippet = ConversationMarkers.snippet(huge)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertLessThanOrEqual(snippet.count, ConversationMarkers.maxSnippetLength)
        XCTAssertTrue(snippet.hasPrefix("word word"))
        let marker = ConversationMarker(id: "u", text: "One\n\nTwo\nThree", replyText: "R1\nR2\nR3", at: nil)
        XCTAssertEqual(marker.snippet, "One Two Three")
        XCTAssertEqual(marker.reply, "R1 R2")
        XCTAssertEqual(MarkerRail.spokenLabel(index: 2, count: 40), "Your message 3 of 40")
    }
}
