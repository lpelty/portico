import Foundation
import XCTest

@testable import Portico

/// Share with team (v0.27, Bill's ZJ2): the dialog opens at once, the
/// check's findings each need a choice, and only Share sends anything.
@MainActor
final class TeamShareTests: XCTestCase {
    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.teamDefaults = UserDefaults(suiteName: "team-share-tests-\(UUID().uuidString)")!
        model.setConnection(.connected)
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.27.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [],
            roots: [Root(name: "work", path: "/Users/someone/work")], commands: [], capabilities: [])
        hello.team = TeamHello(label: "Team knowledge", folder: "_team", intervals: [15, 30, 60])
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-17T12:00:00Z"),
        ])))
        model.selected = 1
        return (model, sent)
    }

    private func finding(_ id: String = "f-1") -> TeamShareDraft.Finding {
        .init(id: id, path: "research/Research plan.md", text: "It names a colleague.", location: "Paragraph 3")
    }

    private func draft(
        _ id: String, rev: String, checking: Bool = false, findings: [TeamShareDraft.Finding] = [], error: String? = nil
    ) -> TeamShareDraft {
        TeamShareDraft(
            rev: rev, paths: ["research/Research plan.md"], checking: checking, checkError: error, findings: findings, id: id)
    }

    func testAFileInTheFirstRootIsNamedRelativeToItAndAnotherAbsolutely() {
        let (model, _) = model()
        XCTAssertEqual(model.teamPath(forAbsolute: "/Users/someone/work/research/Research plan.md"), "research/Research plan.md")
        XCTAssertEqual(model.teamPath(forAbsolute: "/Users/someone/elsewhere/a.md"), "/Users/someone/elsewhere/a.md")
        XCTAssertEqual(model.teamAbsolutePath("research/Research plan.md"), "/Users/someone/work/research/Research plan.md")
    }

    func testShareOpensTheDialogAtOnceAndAsksForTheCheck() throws {
        let (model, sent) = model()
        XCTAssertTrue(model.canShareWithTeam(absolutePath: "/Users/someone/work/research/Research plan.md"))
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let session = try XCTUnwrap(model.teamShare, "open before the gateway answers")
        guard case .teamSharePrepare(let prepare)? = sent.frames.last else { return XCTFail("expected team.share.prepare") }
        XCTAssertEqual(prepare.paths, ["research/Research plan.md"])
        XCTAssertEqual(prepare.id, session.id)
        XCTAssertTrue(session.checking)
        XCTAssertEqual(TeamShareSession.folder(session.paths[0]), "research")
    }

    func testEachFindingNeedsAChoiceAndTakeItOutIsSentOnlyAtShare() throws {
        let (model, sent) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.teamShare?.note = "  Round 2 plan.  "
        model.apply(.teamShareDraft(draft(id, rev: "2", findings: [finding("f-1"), finding("f-2")])))
        var session = try XCTUnwrap(model.teamShare)
        XCTAssertEqual(session.findingsTitle, "2 things to check before it goes")
        XCTAssertEqual(TeamShareSession.text(finding()), "Research plan.md, paragraph 3: It names a colleague.")
        XCTAssertFalse(session.canShare, "undecided findings hold Share")

        model.teamShareChoose("f-1", .takeOut)
        model.teamShareChoose("f-2", .keep)
        session = try XCTUnwrap(model.teamShare)
        XCTAssertEqual(TeamShareSession.chosen(finding(), .takeOut), "Paragraph 3 will be taken out of Research plan.md when you share")
        XCTAssertTrue(session.canShare)
        let before = sent.frames.count
        XCTAssertEqual(before, 1, "choosing sends nothing: the file changes only at Share")

        model.teamShareSend()
        guard case .teamShareSend(let send)? = sent.frames.last else { return XCTFail("expected team.share.send") }
        XCTAssertEqual([send.id, send.rev, send.note], [id, "2", "Round 2 plan."])
        XCTAssertEqual(send.remove, ["f-1"])
        XCTAssertNil(send.unchecked)
        XCTAssertEqual(model.teamShare?.shareLabel, "Sharing…")
        model.apply(.teamResult(TeamResult(ok: true, id: id)))
        XCTAssertNil(model.teamShare, "done: the dialog closes")
    }

    func testANewDraftKeepsTheNoteAndTheChoicesStillThere() throws {
        let (model, _) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.apply(.teamShareDraft(draft(id, rev: "2", findings: [finding("f-1"), finding("f-2")])))
        model.teamShare?.note = "Kept"
        model.teamShareChoose("f-1", .takeOut)
        model.teamShareChoose("f-2", .keep)
        model.teamShareSend()
        model.apply(.teamShareDraft(draft(id, rev: "3", findings: [finding("f-1"), finding("f-3")])))
        model.apply(.teamResult(TeamResult(ok: false, reason: "The check found something new. Look again before sharing.", id: id)))
        let session = try XCTUnwrap(model.teamShare, "refused: the dialog stays")
        XCTAssertEqual(session.note, "Kept")
        XCTAssertEqual(session.choices, ["f-1": .takeOut])
        XCTAssertEqual(session.refusal, "The check found something new. Look again before sharing.")
        XCTAssertFalse(session.sending)
        XCTAssertFalse(session.canShare, "the new finding needs its choice")
        XCTAssertEqual((model.transcripts[1] ?? []).count, 0, "the refusal is said in the dialog, not the conversation")
    }

    func testSharePressedDuringTheCheckWaitsVisiblyAndAFailedCheckOffersShareAnyway() throws {
        let (model, sent) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.apply(.teamShareDraft(draft(id, rev: "1", checking: true)))
        model.teamShareSend()
        XCTAssertEqual(model.teamShare?.shareLabel, "Checking…")
        model.apply(.teamShareDraft(draft(id, rev: "2", error: "The check for personal material could not finish.")))
        model.apply(.teamResult(TeamResult(ok: false, reason: "The check for personal material could not finish.", id: id)))
        XCTAssertEqual(model.teamShare?.shareLabel, "Share anyway")
        model.teamShareSend()
        guard case .teamShareSend(let send)? = sent.frames.last else { return XCTFail("expected team.share.send") }
        XCTAssertEqual(send.unchecked, true)
        XCTAssertEqual(send.rev, "2")
    }

    func testOnceShareIsPressedCancelDoesNothingUntilTheResult() throws {
        // A share under way cannot be called back, so the dialog never claims it was.
        let (model, sent) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.apply(.teamShareDraft(draft(id, rev: "2")))
        model.teamShareSend()
        let before = sent.frames.count
        model.teamShareCancel()
        XCTAssertNotNil(model.teamShare, "the dialog stays")
        XCTAssertEqual(sent.frames.count, before, "no cancel is sent")
        model.apply(.teamResult(TeamResult(ok: true, id: id)))
        XCTAssertNil(model.teamShare)
    }

    func testAShareWhoseResultWasLostIsAskedAgainByTheSameId() throws {
        let (model, sent) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.apply(.teamShareDraft(draft(id, rev: "2")))
        model.teamShareSend()
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.27.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [],
            roots: [Root(name: "work", path: "/Users/someone/work")], commands: [], capabilities: [])
        hello.team = TeamHello(label: "Team knowledge", folder: "_team", intervals: [15, 30, 60])
        model.apply(.hello(hello))  // the connection came back
        guard case .teamShareSend(let again)? = sent.frames.last else { return XCTFail("expected the same share again") }
        XCTAssertEqual([again.id, again.rev], [id, "2"])
        model.apply(.error(ErrorMessage(code: "gateway.error", message: "team.share.send failed: disk full", id: id)))
        XCTAssertEqual(model.teamShare?.sending, false, "an error frees the dialog")
        XCTAssertEqual(model.teamShare?.refusal, "team.share.send failed: disk full")
    }

    func testCancelSendsCancelAndAnotherSharesDraftIsNotTaken() throws {
        let (model, sent) = model()
        model.teamShareStart(absolutePaths: ["/Users/someone/work/research/Research plan.md"])
        let id = try XCTUnwrap(model.teamShare?.id)
        model.apply(.teamShareDraft(draft("someone-else", rev: "9", findings: [finding()])))
        XCTAssertNil(model.teamShare?.draft)
        model.teamShareCancel()
        XCTAssertNil(model.teamShare)
        guard case .teamShareCancel(let cancel)? = sent.frames.last else { return XCTFail("expected team.share.cancel") }
        XCTAssertEqual(cancel.id, id)
    }

    func testAFileAlreadySharedIsNotOfferedShareAgain() {
        let (model, _) = model()
        let who = TeamPerson(name: "Larry Pelty", short: "Larry")
        model.apply(.teamState(TeamState(
            reach: .ok, nextCheckAt: "2026-11-17T20:30:00Z", intervalMinutes: 15,
            files: [TeamFile(path: "research/Research plan.md", direction: .out, rev: "r-1", sharedBy: who, sharedAt: "2026-11-17T20:00:00Z")])))
        XCTAssertFalse(model.canShareWithTeam(absolutePath: "/Users/someone/work/research/Research plan.md"))
        XCTAssertTrue(model.canShareWithTeam(absolutePath: "/Users/someone/work/other.md"))
    }
}
