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

    /// What each directory of the two test roots holds.
    private static let tree: [String: [Entry]] = [
        "work:": [Entry(name: "demo", dir: true), Entry(name: "other", dir: true), Entry(name: "top.md", dir: false)],
        "work:demo": [Entry(name: "notes", dir: true), Entry(name: "plan.md", dir: false)],
        "work:demo/notes": [Entry(name: "deep.md", dir: false)],
        "work:other": [Entry(name: "found.md", dir: false)],
        "vault:": [Entry(name: "notes", dir: true)],
        "vault:notes": [Entry(name: "idea.md", dir: false)],
    ]

    /// Answers every listing asked for so far, from `tree` (a directory it lacks is refused).
    private func answer(_ model: AppModel, _ sent: Sent, tree: [String: [Entry]] = LaunchReviewFixesTests.tree) {
        for request in sent.listings {
            if let entries = tree["\(request.root):\(request.path)"] {
                model.apply(.filesList(FilesList(root: request.root, path: request.path, entries: entries, chat: 3, id: request.id)))
            } else {
                model.apply(.error(ErrorMessage(code: "files.not_found", message: "No such directory", chat: 3, id: request.id)))
            }
        }
        sent.frames = []
    }

    private func listTwoRoots(_ model: AppModel, _ sent: Sent) {
        for path in ["", "demo", "demo/notes", "other"] {
            model.listFiles(chat: 3, root: "work", path: path)
        }
        model.listFiles(chat: 3, root: "vault", path: "")
        model.listFiles(chat: 3, root: "vault", path: "notes")
        answer(model, sent)
    }

    private func twoRoots() throws -> (AppModel, Sent) {
        let (model, sent) = try model()
        launched(model, [session(3)], roots: [Root(name: "work", path: "/tmp"), Root(name: "vault", path: "/vault")])
        listTwoRoots(model, sent)
        return (model, sent)
    }

    private func turnEnds(_ model: AppModel, seq: Int) async {
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: seq, outcome: .done, seq: seq)))
        await settle()
    }

    /// v0.26.5: a relist asks for each root's top level and the folders
    /// open now, in every root (the agent makes folders outside the
    /// session's own folder too). v0.26.6: a listed folder that is closed
    /// is not asked for and keeps its listing; opened, it is asked for.
    func testARelistAsksForTheRootsAndTheOpenFoldersInEveryRoot() async throws {
        let (model, sent) = try twoRoots()
        model.toggleFolder(chat: 3, root: "work", path: "demo")
        model.toggleFolder(chat: 3, root: "vault", path: "notes")
        XCTAssertTrue(model.isFolderOpen(chat: 3, root: "work", path: "demo"), "the folders are open")
        answer(model, sent)  // opening each asked for it again
        await turnEnds(model, seq: 5)
        XCTAssertEqual(
            sent.listings.map { "\($0.root):\($0.path)" },
            ["vault:", "vault:notes", "work:", "work:demo"],
            "the roots and the open folders, and no closed folder")
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "other")?.map(\.name), ["found.md"], "a closed folder keeps its listing")
        XCTAssertNotNil(model.fileEntries(chat: 3, root: "work", path: "demo/notes"))
        XCTAssertNotNil(model.fileEntries(chat: 3, root: "work", path: "demo"), "an open folder keeps its rows until the answer")
        answer(model, sent)

        // Opened in Files after the relist (the click, as the interface makes it), the closed
        // folder is asked for though it has a listing, and its old rows stay meanwhile.
        model.toggleFolder(chat: 3, root: "work", path: "other")
        XCTAssertEqual(sent.listings.map { "\($0.root):\($0.path)" }, ["work:other"], "asked for again when opened")
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "other")?.map(\.name), ["found.md"])
        var grown = Self.tree
        grown["work:other"] = [Entry(name: "found.md", dir: false), Entry(name: "new.md", dir: false)]
        answer(model, sent, tree: grown)
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "other")?.map(\.name), ["found.md", "new.md"], "the file the agent added shows")
        // Closing asks for nothing.
        model.toggleFolder(chat: 3, root: "work", path: "other")
        XCTAssertEqual(sent.listings.count, 0)
    }

    /// v0.26.6 (review round 2, F1): a folder is open by where it is on disk, in every chat.
    /// Opened from one chat, it is asked for again in each chat that has it listed, so the
    /// other chat does not keep showing its old contents.
    func testOpeningAFolderAsksAgainInEveryChatThatListsIt() async throws {
        let (model, sent) = try model()
        launched(model, [session(3), session(4)], roots: [Root(name: "work", path: "/tmp"), Root(name: "vault", path: "/vault")])
        for chat in [3, 4] {
            model.listFiles(chat: chat, root: "work", path: "")
            model.listFiles(chat: chat, root: "work", path: "other")
        }
        for request in sent.listings {
            model.apply(.filesList(FilesList(
                root: request.root, path: request.path, entries: Self.tree["\(request.root):\(request.path)"] ?? [],
                chat: request.chat, id: request.id)))
        }
        sent.frames = []
        model.toggleFolder(chat: 4, root: "work", path: "other")
        XCTAssertEqual(
            sent.listings.map { "\($0.chat ?? 0):\($0.path)" }.sorted(), ["3:other", "4:other"], "both chats' listings of the folder")
    }

    /// v0.26.6 (PORT-67): the filter searches the listings, so a closed folder's files are
    /// still found after the agent's next command.
    func testAfterARelistAClosedFoldersFilesAreStillListed() async throws {
        let (model, sent) = try twoRoots()
        await turnEnds(model, seq: 5)
        answer(model, sent)
        await turnEnds(model, seq: 6)
        XCTAssertEqual(sent.listings.map { "\($0.root):\($0.path)" }, ["vault:", "work:"], "the roots only, each time")
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "other")?.map(\.name), ["found.md"])
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "demo/notes")?.map(\.name), ["deep.md"])
    }

    /// v0.26.6 (PORT-67): an open folder that is gone is forgotten when its parent's
    /// fresh listing lacks it, whichever answer lands first, and is not asked for again.
    func testAFolderThatIsGoneIsForgottenAndNotAskedForAgain() async throws {
        for refusalFirst in [true, false] {
            let (model, sent) = try twoRoots()
            model.toggleFolder(chat: 3, root: "work", path: "demo")
            answer(model, sent)
            await turnEnds(model, seq: 5)
            var gone = Self.tree
            gone["work:demo"] = nil
            gone["work:demo/notes"] = nil
            gone["work:"] = [Entry(name: "other", dir: true), Entry(name: "top.md", dir: false)]
            let requests = sent.listings.sorted { a, _ in (a.path == "demo") == refusalFirst }
            sent.frames = []
            for request in requests {
                if let entries = gone["\(request.root):\(request.path)"] {
                    model.apply(.filesList(FilesList(root: request.root, path: request.path, entries: entries, chat: 3, id: request.id)))
                } else {
                    model.apply(.error(ErrorMessage(code: "files.not_found", message: "No such directory", chat: 3, id: request.id)))
                }
            }
            XCTAssertNil(model.fileEntries(chat: 3, root: "work", path: "demo"), "refusal first: \(refusalFirst)")
            XCTAssertNil(model.fileEntries(chat: 3, root: "work", path: "demo/notes"), "and what was under it")
            XCTAssertNil(model.fileListError(chat: 3, root: "work", path: "demo"), "no row is left to carry a refusal")
            await turnEnds(model, seq: 9)
            XCTAssertEqual(sent.listings.map { "\($0.root):\($0.path)" }, ["vault:", "work:"], "the folder that is gone is left alone")
        }
    }

    /// v0.26.6 (PORT-67): an open folder deleted and made again shows its new contents
    /// after the next relist with no click, though the listing in between was refused.
    func testAnOpenFolderMadeAgainIsListedByTheNextRelist() async throws {
        let (model, sent) = try twoRoots()
        model.toggleFolder(chat: 3, root: "work", path: "demo")
        answer(model, sent)
        await turnEnds(model, seq: 5)
        // The folder's listing is refused while its parent's (read a moment earlier or later) still holds it.
        var between = Self.tree
        between["work:demo"] = nil
        answer(model, sent, tree: between)
        XCTAssertEqual(model.fileListError(chat: 3, root: "work", path: "demo"), "No such directory")
        XCTAssertEqual(model.latestStatusLine(for: 3), "No such directory", "the first refusal is said, as before")
        // Refused again at the next relist (review 20261115-173452-0e093e, F13): the row already
        // says it, and the chat's status line is left to whatever it holds by then.
        model.apply(.statusSet(StatusSet(text: "Reading the plan", chat: 3)))
        await turnEnds(model, seq: 7)
        answer(model, sent, tree: between)
        XCTAssertEqual(model.fileListError(chat: 3, root: "work", path: "demo"), "No such directory")
        XCTAssertEqual(model.latestStatusLine(for: 3), "Reading the plan", "the same refusal again does not take the status line")
        await turnEnds(model, seq: 9)
        XCTAssertEqual(
            sent.listings.map { "\($0.root):\($0.path)" }, ["vault:", "work:", "work:demo"], "the refused open folder is asked for again")
        var remade = Self.tree
        remade["work:demo"] = [Entry(name: "built.js", dir: false)]
        answer(model, sent, tree: remade)
        XCTAssertEqual(model.fileEntries(chat: 3, root: "work", path: "demo")?.map(\.name), ["built.js"])
        XCTAssertNil(model.fileListError(chat: 3, root: "work", path: "demo"))
    }

    /// v0.26.6 (PORT-67): with quick open on screen, a relist loses no listing, so the
    /// prefetch has nothing to ask for again.
    func testQuickOpensPrefetchAsksForNothingAfterARelist() async throws {
        let (model, sent) = try twoRoots()
        // Quick open also lists the session's own folder, empty here.
        var tree = Self.tree
        tree["\(AppModel.chatRoot):"] = []
        model.prefetchFiles(chat: 3)
        answer(model, sent, tree: tree)
        model.prefetchFiles(chat: 3)
        XCTAssertEqual(sent.listings.count, 0, "everything is listed")
        await turnEnds(model, seq: 5)
        XCTAssertEqual(sent.listings.count, 3, "the three roots, no folder under them")
        answer(model, sent, tree: tree)
        model.prefetchFiles(chat: 3)
        XCTAssertEqual(sent.listings.count, 0, "the closed folders kept their listings")
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
