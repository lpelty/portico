import AppKit
import XCTest
@testable import Portico

/// v0.26.6 (PORT-69): up to `TranscriptLayout.fullLimit` rows the transcript is laid out in
/// full, so its height is measured and does not move under the wheel.
final class TranscriptLayoutTests: XCTestCase {
    func testTheCapDecidesFullOrLazy() {
        XCTAssertTrue(TranscriptLayout.isFull(rows: 0))
        XCTAssertTrue(TranscriptLayout.isFull(rows: TranscriptLayout.fullLimit))
        XCTAssertFalse(TranscriptLayout.isFull(rows: TranscriptLayout.fullLimit + 1))
    }

    /// The field's shape (the 2026-11-13 report): a tall person row with images among many
    /// short tool runs and replies, a message sent and the reply awaited, then single wheel
    /// ticks upward. Lazily laid out, this conversation's height read 5797 pt and moved by
    /// hundreds of points between ticks; in full it holds one value.
    @MainActor func testTheContentHeightHoldsStillUnderTheWheel() throws {
        let chat = 9
        let images = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: images) }
        let suite = "portico-transcript-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var shapes: [EntryShape] = [
            EntryShape(id: "user:1", kind: .person, paragraphs: [80]),
            EntryShape(id: "assistant:1", kind: .reply, paragraphs: [300, 200]),
        ]
        var tall = EntryShape(id: "user:2", kind: .person, paragraphs: [900, 1200, 1500, 1100, 900, 700])
        tall.images = [[1600, 900], [600, 1500], [640, 200], [300, 90]]
        shapes.append(tall)
        for n in 0..<30 {
            shapes.append(EntryShape(id: "run:\(n)", kind: .toolRun, toolRows: 3 + n % 5))
            shapes.append(EntryShape(id: "assistant:\(n + 2)", kind: .reply, paragraphs: n % 4 == 0 ? [500, 300] : [140]))
        }
        XCTAssertLessThanOrEqual(shapes.count, TranscriptLayout.fullLimit)

        let model = try SyntheticConversation.model(chat: chat, shapes: shapes, images: images, defaults: defaults)
        let hosted = try ReplayRunner.host(model, defaults: defaults, size: NSSize(width: 1378, height: 880))
        defer { hosted.window.close() }
        ReplayRunner.spin(1.0)

        model.apply(.userText(UserText(
            chat: chat, turn: 500, text: "And one more question about the plan?", attachments: nil,
            seq: 90000, ts: "2026-11-01T10:00:00.000Z")))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: .working, created: "2026-11-01T09:00:00Z")])))
        // Long enough for the thumbnails to load: each replaces its placeholder once.
        ReplayRunner.spin(1.5)
        XCTAssertTrue(model.showsWorkingLine(chat: chat))

        func height() -> CGFloat { hosted.scroll.documentView?.frame.height ?? 0 }
        func offset() -> CGFloat { hosted.scroll.contentView.bounds.minY }
        let settled = height()
        let from = offset()
        XCTAssertGreaterThan(settled, 5000, "the conversation is several screens long")

        var heights: Set<Int> = [Int(settled)]
        for _ in 0..<120 {
            XCTAssertTrue(ReplayRunner.wheel(hosted, pixels: 26))
            ReplayRunner.spin(0.03)
            heights.insert(Int(height()))
        }
        ReplayRunner.spin(0.5)
        heights.insert(Int(height()))
        // The positive control: the wheel did move the view, well up the conversation.
        XCTAssertLessThan(offset(), from - 2000, "the wheel moved the view")
        XCTAssertEqual(heights, [Int(settled)], "the content's height moved under the wheel")
    }
}
