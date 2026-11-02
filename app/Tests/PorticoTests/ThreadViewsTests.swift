import Foundation
import XCTest

@testable import Portico

/// v0.16 threads on screen (Task 5, AM1–AM4; §9.6): the toolbar, the
/// View menu's ⌃0–⌃2, the brief block, the composer's placeholder, the
/// sidebar's card and rows, the limit card's choices, and what the window
/// does when the thread it shows ends.
@MainActor
final class ThreadViewsTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private static let created = "2026-11-02T12:00:00Z"

    private static func main(_ chat: Int = 3, state: ChatStateWord = .idle) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: state, created: created)
        summary.title = "Acme launch plan"
        return summary
    }

    private static func thread(
        _ chat: Int, slot: Int, state: ChatStateWord = .idle, title: String? = nil, ended: String? = nil,
        lastReply: String? = nil
    ) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: state, created: created)
        summary.title = title
        summary.ended = ended
        summary.parent = 3
        summary.lastReply = lastReply
        summary.thread = ThreadInfo(
            label: "Thread \(slot)", slot: slot, parent: 3, brief: "Review the pricing page on its own.",
            files: [], openedAt: created)
        return summary
    }

    private func model(threads: Bool = true, chats: [ChatSummary]) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: ["log"],
            capabilities: threads ? ["sessions", "files", "threads.v1"] : ["sessions", "files"],
            presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: chats)))
        return (model, sent)
    }

    // MARK: - the toolbar

    /// §9.6: no thread item in the toolbar; the list is the way back and
    /// ⌃0 still works.
    func testTheToolbarHasNoThreadItem() {
        XCTAssertEqual(
            ToolbarLayout.items(showSwitcher: true, showViewerToggle: true),
            [.sidebarToggle, .brand, .switcher, .spacer, .viewerToggle])
    }

    // MARK: - the View menu

    func testTheViewMenuListsMainAndTheOpenThreadsOnlyWithThreadsOn() {
        let chats = [Self.main(3), Self.thread(5, slot: 1)]
        let on = ThreadsPresentation(chats: chats, current: 3)
        let items = ThreadMenuItem.items(threads: on, threadsOn: true)
        XCTAssertEqual(items.map(\.title), ["Main", "Thread 1"])
        XCTAssertEqual(items.map(\.slot), [0, 1])
        XCTAssertEqual(items.map(\.key), ["0", "1"])
        XCTAssertTrue(ThreadMenuItem.items(threads: on, threadsOn: false).isEmpty)

        let both = ThreadsPresentation(chats: chats + [Self.thread(6, slot: 2)], current: 6)
        XCTAssertEqual(ThreadMenuItem.items(threads: both, threadsOn: true).map(\.title), ["Main", "Thread 1", "Thread 2"])
    }

    func testTheViewMenuUsesControlForTheThreadKeys() throws {
        // The commands can't be inspected: the source says ⌃ for the threads.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Portico/PorticoApp.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("ThreadMenuItem.items("))
        XCTAssertTrue(source.contains(".keyboardShortcut(KeyEquivalent(Character(item.key)), modifiers: .control)"))
    }

    // MARK: - the brief

    func testTheBriefHeading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let opened = try XCTUnwrap(SessionTime.parse("2026-11-02T14:05:00Z"))
        XCTAssertEqual(
            BriefBlock.heading(openedAt: opened, calendar: calendar, locale: Locale(identifier: "en_US")),
            "BRIEF FROM MAIN · 2:05 PM")
        XCTAssertEqual(BriefBlock.heading(openedAt: nil), "BRIEF FROM MAIN")
    }

    func testOnlyAThreadsFirstMessageIsItsBrief() {
        let brief = "Review the pricing page on its own."
        let first = TranscriptItem.userText(UserText(chat: 5, turn: 1, text: brief))
        let second = TranscriptItem.userText(UserText(chat: 5, turn: 2, text: "Also the footer."))
        let items: [TranscriptItem] = [first, .assistantText(id: "a", text: "On it."), second]
        XCTAssertEqual(BriefBlock.briefItem(in: items, brief: brief), first.id)
        XCTAssertNil(BriefBlock.briefItem(in: items, brief: nil), "Main has no brief")
    }

    func testTheBriefMatchesWithAttachmentsListedUnderIt() {
        let brief = "Review the pricing page on its own."
        let first = TranscriptItem.userText(UserText(
            chat: 5, turn: 1, text: "  \(brief)\n\nAttached: /tmp/acme/pricing.html"))
        XCTAssertEqual(BriefBlock.briefItem(in: [first], brief: brief + "\n"), first.id)
    }

    func testAFirstMessageThatIsNotTheBriefIsLeftAsItIs() {
        let other = TranscriptItem.userText(UserText(chat: 5, turn: 1, text: "Something the person typed."))
        XCTAssertNil(BriefBlock.briefItem(in: [other], brief: "Review the pricing page on its own."))
        XCTAssertNil(BriefBlock.briefItem(in: [other], brief: "  "), "an empty brief matches nothing")
    }

    // MARK: - the composer

    func testThePlaceholderInAThread() {
        XCTAssertEqual(
            InputBar.placeholder(
                connected: true, renewing: false, logging: false, sending: false, about: nil, agentName: "Acme",
                thread: "Thread 2"),
            "Reply in Thread 2")
        XCTAssertEqual(
            InputBar.placeholder(
                connected: true, renewing: false, logging: false, sending: false, about: nil, agentName: "Acme", thread: nil),
            "Ask Acme, or drop a file here")
        XCTAssertEqual(
            InputBar.placeholder(
                connected: false, renewing: false, logging: false, sending: false, about: nil, agentName: "Acme",
                thread: "Thread 2"),
            "Not connected")
    }

    // MARK: - the sidebar

    func testTheOpenRowIsTheConversationYouAreInAndNothingMoves() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.open(chat: 3)
        XCTAssertEqual(model.sidebarCard?.chat, 3)
        let inMain = model.sidebarThreads.rows(now: Date())
        XCTAssertEqual(inMain.map(\.label), ["Main", "Thread 1", "Thread 2"])
        XCTAssertEqual(inMain.filter(\.isOpen).map(\.chat), [3])

        model.switchToConversation(slot: 2)
        XCTAssertEqual(model.sidebarCard?.chat, 6)
        let inThread = model.sidebarThreads.rows(now: Date())
        XCTAssertEqual(inThread.map(\.label), ["Main", "Thread 1", "Thread 2"], "the same order in a thread")
        XCTAssertEqual(inThread.filter(\.isOpen).map(\.chat), [6])
    }

    func testOnAnEndedSessionMainsRowIsTheOpenOne() {
        var old = Self.main(1)
        old.ended = "2026-11-02T11:00:00Z"
        let (model, _) = model(chats: [old, Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 1)
        XCTAssertEqual(model.sidebarCard?.chat, 3)
        let rows = model.sidebarThreads.rows(now: Date())
        XCTAssertEqual(rows.map(\.label), ["Main", "Thread 1"], "an ended session is in History, not the list")
        XCTAssertEqual(rows.filter(\.isOpen).map(\.chat), [3])
    }

    /// Threads off (threads.max 0, or a gateway without `threads.v1`): the
    /// shipped single-session section, "This session" and "Session N".
    func testWithThreadsOffTheSectionIsTheShippedSessionCard() {
        let (off, _) = model(threads: false, chats: [Self.main(3)])
        XCTAssertFalse(off.threadsOn)
        XCTAssertEqual(SessionSidebar.sectionLabel(threadsOn: off.threadsOn), "This session")
        XCTAssertEqual(SessionCard.title(summary: Self.main(3), threadsOn: false), "Session 3")
        XCTAssertEqual(SessionSidebar.sectionLabel(threadsOn: true), "Conversations")
        XCTAssertEqual(SessionCard.title(summary: Self.main(3), threadsOn: true), "Main")
        XCTAssertEqual(SessionCard.title(summary: Self.thread(5, slot: 1), threadsOn: true), "Thread 1")
    }

    func testTheCloseQuestion() {
        XCTAssertEqual(ThreadsPresentation.closeQuestion(label: "Thread 2"), "Thread 2 is still working. Close it anyway?")
    }

    // MARK: - the limit card

    func testTheLimitCardListsBothThreadsWithTitleAndLastActivity() throws {
        let now = try XCTUnwrap(SessionTime.parse("2026-11-02T14:00:00Z"))
        let chats = [
            Self.main(3),
            Self.thread(5, slot: 1, title: "Pricing page", lastReply: "2026-11-02T13:40:00Z"),
            Self.thread(6, slot: 2, state: .working, title: "Onboarding copy"),
        ]
        let choices = ThreadsPresentation(chats: chats, current: 3).limitChoices(now: now)
        XCTAssertEqual(choices.map(\.chat), [5, 6])
        XCTAssertEqual(choices.map(\.label), ["Thread 1", "Thread 2"])
        XCTAssertEqual(choices.map(\.line), ["Pricing page · last reply 20 min ago", "Onboarding copy · working now"])
    }

    // MARK: - closing

    func testThePreflightRefusalOffersClosingWithoutLogging() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.requestCloseThread(chat: 5)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(
            code: "lifecycle.before_first_chat_failed", message: "cannot open a chat: the hook failed", chat: 5, id: close.id)))
        XCTAssertEqual(model.closeFailures[5]?.offersCloseWithoutLogging, true)
    }

    func testAFailedCloseShowsOnTheThreadsRowInMain() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 3)
        model.requestCloseThread(chat: 5)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(code: "engine.start_failed", message: "the engine could not start", chat: 5, id: close.id)))
        let row = model.sidebarThreads.rows(now: Date()).first { $0.chat == 5 }
        XCTAssertEqual(row?.closeFailure?.message, "the engine could not start")
        XCTAssertEqual(row?.closeFailure?.offersCloseWithoutLogging, true)
        model.closeThreadWithoutLogging(chat: 5)
        guard case .threadClose(let plain)? = sent.frames.last else { return XCTFail("expected thread.close") }
        XCTAssertFalse(plain.log)
    }

    func testACloseAndStartWhoseCloseCannotLogOffersClosingWithoutLogging() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        let proposal = ThreadProposal(
            chat: 3, proposal: "p1", toolUseId: "toolu_p1", brief: "Check the checkout flow.", state: .pending)
        model.apply(.threadProposal(proposal))
        model.startThread(proposal, closing: 5)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        model.apply(.error(ErrorMessage(
            code: "lifecycle.before_first_chat_failed", message: "cannot open a chat: the hook failed", chat: 3, id: start.id)))
        XCTAssertNil(model.startingProposal, "the limit card is usable again")
        XCTAssertEqual(model.closeFailures[5]?.offersCloseWithoutLogging, true)
        XCTAssertEqual(
            model.threads.limitChoices(now: Date()).first { $0.chat == 5 }?.closeFailure?.message,
            "cannot open a chat: the hook failed")
    }

    func testAStartRefusedForAnotherReasonRecordsNoCloseFailure() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        let proposal = ThreadProposal(
            chat: 3, proposal: "p1", toolUseId: "toolu_p1", brief: "Check the checkout flow.", state: .pending)
        model.apply(.threadProposal(proposal))
        model.startThread(proposal, closing: 5)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        model.apply(.error(ErrorMessage(code: "thread.proposal_resolved", message: "already started", chat: 3, id: start.id)))
        XCTAssertNil(model.closeFailures[5])
    }

    func testSpokenLabels() {
        XCTAssertEqual(ThreadsPresentation.goLabel(label: "Thread 2"), "Go to Thread 2")
        let row = ThreadRowPresentation(chat: 6, label: "Thread 2", title: "Onboarding copy", status: .needsYou, keyName: "Control-2")
        XCTAssertEqual(row.spokenLabel, "Thread 2, needs you")
        XCTAssertEqual(
            ThreadRowPresentation(chat: 5, label: "Thread 1", title: nil, status: .working, keyName: "Control-1").spokenLabel,
            "Thread 1, working")
        XCTAssertEqual(
            ThreadRowPresentation(chat: 3, label: "Main", title: nil, status: .lastReply("5 min ago"), keyName: "Control-0").spokenLabel,
            "Main, last reply 5 min ago")
    }

    func testWhenTheThreadOnScreenEndsTheWindowGoesBackToMain() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.switchToConversation(slot: 1)
        XCTAssertEqual(model.selected, 5)
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1, ended: "2026-11-02T13:00:00Z")])))
        XCTAssertEqual(model.selected, 3)
    }

    func testAnEndedThreadOpenedFromHistoryStaysOpen() {
        let ended = Self.thread(5, slot: 1, ended: "2026-11-02T13:00:00Z")
        let (model, _) = model(chats: [Self.main(3), ended])
        model.open(chat: 5)
        model.apply(.chatList(ChatList(chats: [Self.main(3), ended])))
        XCTAssertEqual(model.selected, 5, "only a thread that ends while shown sends the window back")
    }

    // MARK: - Changed this session

    func testInAThreadChangedThisSessionIsTheThreadsOwn() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        func write(_ chat: Int, _ id: String, _ path: String, seq: Int) {
            model.apply(.toolStarted(ToolStarted(
                chat: chat, turn: 1, toolUseId: id, tool: "Write", summary: path, input: ["file_path": .string(path)],
                seq: seq, ts: "2026-11-02T13:10:00Z")))
            model.apply(.toolFinished(ToolFinished(
                chat: chat, turn: 1, toolUseId: id, ok: true, summary: "", seq: seq + 1, ts: "2026-11-02T13:10:05Z")))
        }
        write(3, "m", "/tmp/acme/plan.md", seq: 1)
        write(5, "t", "/tmp/acme/pricing.html", seq: 1)
        XCTAssertEqual(model.changedThisSession(chat: 5).map(\.path), ["/tmp/acme/pricing.html"])
        XCTAssertEqual(model.changedThisSession(chat: 3).map(\.path), ["/tmp/acme/plan.md"])
    }
}
