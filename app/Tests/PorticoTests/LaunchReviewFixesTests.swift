import Foundation
import XCTest

@testable import Portico

/// v0.6 review fixes in the model: the launch's load of the live session
/// is not opened twice (the beginning of the conversation and a send in
/// flight survive), the welcome waits while the session is being logged
/// or ended, "Not connected" holds through retries until the first list,
/// a folder relist never skips a directory, and stored artifacts alone
/// leave the viewer closed. Model-only.
@MainActor
final class LaunchReviewFixesTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
        var opens: [ChatOpen] {
            frames.compactMap { if case .chatOpen(let open) = $0 { return open } else { return nil } }
        }
        var listings: [FilesListRequest] {
            frames.compactMap { if case .filesList(let request) = $0 { return request } else { return nil } }
        }
    }

    private func model() throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v06-review-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.relistDelay = .zero
        return (model, sent)
    }

    private func hello(roots: [Root] = []) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.6.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: roots,
            commands: ["log"], capabilities: ["files", "sessions", "context"], presentation: "single", canLog: true)
    }

    private func session(_ chat: Int, state: ChatStateWord = .idle, ended: String? = nil) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-29T09:14:00Z", ended: ended)
    }

    private func launched(_ model: AppModel, _ chats: [ChatSummary], roots: [Root] = []) {
        model.setConnection(.connected)
        model.apply(.hello(hello(roots: roots)))
        model.apply(.chatList(ChatList(chats: chats)))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    // MARK: - one open for the launch's load

    func testViewBeforeTheHistoryArrivesKeepsTheBeginning() throws {
        let (model, sent) = try model()
        launched(model, [session(3, state: .working)])
        XCTAssertEqual(sent.opens.count, 1, "the launch loads the live session")
        // A live frame of the running turn comes before chat.open's history…
        model.apply(.textDelta(TextDelta(chat: 3, turn: 2, text: "tail", seq: 11, ts: "2026-10-29T10:00:00Z")))
        // …and the person clicks View Session 3 before the history arrives.
        model.open(chat: 3)
        XCTAssertEqual(model.selected, 3)
        XCTAssertEqual(sent.opens.count, 1, "a load still out is only shown, not opened again")
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [
            .userText(UserText(chat: 3, turn: 1, text: "first question", seq: 1, ts: "2026-10-29T09:15:00Z")),
            .textDelta(TextDelta(chat: 3, turn: 1, text: "first answer", seq: 2, ts: "2026-10-29T09:15:01Z")),
            .textDelta(TextDelta(chat: 3, turn: 2, text: "tail", seq: 11, ts: "2026-10-29T10:00:00Z")),
        ], truncated: false)))
        let items = model.transcripts[3] ?? []
        XCTAssertTrue(items.contains { if case .userText(let u) = $0 { return u.text == "first question" } else { return false } },
            "the conversation keeps its beginning")
    }

    func testOpeningAChatThatIsLiveStillCatchesUp() throws {
        let (model, sent) = try model()
        launched(model, [session(3)])
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [], truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3, seq: 4)))
        model.open(chat: 3)
        XCTAssertEqual(sent.opens.count, 2)
        XCTAssertEqual(sent.opens.last?.since, 4, "a chat already live is opened again since its watermark")
    }

    func testASendBeforeTheHistoryStaysInFlight() throws {
        let (model, sent) = try model()
        launched(model, [session(3)])
        model.continueSession(chat: 3, text: "go")
        XCTAssertTrue(model.isSending(chat: 3))
        XCTAssertEqual(sent.opens.count, 1)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [
            .userText(UserText(chat: 3, turn: 1, text: "old", seq: 1, ts: "2026-10-29T09:15:00Z"))], truncated: false)))
        XCTAssertTrue(model.isSending(chat: 3), "the launch's history does not forget the send in flight")
    }

    func testARefusedWelcomeSendBeforeTheHistoryComesBack() throws {
        let (model, sent) = try model()
        launched(model, [session(3)])
        model.attachToStart(["/tmp/demo/a.md"])
        model.continueSession(chat: 3, text: "go")
        guard case .messageSend(let send)? = sent.frames.last else { return XCTFail("expected message.send") }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [], truncated: false)))
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "busy", chat: 3, id: send.id)))
        XCTAssertEqual(model.draft(for: 3), "go", "the words go back in the composer")
        XCTAssertEqual(model.draftAttachments[3], ["/tmp/demo/a.md"], "and so do the files")
    }

    func testASendFromBeforeAReconnectIsSettledByTheReplay() throws {
        let (model, _) = try model()
        launched(model, [session(3)])
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [], truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3, seq: 1)))
        model.sendMessage(chat: 3, text: "go")
        // Same gateway, a new socket: the replay is the whole truth again.
        model.apply(.hello(hello()))
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [
            .userText(UserText(chat: 3, turn: 1, text: "go", seq: 2, ts: "2026-10-29T09:15:00Z"))], truncated: false)))
        XCTAssertFalse(model.isSending(chat: 3))
    }

    // MARK: - the welcome while the session is being logged or ended

    func testTheWelcomeSendsNothingWhileTheSessionIsBeingLogged() throws {
        let (model, sent) = try model()
        launched(model, [session(3)])
        model.logSession(chat: 3)
        XCTAssertTrue(model.isSessionCommandPending(chat: 3))
        sent.frames = []
        model.startDraft = "go"
        model.continueSession(chat: 3, text: "go")
        model.continueSession(chat: 3, action: "Summarize")
        XCTAssertFalse(sent.types().contains("message.send"))
        XCTAssertNil(model.selected, "the welcome stays")
        XCTAssertEqual(model.startDraft, "go", "and keeps what was typed")
    }

    // MARK: - "Not connected" until the first list

    func testAFailureBeforeTheFirstListHoldsThroughRetries() throws {
        let (model, _) = try model()
        XCTAssertEqual(model.mainScreen, .waiting)
        model.setConnection(.failed("x"))
        XCTAssertEqual(model.mainScreen, .start)
        model.setConnection(.connecting)
        XCTAssertEqual(model.mainScreen, .start, "a retry does not blank the welcome")
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(3)])))
        XCTAssertEqual(model.mainScreen, .continuing(3))
    }

    // MARK: - relisting the folder

    func testARelistAsksAgainForADirectoryWhoseListingIsStillOut() async throws {
        let (model, sent) = try model()
        launched(model, [session(3)])
        model.listFiles(chat: 3, root: AppModel.chatRoot, path: "")
        guard let first = sent.listings.last else { return XCTFail("expected files.list") }
        model.apply(.filesList(FilesList(root: first.root, path: "", entries: [], chat: 3, id: first.id)))
        model.relistSessionFolder(chat: 3)  // out, unanswered
        sent.frames = []
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .done, seq: 5)))
        await settle()
        XCTAssertEqual(sent.listings.map(\.path), [""], "listed again though a listing was out")
    }

    func testARootHoldingTheSessionsFolderListsThePartInsideIt() async throws {
        let (model, sent) = try model()
        launched(model, [session(3)], roots: [Root(name: "work", path: "/tmp")])
        for path in ["", "demo", "demo/notes", "other"] {
            model.listFiles(chat: 3, root: "work", path: path)
        }
        for request in sent.listings {
            model.apply(.filesList(FilesList(root: request.root, path: request.path, entries: [], chat: 3, id: request.id)))
        }
        sent.frames = []
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .done, seq: 5)))
        await settle()
        XCTAssertEqual(sent.listings.map(\.path), ["demo", "demo/notes"], "the folder and below, nothing else")
    }

    // MARK: - the viewer opens only on something

    func testStoredArtifactsAloneLeaveTheViewerClosed() throws {
        let (model, _) = try model()
        launched(model, [session(2, state: .stopped, ended: "2026-10-28T17:00:00Z"), session(3)])
        model.open(chat: 2)
        model.apply(.chatHistory(ChatHistory(chat: 2, events: [], truncated: false)))
        model.apply(.artifactCreated(ArtifactCreated(chat: 2, artifact: Artifact(
            id: "a", kind: .file, location: "/tmp/demo/a.md", media: .markdown, title: "a.md", source: .tool, open: false))))
        XCTAssertFalse(model.isViewerShown(for: 2), "an earlier session's artifacts do not open an empty viewer")
        model.apply(.artifactCreated(ArtifactCreated(chat: 3, artifact: Artifact(
            id: "b", kind: .file, location: "/tmp/demo/b.md", media: .markdown, title: "b.md", source: .tool, open: true))))
        XCTAssertTrue(model.isViewerShown(for: 3), "one that opens shows")
    }
}
