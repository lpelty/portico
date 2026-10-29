import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// v0.6 in the model: launch continues the live session (Y1) with no
/// welcome-then-jump, the viewer comes back only with something in it,
/// the Files tree lists the session's folder again after a write, and an
/// earlier session has a way back (Y2). Model-only.
@MainActor
final class LaunchAndWayBackTests: XCTestCase {

    // MARK: - helpers

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private var defaults: UserDefaults!

    private func model() throws -> (AppModel, Sent) {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v06-\(UUID().uuidString)"))
        return make()
    }

    /// A model on the same defaults: the next launch.
    private func make() -> (AppModel, Sent) {
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.relistDelay = .zero
        return (model, sent)
    }

    private func hello(epoch: String = "e", canLog: Bool = true) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.6.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["log"], capabilities: ["files", "sessions", "context"], presentation: "single", canLog: canLog)
    }

    private func session(_ chat: Int, ended: String? = nil, unlogged: Bool? = nil, lastReply: String? = nil) -> ChatSummary {
        ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: ended == nil ? .idle : .stopped,
            created: "2026-10-29T09:14:00Z", ended: ended, unlogged: unlogged, lastReply: lastReply)
    }

    /// Launch with Session 2 ended and Session 3 live.
    private func launched(_ model: AppModel) {
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(2, ended: "2026-10-28T17:00:00Z"), session(3)])))
    }

    private func artifact(_ id: String, chat: Int = 3, open: Bool = false) -> ServerMessage {
        .artifactCreated(ArtifactCreated(chat: chat, artifact: Artifact(
            id: id, kind: .file, location: "/tmp/demo/\(id).md", media: .markdown, title: "\(id).md", source: .tool, open: open)))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ stamp: String) -> Date { SessionTime.parse(stamp)! }
    private let us = Locale(identifier: "en_US")

    // MARK: - 1. launch decides before drawing

    func testTheMainScreenIsAPureFunctionOfState() {
        XCTAssertEqual(MainScreen.decide(selected: 4, listed: false, gaveUp: false, single: true, live: 3), .conversation(4))
        XCTAssertEqual(MainScreen.decide(selected: nil, listed: false, gaveUp: false, single: true, live: nil), .waiting,
            "nothing listed yet: draw nothing rather than a welcome that may change")
        XCTAssertEqual(MainScreen.decide(selected: nil, listed: false, gaveUp: true, single: false, live: nil), .start,
            "a connection that gave up shows the welcome, which says so")
        XCTAssertEqual(MainScreen.decide(selected: nil, listed: true, gaveUp: false, single: true, live: 3), .continuing(3))
        XCTAssertEqual(MainScreen.decide(selected: nil, listed: true, gaveUp: false, single: true, live: nil), .start,
            "no live session: the welcome starts one, as before")
        XCTAssertEqual(MainScreen.decide(selected: nil, listed: true, gaveUp: false, single: false, live: 3), .start,
            "the chat list keeps its own start screen")
    }

    func testLaunchWithALiveSessionContinuesItWithoutShowingTheConversation() throws {
        let (model, sent) = try model()
        XCTAssertEqual(model.mainScreen, .waiting, "before the gateway says anything")
        model.setConnection(.connecting)
        XCTAssertEqual(model.mainScreen, .waiting)
        launched(model)
        XCTAssertNil(model.selected, "no jump into the conversation")
        XCTAssertEqual(model.mainScreen, .continuing(3))
        XCTAssertEqual(model.shownChat, 3, "the viewer, title and strip follow the continued session")
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open, got \(sent.types())") }
        XCTAssertEqual(open.chat, 3, "the live session is loaded so View and the first send find it ready")
        XCTAssertNil(open.since)

        // A second chat.list (an alias, say) asks for nothing more.
        let count = sent.frames.count
        model.apply(.chatList(ChatList(chats: [session(2, ended: "2026-10-28T17:00:00Z"), session(3)])))
        XCTAssertEqual(sent.frames.count, count)
        XCTAssertEqual(model.mainScreen, .continuing(3))
    }

    func testAConnectionThatGivesUpShowsTheWelcomeNotABlankColumn() throws {
        let (model, _) = try model()
        model.setConnection(.failed("no gateway"))
        XCTAssertEqual(model.mainScreen, .start)
    }

    func testSendingFromTheWelcomeContinuesTheSessionAndShowsIt() throws {
        let (model, sent) = try model()
        launched(model)
        model.attachToStart(["/tmp/notes.md"])
        model.startDraft = "  Draft the summary  "
        model.continueSession(chat: 3, text: model.startDraft)
        XCTAssertEqual(model.selected, 3)
        XCTAssertEqual(model.mainScreen, .conversation(3))
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send, got \(sent.types())") }
        XCTAssertEqual(message.chat, 3, "appended to the live session, not a new one")
        XCTAssertEqual(message.text, "Draft the summary")
        XCTAssertEqual(message.attachments, ["/tmp/notes.md"])
        XCTAssertFalse(sent.types().contains("chat.new"))
        XCTAssertEqual(model.startDraft, "")
        XCTAssertTrue(model.startAttachments.isEmpty)
    }

    func testAMessageTheSessionCannotTakeYetWaitsInItsComposer() throws {
        let (model, sent) = try model()
        launched(model)
        model.apply(.chatState(ChatState(chat: 3, state: .working, seq: 1)))
        model.continueSession(chat: 3, text: "next")
        XCTAssertEqual(model.selected, 3)
        XCTAssertFalse(sent.types().contains("message.send"), "a running turn would refuse it")
        XCTAssertEqual(model.draft(for: 3), "next", "nothing typed is lost")
    }

    func testASuggestionFromTheWelcomeGoesToTheLiveSession() throws {
        let (model, sent) = try model()
        launched(model)
        model.continueSession(chat: 3, action: "Summarize this folder")
        XCTAssertEqual(model.selected, 3)
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.chat, 3)
        XCTAssertEqual(message.text, "Summarize this folder")
    }

    func testStartANewSessionFromTheWelcomeAsksToLogFirstWhenThereIsUnloggedWork() throws {
        let (model, sent) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(3, unlogged: true)])))
        model.requestNew(chat: 3)
        XCTAssertEqual(model.askingToLog, 3, "the existing New path")
        XCTAssertFalse(sent.types().contains("session.renew"))
    }

    func testAReconnectMidUseNeverGoesBackToTheWelcome() throws {
        let (model, _) = try model()
        launched(model)
        model.open(chat: 3)
        XCTAssertEqual(model.mainScreen, .conversation(3))

        // The gateway restarts: a new epoch, the list again.
        model.setConnection(.disconnected)
        XCTAssertEqual(model.mainScreen, .conversation(3), "a dropped socket keeps the conversation")
        model.setConnection(.connected)
        model.apply(.hello(hello(epoch: "e2")))
        model.apply(.chatList(ChatList(chats: [session(2, ended: "2026-10-28T17:00:00Z"), session(3)])))
        XCTAssertEqual(model.mainScreen, .conversation(3))

        // Even when the list no longer has what was shown: the live session, not the welcome.
        model.open(chat: 2)
        model.apply(.hello(hello(epoch: "e3")))
        model.apply(.chatList(ChatList(chats: [session(3)])))
        XCTAssertEqual(model.mainScreen, .conversation(3))
    }

    func testALiveTurnFinishingIsTheLastReply() throws {
        let (model, _) = try model()
        launched(model)
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .done, seq: 5, ts: "2026-10-29T10:02:00Z")))
        XCTAssertEqual(model.summary(of: 3)?.lastReply, "2026-10-29T10:02:00Z")
    }

    func testAnErrorBeforeTheAgentSaidAnythingIsNotTheLastReply() throws {
        let (model, _) = try model()
        launched(model)
        // The engine could not start: the echo, then the error finish.
        model.apply(.userText(UserText(chat: 3, turn: 1, text: "hello", seq: 1, ts: "2026-10-29T10:00:00Z")))
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .error, seq: 2, ts: "2026-10-29T10:01:00Z")))
        XCTAssertNil(model.summary(of: 3)?.lastReply)

        // An error after the agent answered still is.
        model.apply(.userText(UserText(chat: 3, turn: 2, text: "again", seq: 3, ts: "2026-10-29T10:02:00Z")))
        model.apply(.textDelta(TextDelta(chat: 3, turn: 2, text: "Partly", seq: 4, ts: "2026-10-29T10:02:30Z")))
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 2, outcome: .error, seq: 5, ts: "2026-10-29T10:03:00Z")))
        XCTAssertEqual(model.summary(of: 3)?.lastReply, "2026-10-29T10:03:00Z")
    }

    func testTheContinuingLineSaysWhichSessionAndWhenItLastAnswered() {
        let shown = SessionPresentation(summary: session(3, lastReply: "2026-10-29T10:02:00Z"))
        XCTAssertEqual(
            shown.continuingLine(now: date("2026-10-29T10:14:00Z"), calendar: utc, locale: us),
            "Continuing Session 3 · started today, 9:14 AM · last reply 12 min ago")
        XCTAssertEqual(
            SessionPresentation(summary: session(3)).continuingLine(now: date("2026-10-29T10:14:00Z"), calendar: utc, locale: us),
            "Continuing Session 3 · started today, 9:14 AM", "no last reply until the gateway says")
        XCTAssertEqual(
            shown.continuingLine(now: date("2026-10-30T08:00:00Z"), calendar: utc, locale: us),
            "Continuing Session 3 · started yesterday, 9:14 AM · last reply yesterday, 10:02 AM",
            "an older reply on the full form too (v0.7 decision 1)")
        XCTAssertEqual(SessionTime.ago(date("2026-10-29T10:13:40Z"), now: date("2026-10-29T10:14:00Z")), "just now")
        XCTAssertEqual(SessionTime.ago(date("2026-10-29T07:00:00Z"), now: date("2026-10-29T10:14:00Z")), "3 h ago")
        XCTAssertEqual(SessionTime.ago(date("2026-10-27T07:00:00Z"), now: date("2026-10-29T10:14:00Z")), "2 d ago")
    }

    // MARK: - 2. the viewer on resume

    func testTheViewerRestoreRuleIsPure() {
        XCTAssertNil(ViewerRestore.artifact(saved: nil, chat: 3), "closed or empty at quit: closed")
        XCTAssertEqual(ViewerRestore.artifact(saved: SavedViewer(chat: 3, artifact: "a2"), chat: 3), "a2")
        XCTAssertNil(ViewerRestore.artifact(saved: SavedViewer(chat: 2, artifact: "a1"), chat: 3),
            "another session's artifact does not open this one's viewer")
    }

    func testResumeWithNothingShowingStartsWithTheViewerClosed() throws {
        let (model, _) = try model()
        launched(model)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        XCTAssertEqual(model.artifacts[3]?.count, 2)
        XCTAssertFalse(model.isViewerShown(for: 3), "artifacts alone do not open an empty viewer")
        XCTAssertNil(model.current[3])

        // Something new auto-opens as before.
        model.apply(artifact("a3", open: true))
        XCTAssertTrue(model.isViewerShown(for: 3))
        XCTAssertEqual(model.current[3]?.id, "a3")
    }

    func testQuittingWithAnArtifactShowingBringsItBack() throws {
        let (first, _) = try model()
        launched(first)
        first.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        first.open(chat: 3)
        first.show(try XCTUnwrap(first.artifacts[3]?.first { $0.id == "a2" }), in: 3)
        first.rememberViewerForNextLaunch()
        XCTAssertEqual(first.settings.viewerAtQuit, SavedViewer(chat: 3, artifact: "a2"))

        // v0.8 decision 1: the welcome stands alone; going into the
        // conversation brings the viewer back, on the artifact.
        let (next, _) = make()
        launched(next)
        next.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        XCTAssertEqual(next.mainScreen, .continuing(3))
        XCTAssertFalse(next.isViewerShown(for: 3), "never beside the welcome")
        XCTAssertNil(next.current[3])
        next.open(chat: 3)  // View Session 3
        XCTAssertEqual(next.current[3]?.id, "a2")
        XCTAssertTrue(next.isViewerShown(for: 3))
    }

    // MARK: - v0.8 decision 2: a generated title arrives in a later chat.list

    func testALaterTitleUpdatesTheEarlierRowTheCardAndTheDivider() throws {
        let (model, _) = try model()
        func listed(_ earlier: String, _ live: String) -> ServerMessage {
            .chatList(ChatList(chats: [
                ChatSummary(
                    chat: 2, folder: "/tmp/demo", alias: nil, state: .stopped, created: "2026-10-28T09:14:00Z",
                    title: earlier, ended: "2026-10-28T17:00:00Z"),
                ChatSummary(
                    chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-29T09:14:00Z",
                    title: live, parent: 2),
            ]))
        }
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(listed("can you look at the interview notes from", "next: the codebook"))
        model.apply(listed("Interview notes review", "Codebook draft"))

        XCTAssertEqual(model.earlierSessions.map { SessionPresentation(summary: $0).title }, ["Interview notes review"])
        XCTAssertEqual(model.earlierSessions(matching: "notes review").map(\.chat), [2], "the search reads the new title")
        let card = SessionPresentation(summary: try XCTUnwrap(model.summary(of: 3)))
        XCTAssertTrue(card.startedLine(calendar: utc, locale: us).hasSuffix(" · Codebook draft"))
        let parent = SessionPresentation(summary: try XCTUnwrap(model.summary(of: 2)))
        XCTAssertEqual(parent.parentLine(calendar: utc, locale: us), "Session 2 · Interview notes review · not logged")

        // A replayed first message does not put the first line back.
        model.apply(.userText(UserText(chat: 3, turn: 1, text: "next: the codebook", seq: 1, ts: "2026-10-29T09:15:00Z")))
        XCTAssertEqual(SessionPresentation(summary: try XCTUnwrap(model.summary(of: 3))).title, "Codebook draft")
    }

    // MARK: - v0.8 decision 1: the welcome on its own

    private func rememberedA2() throws {
        let (first, _) = try model()
        first.settings.viewerAtQuit = SavedViewer(chat: 3, artifact: "a2")
    }

    func testTheQuitRuleKeepsWhatWasRememberedWhileTheRestoreIsHeld() {
        let saved = SavedViewer(chat: 3, artifact: "a2")
        let showing = SavedViewer(chat: 3, artifact: "a5")
        XCTAssertEqual(ViewerRestore.toRemember(showing: nil, saved: saved, held: true), saved, "quit from the welcome")
        XCTAssertNil(ViewerRestore.toRemember(showing: nil, saved: saved, held: false), "closed in the conversation")
        XCTAssertEqual(ViewerRestore.toRemember(showing: showing, saved: saved, held: true), showing)
        XCTAssertEqual(ViewerRestore.toRemember(showing: showing, saved: nil, held: false), showing)
    }

    func testQuittingFromTheWelcomeKeepsTheRememberedArtifact() throws {
        try rememberedA2()
        let (model, _) = make()
        launched(model)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        XCTAssertFalse(model.isViewerShown(for: 3))
        model.rememberViewerForNextLaunch()
        XCTAssertEqual(model.settings.viewerAtQuit, SavedViewer(chat: 3, artifact: "a2"), "not lost by quitting from the welcome")

        // And again the launch after that: still there for the conversation.
        let (next, _) = make()
        launched(next)
        next.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        next.open(chat: 3)
        XCTAssertEqual(next.current[3]?.id, "a2")
    }

    func testViewingBeforeTheEventsArriveRestoresWhenTheArtifactIsListed() throws {
        try rememberedA2()
        let (model, _) = make()
        launched(model)
        model.open(chat: 3)
        XCTAssertFalse(model.isViewerShown(for: 3), "closed until the artifact is listed again")
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        XCTAssertEqual(model.current[3]?.id, "a2")
        XCTAssertTrue(model.isViewerShown(for: 3))
    }

    func testASendFromTheWelcomeRestoresTheViewer() throws {
        try rememberedA2()
        let (model, _) = make()
        launched(model)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3)))
        model.continueSession(chat: 3, text: "next step")
        XCTAssertEqual(model.mainScreen, .conversation(3))
        XCTAssertEqual(model.current[3]?.id, "a2")
        XCTAssertTrue(model.isViewerShown(for: 3))
    }

    func testPickingAnotherSessionHoldsTheRestoreForTheLiveOne() throws {
        try rememberedA2()
        let (model, _) = make()
        launched(model)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1"), artifact("a2")], truncated: false)))
        model.open(chat: 2)
        XCTAssertNil(model.current[3])
        model.rememberViewerForNextLaunch()
        XCTAssertEqual(model.settings.viewerAtQuit, SavedViewer(chat: 3, artifact: "a2"), "still held for Session 3")
        model.open(chat: 3)
        XCTAssertEqual(model.current[3]?.id, "a2")

        // Once restored, a closed viewer at quit remembers nothing, as before.
        model.setViewer(visible: false, for: 3)
        model.rememberViewerForNextLaunch()
        XCTAssertNil(model.settings.viewerAtQuit)
    }

    func testQuittingWithTheViewerClosedOrEmptyRemembersNothing() throws {
        let (model, _) = try model()
        launched(model)
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [artifact("a1")], truncated: false)))
        model.setViewer(visible: true, for: 3)
        model.rememberViewerForNextLaunch()
        XCTAssertNil(model.settings.viewerAtQuit, "open but empty")

        model.show(try XCTUnwrap(model.artifacts[3]?.first), in: 3)
        model.setViewer(visible: false, for: 3)
        model.rememberViewerForNextLaunch()
        XCTAssertNil(model.settings.viewerAtQuit, "an artifact behind a closed viewer")
    }

    func testAFileOpenedFromTheFilesPaneComesBackToo() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("portico-v06-\(UUID().uuidString).md")
        try "# Notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let (model, _) = try model()
        model.settings.viewerAtQuit = SavedViewer(chat: 3, artifact: AppModel.localArtifactPrefix + file.path)
        launched(model)
        XCTAssertNil(model.current[3], "not beside the welcome (v0.8 decision 1)")
        model.open(chat: 3)
        XCTAssertEqual(model.current[3]?.location, file.path)
        XCTAssertTrue(model.isViewerShown(for: 3))
    }

    // MARK: - 3. the folder tree after a write

    func testTheRelistTriggerIsWritesAndTurnEnds() {
        let tools = ["t1": "Write", "t2": "Read", "t3": "MultiEdit", "t4": "NotebookEdit", "t5": "Edit", "t6": "Bash"]
        func finished(_ id: String) -> ServerMessage {
            .toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: id, ok: true, summary: ""))
        }
        let lookup: (String) -> String? = { tools[$0] }
        XCTAssertTrue(FolderRelist.triggers(finished("t1"), tool: lookup))
        XCTAssertTrue(FolderRelist.triggers(finished("t3"), tool: lookup))
        XCTAssertTrue(FolderRelist.triggers(finished("t4"), tool: lookup))
        XCTAssertTrue(FolderRelist.triggers(finished("t5"), tool: lookup))
        XCTAssertFalse(FolderRelist.triggers(finished("t2"), tool: lookup), "a read changes nothing")
        XCTAssertFalse(FolderRelist.triggers(finished("t6"), tool: lookup), "a command waits for the turn's end")
        XCTAssertFalse(FolderRelist.triggers(finished("unknown"), tool: lookup))
        XCTAssertTrue(FolderRelist.triggers(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .done)), tool: lookup))
        XCTAssertFalse(FolderRelist.triggers(.textDelta(TextDelta(chat: 3, turn: 1, text: "x")), tool: lookup))
    }

    /// The Files pane has listed the folder's top and `notes/`.
    private func listedTree(_ model: AppModel, _ sent: Sent) {
        model.listFiles(chat: 3, root: AppModel.chatRoot, path: "")
        model.listFiles(chat: 3, root: AppModel.chatRoot, path: "notes")
        for frame in sent.frames {
            if case .filesList(let request) = frame {
                model.apply(.filesList(FilesList(
                    root: request.root, path: request.path, entries: [Entry(name: "a.md", dir: false)], chat: 3, id: request.id)))
            }
        }
        sent.frames = []
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testAWriteListsTheSessionsFolderAgainKeepingWhatIsDrawn() async throws {
        let (model, sent) = try model()
        launched(model)
        listedTree(model, sent)
        model.apply(.toolStarted(ToolStarted(chat: 3, turn: 1, toolUseId: "w1", tool: "Write", summary: "notes/b.md", input: [:], seq: 10)))
        model.apply(.toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: "w1", ok: true, summary: "", seq: 11)))
        await settle()
        let paths = sent.frames.compactMap { frame -> String? in
            if case .filesList(let request) = frame { return request.path }
            return nil
        }
        XCTAssertEqual(paths.sorted(), ["", "notes"], "every listed directory of the folder, once")
        XCTAssertEqual(model.fileEntries(chat: 3, root: AppModel.chatRoot, path: "notes")?.map(\.name), ["a.md"],
            "the old listing stays drawn until the new one comes")
    }

    func testABurstOfWritesListsOnce() async throws {
        let (model, sent) = try model()
        model.relistDelay = .milliseconds(50)
        launched(model)
        listedTree(model, sent)
        for n in 1...5 {
            model.apply(.toolStarted(ToolStarted(chat: 3, turn: 1, toolUseId: "e\(n)", tool: "Edit", summary: "a.md", input: [:], seq: 10 + 2 * n)))
            model.apply(.toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: "e\(n)", ok: true, summary: "", seq: 11 + 2 * n)))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 2, "one relist of the two directories")
    }

    func testAReadDoesNotListAgain() async throws {
        let (model, sent) = try model()
        launched(model)
        listedTree(model, sent)
        model.apply(.toolStarted(ToolStarted(chat: 3, turn: 1, toolUseId: "r1", tool: "Read", summary: "a.md", input: [:], seq: 10)))
        model.apply(.toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: "r1", ok: true, summary: "", seq: 11)))
        await settle()
        XCTAssertFalse(sent.types().contains("files.list"))
    }

    func testAChatWhoseFilesAreNotShownForgetsItsListingInstead() async throws {
        let (model, sent) = try model()
        launched(model)
        model.open(chat: 2)
        model.listFiles(chat: 3, root: AppModel.chatRoot, path: "")
        guard case .filesList(let request)? = sent.frames.last else { return XCTFail("expected files.list") }
        model.apply(.filesList(FilesList(root: request.root, path: "", entries: [], chat: 3, id: request.id)))
        sent.frames = []
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 1, outcome: .done, seq: 12)))
        await settle()
        XCTAssertFalse(sent.types().contains("files.list"), "nothing asked for a tree that is not on screen")
        XCTAssertNil(model.fileEntries(chat: 3, root: AppModel.chatRoot, path: ""), "it is listed afresh when shown")
    }

    // MARK: - 4. the way back from an earlier session

    func testTheEarlierBarAndTheCardOfferTheWayBack() throws {
        let (model, _) = try model()
        launched(model)
        XCTAssertFalse(model.showsEarlierBar(chat: 3))
        XCTAssertTrue(model.showsEarlierBar(chat: 2))
        XCTAssertEqual(model.backTarget(from: 2), 3)
        XCTAssertNil(model.backTarget(from: 3))

        XCTAssertTrue(model.cardOpensLiveSession(live: 3), "on the welcome, the card shows the live session")
        model.open(chat: 2)
        XCTAssertTrue(model.cardOpensLiveSession(live: 3), "from an earlier session it is the way back")
        model.openLiveSession(3)
        XCTAssertEqual(model.selected, 3)
        XCTAssertFalse(model.cardOpensLiveSession(live: 3), "on the live session it is just a card")
    }

    func testNoBackButtonWithoutALiveSession() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(2, ended: "2026-10-28T17:00:00Z")])))
        XCTAssertTrue(model.showsEarlierBar(chat: 2))
        XCTAssertNil(model.backTarget(from: 2))
    }

    func testTheEarlierBarSaysWhenItEnded() {
        let now = date("2026-10-29T15:00:00Z")
        func line(_ ended: String) -> String {
            SessionPresentation(summary: session(2, ended: ended)).endedBarLine(now: now, calendar: utc, locale: us)
        }
        XCTAssertEqual(line("2026-10-28T17:00:00Z"), "Session 2 · ended yesterday, 5:00 PM · read-only")
        XCTAssertEqual(line("2026-10-29T14:48:00Z"), "Session 2 · ended 12 min ago · read-only")
        XCTAssertEqual(line("2026-10-29T09:14:00Z"), "Session 2 · ended today, 9:14 AM · read-only")
        XCTAssertEqual(line("2026-10-27T16:12:00Z"), "Session 2 · ended Oct 27, 4:12 PM · read-only")
        XCTAssertEqual(line("2025-10-27T16:12:00Z"), "Session 2 · ended Oct 27, 2025, 4:12 PM · read-only")
    }

    // MARK: - 5. earlier rows

    func testAnEarlierRowsTitleIsBrighterAndMediumOnlyWhenSelected() {
        let rest = EarlierRow.titleStyle(selected: false, untitled: false)
        let selected = EarlierRow.titleStyle(selected: true, untitled: false)
        XCTAssertEqual(rest.weight, .regular)
        XCTAssertEqual(rest.color, Theme.text2)
        XCTAssertEqual(selected.weight, .medium)
        XCTAssertEqual(selected.color, Theme.text)
    }
}
