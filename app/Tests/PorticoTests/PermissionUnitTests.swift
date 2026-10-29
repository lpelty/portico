import Foundation
import XCTest

@testable import Portico

/// V1, one permission unit: while asking, the tool row reads "waiting for
/// your OK" and one card is pinned above the composer, with no copy in
/// the transcript; after the answer the card goes and the outcome is drawn
/// on the row — from the app's own answer at once, from `card.answered`,
/// and from `tool.finished.permission`, live and in a replay. Model-only.
@MainActor
final class PermissionUnitTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    private func start(_ id: String, tool: String = "Write", seq: Int) -> ServerMessage {
        .toolStarted(ToolStarted(chat: 1, turn: 1, toolUseId: id, tool: tool, summary: "/tmp/demo/Q3-synthesis.md", input: [:], seq: seq))
    }

    private func ask(_ card: String, tool toolUseId: String, seq: Int) -> CardAsk {
        CardAsk(
            chat: 1, id: card, kind: .permission, title: "Save changes to Q3-synthesis.md?",
            permission: Permission(tool: "Write", summary: "/tmp/demo/Q3-synthesis.md", input: [:]),
            questions: nil, form: nil, toolUseId: toolUseId, seq: seq)
    }

    private func row(_ model: AppModel, _ id: String) -> ToolRow? {
        for item in model.transcripts[1] ?? [] {
            if case .tool(let row) = item, row.toolUseId == id { return row }
        }
        return nil
    }

    private func cards(_ model: AppModel) -> Int {
        (model.transcripts[1] ?? []).filter { if case .card = $0 { true } else { false } }.count
    }

    func testAskingPinsOneCardAndTheRowWaits() throws {
        let (model, _) = model()
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        model.apply(start("tu-1", seq: 2))
        let card = ask("card-1", tool: "tu-1", seq: 3)
        model.apply(.cardAsk(card))

        XCTAssertEqual(model.pinnedCards(for: 1).map(\.id), ["card-1"], "one card, pinned")
        XCTAssertEqual(cards(model), 0, "no inline duplicate")
        XCTAssertEqual(model.permissionCard(chat: 1, toolUseId: "tu-1")?.id, "card-1")
        let waiting = ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1")))
        XCTAssertEqual(waiting.outcomeText(waiting: true), "waiting for your OK")
        XCTAssertEqual(waiting.outcomeTone(waiting: true), .wait)
        XCTAssertNil(waiting.outcomeText(waiting: false), "nothing decided yet")
    }

    func testAllowOnceIsDrawnOnTheRowAtOnceAndTheCardLeavesNothing() throws {
        let (model, sent) = model()
        model.apply(start("tu-1", seq: 1))
        let card = ask("card-1", tool: "tu-1", seq: 2)
        model.apply(.cardAsk(card))
        model.answerCard(PermissionChoice.allowOnce.answer(for: card))

        guard case .cardAnswer(let answer)? = sent.frames.last else { return XCTFail("expected card.answer") }
        XCTAssertEqual(answer.scope, .once)
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertNil(model.permissionCard(chat: 1, toolUseId: "tu-1"), "the row no longer waits")
        XCTAssertEqual(row(model, "tu-1")?.permission, .once, "drawn before the gateway confirms")

        model.apply(.cardAnswered(CardAnswered(chat: 1, id: "card-1", toolUseId: "tu-1", outcome: .once, seq: 3)))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-1", ok: true, summary: "ok", permission: .once, seq: 4)))
        XCTAssertEqual(cards(model), 0, "no separate answered card")
        XCTAssertEqual(ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1"))).outcomeText(waiting: false), "allowed once")
    }

    func testAllowForThisSessionAndAutoRead() throws {
        let (model, _) = model()
        model.apply(start("tu-1", seq: 1))
        let card = ask("card-1", tool: "tu-1", seq: 2)
        model.apply(.cardAsk(card))
        model.answerCard(PermissionChoice.allowSession.answer(for: card))
        XCTAssertEqual(row(model, "tu-1")?.permission, .session)
        XCTAssertEqual(ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1"))).outcomeText(waiting: false), "allowed for this session")

        // A later identical step the session allow covered: no card, the finish says so.
        model.apply(start("tu-2", seq: 3))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-2", ok: true, summary: "ok", permission: .session, seq: 4)))
        XCTAssertEqual(row(model, "tu-2")?.permission, .session)

        // Auto mode: no card at all; the row says auto.
        model.apply(start("tu-3", tool: "Bash", seq: 5))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-3", ok: true, summary: "ok", permission: .auto, seq: 6)))
        let auto = ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-3")))
        XCTAssertEqual(auto.outcomeText(waiting: false), "auto")
        XCTAssertEqual(auto.outcomeTone(waiting: false), .quiet)
    }

    func testDenyCarriesTheNoteOntoTheRowInRed() throws {
        let (model, sent) = model()
        model.apply(start("tu-1", seq: 1))
        let card = ask("card-1", tool: "tu-1", seq: 2)
        model.apply(.cardAsk(card))
        model.answerCard(PermissionChoice.deny.answer(for: card, note: "Put it in drafts/ instead"))

        guard case .cardAnswer(let answer)? = sent.frames.last else { return XCTFail("expected card.answer") }
        XCTAssertEqual(answer.answer, ["decision": .string("deny")])
        XCTAssertEqual(answer.note, "Put it in drafts/ instead")
        var shown = ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1")))
        XCTAssertEqual(shown.outcomeText(waiting: false), "declined")
        XCTAssertEqual(shown.outcomeTone(waiting: false), .deny)
        XCTAssertEqual(shown.noteLine, "Your note: Put it in drafts/ instead")

        // The gateway's closing and the failed finish keep the note.
        model.apply(.cardAnswered(CardAnswered(chat: 1, id: "card-1", toolUseId: "tu-1", outcome: .declined, note: "Put it in drafts/ instead", seq: 3)))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-1", ok: false, summary: "denied", permission: .declined, note: "Put it in drafts/ instead", seq: 4)))
        shown = ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1")))
        XCTAssertEqual(shown.noteLine, "Your note: Put it in drafts/ instead")
    }

    func testBlockedByAutoMode() throws {
        let (model, _) = model()
        model.apply(start("tu-1", tool: "Bash", seq: 1))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-1", ok: false, summary: "Permission denied", permission: .blocked, seq: 2)))
        let shown = ToolRowPresentation(row: try XCTUnwrap(row(model, "tu-1")))
        XCTAssertEqual(shown.outcomeText(waiting: false), "blocked by auto mode")
        XCTAssertEqual(shown.outcomeTone(waiting: false), .deny)
        XCTAssertNil(shown.noteLine)
    }

    func testReplayDrawsOutcomesAndPinsNothing() throws {
        let (model, _) = model()
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .turnStarted(TurnStarted(chat: 1, turn: 1)),
            start("tu-1", seq: 1),
            .cardAsk(ask("card-1", tool: "tu-1", seq: 2)),
            .cardAnswered(CardAnswered(chat: 1, id: "card-1", toolUseId: "tu-1", outcome: .declined, note: "not now", seq: 3)),
            .toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-1", ok: false, summary: "denied", permission: .declined, note: "not now", seq: 4)),
            start("tu-2", seq: 5),
            .toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "tu-2", ok: true, summary: "ok", permission: .auto, seq: 6)),
        ], truncated: false)))
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertEqual(cards(model), 0)
        XCTAssertEqual(row(model, "tu-1")?.permission, .declined)
        XCTAssertEqual(row(model, "tu-1")?.note, "not now")
        XCTAssertEqual(row(model, "tu-2")?.permission, .auto)
    }

    func testAnOutcomeAheadOfItsRowWaitsForTheRow() {
        let (model, _) = model()
        model.apply(.cardAsk(ask("card-1", tool: "tu-9", seq: 1)))
        XCTAssertEqual(model.pinnedCards(for: 1).count, 1, "the card pins even before its row")
        model.apply(.cardAnswered(CardAnswered(chat: 1, id: "card-1", toolUseId: "tu-9", outcome: .session, seq: 2)))
        model.apply(start("tu-9", seq: 3))
        XCTAssertEqual(row(model, "tu-9")?.permission, .session)
    }

    func testACancelledCardSaysNotAnswered() throws {
        let (model, _) = model()
        model.apply(start("tu-1", seq: 1))
        model.apply(.cardAsk(ask("card-1", tool: "tu-1", seq: 2)))
        model.apply(.cardCancel(CardCancel(chat: 1, id: "card-1", reason: "nobody was there to answer", seq: 3)))
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        let shown = try XCTUnwrap(row(model, "tu-1"))
        XCTAssertEqual(shown.unanswered, "nobody was there to answer")
        XCTAssertEqual(ToolRowPresentation(row: shown).outcomeText(waiting: false), "not answered")
    }

    func testAWriteWhoseCardWasNeverAnsweredDidNotWrite() {
        var write = ToolRow(toolUseId: "tu-1", turn: 1, tool: "Write", summary: "", input: ["file_path": .string("/tmp/a.md")])
        write.finished = true
        write.ok = true
        XCTAssertTrue(AppModel.didWrite(write))
        write.unanswered = "cancelled"
        XCTAssertFalse(AppModel.didWrite(write), "nobody allowed it, so it didn't run")
    }
}
