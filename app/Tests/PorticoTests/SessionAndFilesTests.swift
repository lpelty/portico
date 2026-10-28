import Foundation
import XCTest

@testable import Portico

/// v0.2 in the model: the single-session presentation (S1/S2/S5), renewing,
/// context and compaction, and the files work (Quick, quick open, the
/// document view, text search, Obsidian). Model-only, like AppModelTests.
@MainActor
final class SessionAndFilesTests: XCTestCase {

    // MARK: - helpers

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func model() throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v02-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    private func hello(
        single: Bool = true, canLog: Bool = true,
        capabilities: [String] = ["files", "sessions", "files.search", "context"],
        roots: [Root] = []
    ) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.2.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: roots, commands: [],
            capabilities: capabilities, presentation: single ? "single" : "multiple", canLog: canLog)
    }

    private func session(
        _ chat: Int, ended: String? = nil, logged: Bool? = nil, parent: Int? = nil, title: String? = nil,
        compactions: Int? = nil, percent: Double? = nil, folder: String = "/tmp/demo"
    ) -> ChatSummary {
        ChatSummary(
            chat: chat, folder: folder, alias: nil, state: ended == nil ? .idle : .stopped,
            created: "2026-10-27T11:42:00Z", title: title, ended: ended, logged: logged, parent: parent,
            compactions: compactions, contextPercent: percent)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - protocol tolerance

    func testV01HelloAndRecordsDecodeWithDefaults() throws {
        let hello = try JSONDecoder().decode(HelloServer.self, from: Data("""
            {"protocol":1,"gateway_version":"0.1.0","epoch":"e","brand":{"name":"P","agent_name":"A"},
             "actions":[],"roots":[],"commands":[],"capabilities":["files"],"ts":"2026-10-27T12:00:00Z"}
            """.utf8))
        XCTAssertFalse(hello.isSingle, "no presentation means the v0.1 chat list")
        XCTAssertNil(hello.canLog)
        let record = try JSONDecoder().decode(ChatSummary.self, from: Data("""
            {"chat":3,"folder":"/tmp","state":"idle","created":"2026-10-27T12:00:00Z"}
            """.utf8))
        XCTAssertNil(record.ended)
        XCTAssertNil(record.contextPercent)
    }

    // MARK: - launch

    func testSingleLaunchOpensTheLiveSessionDirectly() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(12, ended: "2026-10-26T10:00:00Z", logged: true), session(14), session(13, ended: "2026-10-27T11:40:00Z")])))
        XCTAssertEqual(model.selected, 14)
        XCTAssertEqual(sent.types().last, "chat.open")
        XCTAssertEqual(model.earlierSessions.map(\.chat), [13, 12], "ended sessions, newest first")
    }

    func testSingleWithNoSessionShowsTheStartScreen() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [])))
        XCTAssertNil(model.selected)
    }

    func testMultiplePresentationDoesNotAutoOpen() throws {
        let (model, _) = try model()
        model.apply(.hello(hello(single: false)))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertNil(model.selected, "the v0.1 chat list is unchanged")
        XCTAssertFalse(model.canRenew(chat: 1))
    }

    func testEarlierSearchFiltersByTitle() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [
            session(10, ended: "2026-10-23T10:00:00Z", title: "Pricing notes"),
            session(11, ended: "2026-10-24T10:00:00Z", title: "Onboarding study"),
            session(12),
        ])))
        XCTAssertEqual(model.earlierSessions(matching: "pric").map(\.chat), [10])
        XCTAssertEqual(model.earlierSessions(matching: "  ").map(\.chat), [11, 10])
    }

    // MARK: - renewing

    func testRenewSendsSessionRenewWithLogAndSwitchesOnRenewed() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(canLog: true)))
        model.apply(.chatList(ChatList(chats: [session(14, title: "Q3 synthesis")])))
        model.renew(chat: 14)
        guard case .sessionRenew(let renew)? = sent.frames.last else { return XCTFail("expected session.renew, got \(sent.types())") }
        XCTAssertEqual(renew.chat, 14)
        XCTAssertTrue(renew.log)
        XCTAssertTrue(model.isRenewing(chat: 14))
        model.renew(chat: 14)
        XCTAssertEqual(sent.types().filter { $0 == "session.renew" }.count, 1, "one renew at a time")

        model.apply(.sessionRenewed(SessionRenewed(
            ended: session(14, ended: "2026-10-27T13:40:00Z", logged: true, title: "Q3 synthesis"),
            next: session(15, parent: 14), id: renew.id)))
        XCTAssertFalse(model.isRenewing(chat: 14))
        XCTAssertEqual(model.selected, 15)
        XCTAssertEqual(model.liveSession?.chat, 15)
        XCTAssertEqual(model.earlierSessions.map(\.chat), [14])
        XCTAssertTrue(model.isEnded(chat: 14))
        XCTAssertEqual(sent.types().last, "chat.open")
    }

    func testRenewWithoutALogStepSaysSo() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(canLog: false)))
        model.apply(.chatList(ChatList(chats: [session(2)])))
        model.renew(chat: 2)
        guard case .sessionRenew(let renew)? = sent.frames.last else { return XCTFail("expected session.renew") }
        XCTAssertFalse(renew.log)
    }

    func testTypingNewAloneRenewsInSingleAndIsTextOtherwise() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(4)])))
        model.setDraft(" /new ", for: 4)
        model.sendMessage(chat: 4, text: " /new ")
        XCTAssertEqual(sent.types().last, "session.renew")
        XCTAssertEqual(model.draft(for: 4), "", "the composer clears")

        model.sendMessage(chat: 4, text: "/new please")
        XCTAssertEqual(sent.types().last, "message.send", "only /new alone renews")

        let (multi, multiSent) = try self.model()
        multi.apply(.hello(hello(single: false)))
        multi.apply(.chatList(ChatList(chats: [session(4)])))
        multi.sendMessage(chat: 4, text: "/new")
        XCTAssertEqual(multiSent.types().last, "message.send", "multiple presentation sends it as text")
    }

    func testRenewNeedsTheSessionsCapability() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(capabilities: ["files"])))
        model.apply(.chatList(ChatList(chats: [session(4)])))
        model.renew(chat: 4)
        XCTAssertFalse(sent.types().contains("session.renew"))
    }

    func testRefusedRenewIsNoLongerBusy() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(4)])))
        model.renew(chat: 4)
        guard case .sessionRenew(let renew)? = sent.frames.last else { return XCTFail() }
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "busy", chat: 4, id: renew.id)))
        XCTAssertFalse(model.isRenewing(chat: 4))
        XCTAssertEqual(model.status[4], "busy")
    }

    // MARK: - context, compaction, the nudge

    func testContextUsageReachesTheCardAndTheStrip() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, percent: 40)])))
        XCTAssertEqual(model.contextPercent(for: 1), 40, "the record's value until a usage arrives")
        XCTAssertNil(model.modelName(for: 1))
        model.apply(.contextUsage(ContextUsage(chat: 1, percent: 62.4, model: "claude-sonnet-5-5")))
        XCTAssertEqual(model.contextPercent(for: 1), 62.4)
        XCTAssertEqual(model.modelName(for: 1), "claude-sonnet-5-5")
        let strip = model.statusStrip(gateway: .running(port: 1))
        XCTAssertEqual(strip.modelText, "Claude Sonnet 5.5")
        XCTAssertEqual(StatusStripPresentation.modelDisplayName("claude-opus-4-1-20250805"), "Claude Opus 4.1")
        XCTAssertEqual(StatusStripPresentation.modelDisplayName("gpt-6"), "gpt-6")
        XCTAssertEqual(strip.contextText, "62% context")
        XCTAssertTrue(strip.text.contains("62% context"))
    }

    func testCompactionDrawsALineLiveAndInReplay() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        model.apply(.chatCompacted(ChatCompacted(chat: 1, trigger: "auto", seq: 5)))
        model.apply(.chatCompacted(ChatCompacted(chat: 1, trigger: "auto", seq: 5)))
        XCTAssertEqual(model.compactions(for: 1), 1, "a re-sent frame is not applied twice")

        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .turnStarted(TurnStarted(chat: 1, turn: 1)),
            .chatCompacted(ChatCompacted(chat: 1, trigger: "auto")),
            .chatCompacted(ChatCompacted(chat: 1, trigger: "manual")),
        ], truncated: false)))
        let lines = (model.transcripts[1] ?? []).filter { if case .compacted = $0 { true } else { false } }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(model.compactions(for: 1), 2)
    }

    func testNudgeAtEightyPercentOrTwoCompactionsAndNotNow() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, percent: 79.9), session(2, compactions: 2), session(3, ended: "2026-10-27T12:00:00Z", percent: 95)])))
        XCTAssertFalse(model.shouldNudge(chat: 1))
        XCTAssertTrue(model.shouldNudge(chat: 2), "two compactions")
        XCTAssertFalse(model.shouldNudge(chat: 3), "an ended session never nudges")
        model.apply(.contextUsage(ContextUsage(chat: 1, percent: 80)))
        XCTAssertTrue(model.shouldNudge(chat: 1))
        model.dismissNudge(chat: 1)
        XCTAssertFalse(model.shouldNudge(chat: 1), "Not now holds for that session")
        XCTAssertTrue(model.shouldNudge(chat: 2))
    }

    // MARK: - what the frames say

    func testSessionLinesAndTimes() {
        let parent = SessionPresentation(summary: session(13, ended: "2026-10-27T11:40:00Z", logged: true, title: "Interview codebook"))
        XCTAssertEqual(parent.parentLine(calendar: utc), "Session 13 · Interview codebook · logged 11:40")
        let unlogged = SessionPresentation(summary: session(13, ended: "2026-10-27T11:40:00Z", logged: false))
        XCTAssertEqual(unlogged.parentLine(calendar: utc), "Session 13 · not logged")
        let current = SessionPresentation(summary: session(14, title: "Q3 synthesis"))
        XCTAssertEqual(current.startedLine(calendar: utc), "Started 11:42 · Q3 synthesis")
        XCTAssertEqual(current.startedSecondLine(calendar: utc), "Session 14 · started 11:42")

        let start = SessionTime.parse("2026-10-27T11:42:00Z")!
        XCTAssertEqual(SessionTime.age(since: start, now: start.addingTimeInterval(2 * 3600 + 120)), "2 h")
        XCTAssertEqual(SessionTime.age(since: start, now: start.addingTimeInterval(12 * 60)), "12 m")
        let now = SessionTime.parse("2026-10-29T15:00:00Z")!  // a Thursday
        XCTAssertEqual(SessionTime.relativeDay(SessionTime.parse("2026-10-29T11:40:00Z")!, now: now, calendar: utc), "11:40")
        XCTAssertEqual(SessionTime.relativeDay(SessionTime.parse("2026-10-27T11:40:00Z")!, now: now, calendar: utc), "Tue")
        XCTAssertEqual(SessionTime.relativeDay(SessionTime.parse("2026-10-01T11:40:00Z")!, now: now, calendar: utc), "Oct 1")
        XCTAssertNotNil(SessionTime.parse("2026-10-27T11:42:00.123Z"), "fractional seconds parse too")
    }

    // MARK: - Quick: touched and pinned

    private func tool(_ chat: Int, _ id: String, _ tool: String, path: String, seq: Int) -> ServerMessage {
        .toolStarted(ToolStarted(chat: chat, turn: 1, toolUseId: id, tool: tool, summary: path, input: ["file_path": .string(path)], seq: seq))
    }

    func testTouchedFilesComeFromToolEventsNewestFirst() throws {
        let (model, _) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, folder: "/tmp/demo")])))
        model.apply(tool(1, "a", "Read", path: "/tmp/demo/P01.md", seq: 1))
        model.apply(tool(1, "b", "Read", path: "notes/P02.md", seq: 2))
        model.apply(tool(1, "c", "Write", path: "/tmp/demo/Q3.md", seq: 3))
        model.apply(tool(1, "d", "Read", path: "/tmp/demo/P01.md", seq: 4))
        model.apply(.toolStarted(ToolStarted(chat: 1, turn: 1, toolUseId: "e", tool: "Bash", summary: "ls -la", input: ["command": .string("ls")], seq: 5)))
        let touched = model.touchedFiles(chat: 1)
        XCTAssertEqual(touched.map(\.path), ["/tmp/demo/P01.md", "/tmp/demo/Q3.md", "/tmp/demo/notes/P02.md"])
        XCTAssertEqual(touched.map(\.verb), ["read", "wrote", "read"])
    }

    func testTouchedReadsFoldPastFour() {
        let reads = (1...12).map { TouchedFile(path: "/r/\($0).md", wrote: false) }
        let list = TouchedList([TouchedFile(path: "/w/Q3.md", wrote: true)] + reads)
        XCTAssertEqual(list.shown.map(\.path), ["/w/Q3.md", "/r/1.md", "/r/2.md"])
        XCTAssertEqual(list.moreRead, 10)
        let few = TouchedList(Array(reads.prefix(4)))
        XCTAssertEqual(few.shown.count, 4)
        XCTAssertEqual(few.moreRead, 0)
    }

    func testPinsPersistInSettings() throws {
        let suite = "portico-pins-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.togglePin("/tmp/demo/Q3.md")
        model.togglePin("/tmp/demo/plan.md")
        XCTAssertTrue(model.isPinned("/tmp/demo/Q3.md"))
        XCTAssertEqual(Settings(defaults: defaults).pinnedFiles, ["/tmp/demo/Q3.md", "/tmp/demo/plan.md"])
        model.togglePin("/tmp/demo/Q3.md")
        XCTAssertEqual(Settings(defaults: defaults).pinnedFiles, ["/tmp/demo/plan.md"])
    }

    // MARK: - quick open

    func testQuickOpenRanksPinnedThenTouchedThenPrefix() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(roots: [Root(name: "Research vault", path: "/vault")])))
        model.apply(.chatList(ChatList(chats: [session(1, folder: "/tmp/demo")])))
        model.listFiles(chat: 1, root: "Research vault", path: "Reports")
        guard case .filesList(let request)? = sent.frames.last else { return XCTFail() }
        model.apply(.filesList(FilesList(root: "Research vault", path: "Reports", entries: [
            Entry(name: "Q2-synthesis.md", dir: false), Entry(name: "Q3-synthesis.md", dir: false),
            Entry(name: "synthesis-template.md", dir: false), Entry(name: "other.md", dir: false),
            Entry(name: "Archive", dir: true),
        ], id: request.id)))
        model.togglePin("/vault/Reports/Q3-synthesis.md")
        model.apply(tool(1, "a", "Read", path: "/vault/Reports/Q2-synthesis.md", seq: 1))

        let items = model.quickOpenItems(chat: 1, query: "synth")
        XCTAssertEqual(items.map(\.name), ["Q3-synthesis.md", "Q2-synthesis.md", "synthesis-template.md"])
        XCTAssertTrue(items[0].pinned)
        XCTAssertTrue(items[1].touched)
        XCTAssertEqual(items[0].location, "Research vault / Reports")
        XCTAssertEqual(model.quickOpenItems(chat: 1, query: "").count, 4, "empty query lists every file, no folders")
    }

    func testPrefetchIsBoundedAndSkipsHiddenFolders() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(roots: [])))
        model.apply(.chatList(ChatList(chats: [session(1, folder: "/tmp/demo")])))
        model.prefetchFiles(chat: 1)
        guard case .filesList(let top)? = sent.frames.last else { return XCTFail("expected files.list, got \(sent.types())") }
        XCTAssertEqual(top.path, "")
        let dirs = (0..<40).map { Entry(name: "d\($0)", dir: true) } + [Entry(name: ".git", dir: true)]
        model.apply(.filesList(FilesList(root: "chat", path: "", entries: dirs, id: top.id)))
        sent.frames.removeAll()
        model.prefetchFiles(chat: 1)
        let asked = sent.frames.compactMap { if case .filesList(let r) = $0 { r.path } else { nil } }
        XCTAssertEqual(asked.count, AppModel.prefetchInFlight, "a few at a time")
        XCTAssertFalse(asked.contains(".git"))
    }

    // MARK: - the document view and search

    func testDocumentViewSwitchesTheSidebarToQuickAndBack() throws {
        let (model, _) = try model()
        XCTAssertEqual(model.filesTab, .folder)
        model.openDocumentView(file: "/tmp/demo/Q3.md")
        XCTAssertTrue(model.documentMode)
        XCTAssertEqual(model.filesTab, .quick)
        XCTAssertEqual(model.documentFile, "/tmp/demo/Q3.md")
        model.reveal(file: "/tmp/demo/plan.md", in: 1)
        XCTAssertEqual(model.documentFile, "/tmp/demo/plan.md", "quick open lands in the document view while it is open")
        model.toggleDocumentView()
        XCTAssertFalse(model.documentMode)
        XCTAssertEqual(model.filesTab, .folder)
        model.reveal(file: "/tmp/demo/plan.md", in: 1)
        XCTAssertEqual(model.current[1]?.location, "/tmp/demo/plan.md", "otherwise it opens in the viewer")
    }

    func testComposerAimedAtTheOpenFileAttachesIt() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        model.attach(["/tmp/a.md"], to: 1)
        model.sendMessage(chat: 1, text: "What is this?", about: "/tmp/demo/Q3.md")
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail() }
        XCTAssertEqual(message.attachments, ["/tmp/a.md", "/tmp/demo/Q3.md"])
    }

    func testSearchSendsOnePerRootAndGathersHits() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(roots: [Root(name: "projects", path: "/Users/someone/projects")])))
        model.apply(.chatList(ChatList(chats: [session(1, folder: "/tmp/demo")])))
        model.selected = 1
        model.searchFiles(chat: 1, query: "synthesis")
        let searches = sent.frames.compactMap { if case .filesSearch(let s) = $0 { s } else { nil } }
        XCTAssertEqual(searches.map(\.root), ["chat", "projects"])
        XCTAssertTrue(model.fileSearch?.isSearching == true)
        model.apply(.filesResults(FilesResults(root: "projects", query: "synthesis", hits: [Hit(path: "demo/Q3-synthesis.md", snippet: "Across…")], id: searches[1].id)))
        XCTAssertEqual(model.fileSearch?.hits.map(\.absolutePath), ["/Users/someone/projects/demo/Q3-synthesis.md"])
        model.apply(.filesResults(FilesResults(root: "chat", query: "synthesis", hits: [], id: searches[0].id)))
        XCTAssertFalse(model.fileSearch?.isSearching == true)
        // A stale answer goes nowhere; an empty query clears the search.
        model.apply(.filesResults(FilesResults(root: "chat", query: "x", hits: [Hit(path: "x.md")], id: "old")))
        XCTAssertEqual(model.fileSearch?.hits.count, 1)
        model.searchFiles(chat: 1, query: " ")
        XCTAssertNil(model.fileSearch)
    }

    func testSearchNeedsTheCapability() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello(capabilities: ["files"])))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        model.searchFiles(chat: 1, query: "x")
        XCTAssertFalse(sent.types().contains("files.search"))
        XCTAssertNil(model.fileSearch)
    }

    func testObsidianURLEncodesThePath() {
        XCTAssertEqual(
            Obsidian.url(path: "/Users/me/My Vault/Q3 & notes.md")?.absoluteString,
            "obsidian://open?path=%2FUsers%2Fme%2FMy%20Vault%2FQ3%20%26%20notes.md")
    }

    func testTitleFromFirstMessageMatchesTheGatewayRule() {
        XCTAssertEqual(SessionPresentation.title(from: "\n  Pull the themes out  \nsecond line"), "Pull the themes out")
        XCTAssertNil(SessionPresentation.title(from: "  \n \n"))
        XCTAssertEqual(SessionPresentation.title(from: String(repeating: "a", count: 80)), String(repeating: "a", count: 60) + "…")
        XCTAssertEqual(
            SessionPresentation.title(from: "Plan the interview codebook for the Q3 research synthesis, with themes and quotes"),
            "Plan the interview codebook for the Q3 research synthesis…")
    }
}
