import Foundation
import XCTest

@testable import Portico

/// v0.28 (PORT-82; Bill's ZJ7): the share the agent starts in a
/// conversation is one card, changed in place. Nothing is sent before
/// Share; Cancel removes the card; a shared card reads the same for good.
@MainActor
final class TeamShareCardTests: XCTestCase {
    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.teamDefaults = UserDefaults(suiteName: "team-card-tests-\(UUID().uuidString)")!
        model.setConnection(.connected)
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.28.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [],
            roots: [Root(name: "work", path: "/Users/someone/work")], commands: [], capabilities: [])
        hello.team = TeamHello(label: "Team knowledge", folder: "_team", intervals: [15, 30, 60])
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-19T12:00:00Z"),
        ])))
        model.selected = 1
        return (model, sent)
    }

    private static let paths = ["research/round-2/Research plan.md", "research/round-2/interview-guide.md"]
    private static let note = "Round 2 plan and guide. The final index is waiting on your corpus list."

    private func card(_ state: TeamShareCard.State = .draft, toolUse: String? = "toolu_share", at: String? = nil) -> TeamShareCard {
        TeamShareCard(chat: 1, share: "s-1", toolUseId: toolUse, paths: Self.paths, note: Self.note, state: state, at: at)
    }

    private func draft(rev: String, checking: Bool = false, findings: [TeamShareDraft.Finding] = []) -> TeamShareDraft {
        TeamShareDraft(rev: rev, paths: Self.paths, note: Self.note, checking: checking, findings: findings, chat: 1, id: "s-1")
    }

    private func sends(_ sent: Sent) -> [TeamShareSend] {
        sent.frames.compactMap { if case .teamShareSend(let send) = $0 { send } else { nil } }
    }

    func testTheCardFrameDecodesFromItsWireShape() throws {
        let json = """
            {"type":"team.share.card","ts":"2026-11-19T14:14:00Z","chat":14,"share":"s-41c07be2","tool_use_id":"toolu_01Share",
             "paths":["research/round-2/Research plan.md"],"note":"The plan.","state":"shared","at":"2026-11-19T14:14:00Z"}
            """
        guard case .teamShareCard(let card) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("expected team.share.card")
        }
        XCTAssertEqual(card.chat, 14)
        XCTAssertEqual(card.share, "s-41c07be2")
        XCTAssertEqual(card.toolUseId, "toolu_01Share")
        XCTAssertEqual(card.state, .shared)
        XCTAssertEqual(card.at, "2026-11-19T14:14:00Z")
    }

    func testADraftCardTakesTheAgentsRowAndWaitsForTheCheck() throws {
        let (model, sent) = model()
        model.apply(.teamShareCard(card()))
        XCTAssertEqual(model.shareCard(forToolUse: "toolu_share")?.share, "s-1")
        XCTAssertNil(model.shareCard(forToolUse: "toolu_other"))
        let session = try XCTUnwrap(model.teamCardSessions["s-1"])
        XCTAssertEqual(session.note, Self.note, "the note the agent wrote")
        XCTAssertTrue(session.checking)
        XCTAssertNil(model.teamShare, "the dialog does not open for a conversation's share")

        model.apply(.teamShareDraft(draft(rev: "1", checking: true)))
        XCTAssertNil(model.teamShare)
        model.teamCardSend("s-1")
        XCTAssertEqual(sends(sent).map(\.rev), ["1"], "Share may be pressed during the check; the gateway finishes it first")
    }

    func testEachFindingNeedsAChoiceAndOnlyShareSendsAnything() throws {
        let (model, sent) = model()
        model.apply(.teamShareCard(card()))
        let finding = TeamShareDraft.Finding(id: "f-1", path: Self.paths[0], text: "It names a colleague.", location: "Paragraph 3")
        model.apply(.teamShareDraft(draft(rev: "2", findings: [finding])))
        XCTAssertEqual(model.teamCardSessions["s-1"]?.findingsTitle, "One thing to check before it goes")
        XCTAssertEqual(model.teamCardSessions["s-1"]?.canShare, false)
        model.teamCardSend("s-1")
        XCTAssertEqual(sends(sent), [], "nothing goes until the person chose")

        model.teamCardChoose("s-1", "f-1", .takeOut)
        model.teamCardSetNote("s-1", "  The plan, edited. ")
        model.teamCardSend("s-1")
        let send = try XCTUnwrap(sends(sent).last)
        XCTAssertEqual(send.id, "s-1")
        XCTAssertEqual(send.rev, "2")
        XCTAssertEqual(send.note, "The plan, edited.")
        XCTAssertEqual(send.remove, ["f-1"])
        XCTAssertEqual(model.teamCardSessions["s-1"]?.sending, true)
        model.teamCardCancel("s-1")
        XCTAssertFalse(sent.frames.contains { if case .teamShareCancel = $0 { true } else { false } }, "a share under way is not called back")
    }

    func testAfterShareTheSameCardReadsSharedAndStaysSo() {
        let (model, _) = model()
        model.apply(.teamShareCard(card()))
        model.apply(.teamShareDraft(draft(rev: "1")))
        model.teamCardSend("s-1")
        model.apply(.teamResult(TeamResult(ok: true, id: "s-1")))
        model.apply(.teamShareCard(card(.shared, at: "2026-11-19T20:14:00Z")))
        XCTAssertNil(model.teamCardSessions["s-1"], "its draft is done with")
        XCTAssertEqual(model.teamShareCards.count, 1, "one card, changed in place, never a second one")
        XCTAssertEqual(model.shareCard(forToolUse: "toolu_share")?.state, .shared)

        // Again on the next chat.open, after a restart, after a file stopped syncing: the same.
        model.apply(.teamShareCard(card(.shared, at: "2026-11-19T20:14:00Z")))
        XCTAssertEqual(model.teamShareCards.count, 1)
        XCTAssertEqual(model.teamCardFiles(card(.shared)), [], "no shared rows: Stop syncing is not offered, the card still reads Shared")
    }

    func testTheSharedLineSaysWhen() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(SessionTime.parse("2026-11-19T22:00:00Z"))
        XCTAssertEqual(
            TeamShareCardPresentation.sharedLine(at: "2026-11-19T20:14:00Z", now: now, calendar: calendar, locale: locale),
            "Shared today at 2:14 PM. They stay in step from here.")
        XCTAssertEqual(
            TeamShareCardPresentation.sharedLine(at: "2026-11-18T20:14:00Z", now: now, calendar: calendar, locale: locale),
            "Shared Nov 18 at 2:14 PM. They stay in step from here.")
        XCTAssertEqual(TeamShareCardPresentation.sharedLine(at: nil), "Shared. They stay in step from here.")
        XCTAssertEqual(TeamShareCardPresentation.quoted("  Round 2. "), "\u{201C}Round 2.\u{201D}")
        XCTAssertNil(TeamShareCardPresentation.quoted("  "))
        XCTAssertEqual(TeamShareCardPresentation.startsLine, "From now on, changes to these files go to the team by themselves.")
    }

    func testARefusedShareSaysWhyOnTheCardAndCanBePressedAgain() {
        let (model, sent) = model()
        model.apply(.teamShareCard(card()))
        model.apply(.teamShareDraft(draft(rev: "1")))
        model.teamCardSend("s-1")
        model.apply(.teamResult(TeamResult(ok: false, reason: "The team source did not answer.", id: "s-1")))
        XCTAssertEqual(model.teamCardSessions["s-1"]?.refusal, "The team source did not answer.")
        XCTAssertEqual(model.teamCardSessions["s-1"]?.sending, false)
        XCTAssertEqual(model.shareCard(forToolUse: "toolu_share")?.state, .draft)
        model.teamCardSend("s-1")
        XCTAssertEqual(sends(sent).count, 2)
    }

    func testCancelAsksTheGatewayAndTheCancelledCardAndItsRowAreNotDrawn() {
        let (model, sent) = model()
        model.apply(.teamShareCard(card()))
        model.teamCardCancel("s-1")
        guard case .teamShareCancel(let cancel)? = sent.frames.last else { return XCTFail("expected team.share.cancel") }
        XCTAssertEqual(cancel.id, "s-1")
        XCTAssertEqual(model.shareCard(forToolUse: "toolu_share")?.state, .draft, "until the gateway says so")

        model.apply(.teamShareCard(card(.cancelled)))
        XCTAssertNil(model.teamCardSessions["s-1"])
        XCTAssertTrue(model.isCancelledShare(toolUse: "toolu_share"))
        let row = ToolRow(toolUseId: "toolu_share", turn: 1, tool: "mcp__portico__share_with_team", summary: "", input: [:])
        XCTAssertFalse(model.isDrawn(.tool(row), in: 1), "Cancel removes the card: its row draws nothing")
    }

    func testACardWithNoRowIsStillShownAfterTheTranscript() {
        let (model, _) = model()
        model.apply(.teamShareCard(card(toolUse: nil)))
        XCTAssertEqual(model.unanchoredShareCards(in: 1).map(\.share), ["s-1"])
        XCTAssertEqual(model.unanchoredShareCards(in: 2), [])
        model.apply(.teamShareCard(card(.cancelled, toolUse: nil)))
        XCTAssertEqual(model.unanchoredShareCards(in: 1), [])
    }
}
