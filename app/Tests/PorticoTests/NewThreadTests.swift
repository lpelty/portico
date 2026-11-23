import Foundation
import XCTest

@testable import Portico

/// v0.28 (PORT-77, PORT-80; Bill's rows ZK and ZL): the person opens a
/// thread with one click, an unused one goes away, and a thread is called
/// by its name: written by the app, or typed.
@MainActor
final class NewThreadTests: XCTestCase {
    final class Sent {
        var frames: [ClientMessage] = []
    }

    private static let created = "2026-11-18T12:00:00Z"

    private static func main(_ chat: Int = 3) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: .idle, created: created)
        summary.title = "Mobile login screen"
        return summary
    }

    /// A thread: with a `brief` the agent proposed it, without one the person opened it.
    private static func thread(
        _ chat: Int, slot: Int, title: String? = nil, alias: String? = nil, brief: String = "", state: ChatStateWord = .idle,
        ended: String? = nil
    ) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: alias, state: state, created: created)
        summary.title = title
        summary.ended = ended
        summary.parent = 3
        summary.thread = ThreadInfo(label: "Thread \(slot)", slot: slot, parent: 3, brief: brief, files: [], openedAt: created)
        return summary
    }

    private func model(
        chats: [ChatSummary], capabilities: [String] = ["sessions", "threads.v1", "threads.new.v1", "chat.retitle.v1"]
    ) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.28.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: ["log"],
            capabilities: capabilities, presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: chats)))
        return (model, sent)
    }

    private func starts(_ sent: Sent) -> [ThreadStart] {
        sent.frames.compactMap { if case .threadStart(let start) = $0 { start } else { nil } }
    }

    private func discards(_ sent: Sent) -> [Int] {
        sent.frames.compactMap { if case .threadDiscard(let discard) = $0 { discard.chat } else { nil } }
    }

    // MARK: - names (PORT-80)

    func testAThreadIsCalledByItsNameAndItsNumberIsTheSecondLine() {
        let named = Self.thread(5, slot: 1, title: "Notes app login flow")
        XCTAssertEqual(ThreadName.shown(named), "Notes app login flow")
        XCTAssertEqual(ThreadName.numberLine(named), "Thread 1")

        let unused = Self.thread(6, slot: 2)
        XCTAssertNil(ThreadName.name(unused))
        XCTAssertEqual(ThreadName.shown(unused), "New thread")
        XCTAssertEqual(ThreadName.numberLine(unused), "Thread 2 · nothing sent yet")

        // A thread the agent proposed arrives named, from its brief.
        let proposed = Self.thread(7, slot: 2, brief: "Rewrite onboarding step 2.\nKeep it short.")
        XCTAssertEqual(ThreadName.shown(proposed), "Rewrite onboarding step 2.")
        XCTAssertEqual(ThreadName.numberLine(proposed), "Thread 2")
        XCTAssertNil(ThreadName.numberLine(Self.main()), "Main has no number line")
    }

    func testATypedNameWinsOverTheOneTheAppWrote() {
        let typed = Self.thread(5, slot: 1, title: "Notes app login flow", alias: "Login notes")
        XCTAssertEqual(ThreadName.shown(typed), "Login notes")
        XCTAssertEqual(SessionPresentation(summary: typed).historyTitle, "Login notes · Thread 1")
        var blank = typed
        blank.alias = "  "
        XCTAssertEqual(ThreadName.shown(blank), "Notes app login flow", "saved empty: back to the app's name")
    }

    func testALongNameIsWholeInTheHoverAndTheRowKeepsItsNumber() throws {
        let long = String(repeating: "Notes app login flow ", count: 3).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(long.count, 62)
        let rows = ThreadsPresentation(chats: [Self.main(), Self.thread(5, slot: 1, title: long)], current: 3)
            .rows(now: Date())
        let row = try XCTUnwrap(rows.last)
        XCTAssertEqual(row.label, long)
        XCTAssertEqual(row.subtitle, "Thread 1")
        XCTAssertEqual(row.help, "\(long) · Thread 1 (Control-1)")
    }

    func testRenameSendsTheTypedNameAndAnEmptyOneClearsIt() {
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1, title: "Notes app login flow")])
        model.renaming = 5
        model.rename(chat: 5, to: "  Login notes ")
        XCTAssertNil(model.renaming)
        guard case .chatAlias(let alias)? = sent.frames.last else { return XCTFail("expected chat.alias, got \(sent.frames)") }
        XCTAssertEqual(alias.chat, 5)
        XCTAssertEqual(alias.alias, "Login notes")

        let count = sent.frames.count
        model.rename(chat: 5, to: "Notes app login flow")
        XCTAssertEqual(sent.frames.count, count, "Return on the unchanged name sends nothing")

        model.apply(.chatList(ChatList(chats: [Self.main(), Self.thread(5, slot: 1, title: "Notes app login flow", alias: "Login notes")])))
        model.rename(chat: 5, to: "")
        guard case .chatAlias(let cleared)? = sent.frames.last else { return XCTFail("expected chat.alias") }
        XCTAssertNil(cleared.alias, "saved empty, the thread goes back to a name the app writes")

        // Main's session title renames the same way.
        model.rename(chat: 3, to: "Login screen, mobile")
        guard case .chatAlias(let main)? = sent.frames.last else { return XCTFail("expected chat.alias") }
        XCTAssertEqual(main.chat, 3)
        XCTAssertEqual(main.alias, "Login screen, mobile")
    }

    func testNameItForMeAsksTheGatewayOnlyWhenItWritesNames() {
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1, title: "Notes app login flow")])
        XCTAssertTrue(model.canNameForMe)
        model.nameForMe(chat: 5)
        guard case .chatRetitle(let retitle)? = sent.frames.last else { return XCTFail("expected chat.retitle") }
        XCTAssertEqual(retitle.chat, 5)

        let (older, olderSent) = self.model(chats: [Self.main()], capabilities: ["sessions", "threads.v1", "threads.new.v1"])
        XCTAssertFalse(older.canNameForMe)
        older.nameForMe(chat: 3)
        XCTAssertFalse(olderSent.frames.contains { if case .chatRetitle = $0 { true } else { false } })
    }

    func testTheComposerAndMainsCardsUseTheName() {
        XCTAssertEqual(
            InputBar.placeholder(
                connected: true, renewing: false, logging: false, sending: false, about: nil, agentName: "Agent",
                thread: "Notes app login flow"),
            "Reply in Notes app login flow")
        XCTAssertEqual(
            InputBar.placeholder(
                connected: true, renewing: false, logging: false, sending: false, about: nil, agentName: "Agent",
                thread: "New thread", unusedThread: true),
            "What should this thread work on?")
        XCTAssertEqual(ThreadsPresentation.closeQuestion(label: "Notes app login flow"), "Notes app login flow is still working. Close it anyway?")
        XCTAssertEqual(SessionCard.newSessionLabel, "New session")
        XCTAssertEqual(NewThreadIntro.heading, "New thread")
    }

    // MARK: - New thread (PORT-77)

    func testTheRowShowsOnlyWithAGatewayThatOpensAThreadWithoutAProposal() {
        XCTAssertTrue(model(chats: [Self.main()]).0.canOpenThread)
        XCTAssertFalse(model(chats: [Self.main()], capabilities: ["sessions", "threads.v1"]).0.canOpenThread, "an older gateway")
        XCTAssertFalse(model(chats: []).0.canOpenThread, "no session yet")
        XCTAssertEqual(NewThreadRow.help, "Start a new thread · Control-T")
    }

    func testOneClickOpensAnEmptyThreadAndSwitchesToIt() throws {
        let (model, sent) = model(chats: [Self.main()])
        model.open(chat: 3)
        let focus = model.composerFocusRequests
        model.newThread()
        let start = try XCTUnwrap(starts(sent).last)
        XCTAssertEqual(start.chat, 3)
        XCTAssertNil(start.proposal, "nothing is asked and nothing is taken from Main")
        XCTAssertNil(start.close)
        XCTAssertNotNil(model.openingThread)
        model.newThread()
        XCTAssertEqual(starts(sent).count, 1, "a second click while it opens sends nothing")

        model.apply(.chatState(ChatState(chat: 5, state: .idle, id: start.id)))
        model.apply(.chatList(ChatList(chats: [Self.main(), Self.thread(5, slot: 1)])))
        XCTAssertNil(model.openingThread)
        XCTAssertEqual(model.selected, 5, "the new thread is on screen")
        XCTAssertEqual(model.composerFocusRequests, focus + 1, "the cursor is in its composer")
        XCTAssertTrue(model.isUnusedThread(chat: 5))

        // New thread again, inside the unused one: it is this one.
        model.newThread()
        XCTAssertEqual(starts(sent).count, 1)
        XCTAssertEqual(model.composerFocusRequests, focus + 2)
    }

    func testFromInsideAThreadTheNewOneStillOpensBesideMain() throws {
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1, title: "Notes app login flow")])
        model.open(chat: 5)
        model.newThread()
        XCTAssertEqual(try XCTUnwrap(starts(sent).last).chat, 3)
    }

    func testSwitchingOutOfAnUnusedThreadTakesItAway() {
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1), Self.thread(6, slot: 2, title: "Onboarding copy")])
        model.open(chat: 5)
        XCTAssertEqual(discards(sent), [])
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [5], "left without a message: it goes away")

        model.open(chat: 6)
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [5], "a thread with a name stays")
    }

    func testAThreadWithSomethingTypedOrAttachedOrProposedIsNotTakenAway() {
        let proposed = Self.thread(7, slot: 2, brief: "Rewrite onboarding step 2.")
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1), proposed])
        model.open(chat: 5)
        model.setDraft("half a thought", for: 5)
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [], "typed words are never thrown away")

        model.setDraft("", for: 5)
        model.attach(["/tmp/acme/notes.md"], to: 5)
        model.open(chat: 5)
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [], "nor an attached file")

        model.open(chat: 7)
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [], "a thread the agent proposed is not the person's unused one")
        XCTAssertFalse(model.isUnusedThread(chat: 3), "Main is never one")
    }

    func testAnOlderGatewayIsNeverSentADiscard() {
        let (model, sent) = model(chats: [Self.main(), Self.thread(5, slot: 1)], capabilities: ["sessions", "threads.v1"])
        model.open(chat: 5)
        model.open(chat: 3)
        XCTAssertEqual(discards(sent), [])
    }

    func testAtTheLimitTheRowListsTheThreadsAndClosingOneOpensTheNewThread() throws {
        let now = try XCTUnwrap(SessionTime.parse("2026-11-18T12:30:00Z"))
        let chats = [
            Self.main(), Self.thread(5, slot: 1, title: "Notes app login flow", state: .working),
            Self.thread(6, slot: 2, title: "Onboarding copy", state: .waitingOnYou),
        ]
        let (model, sent) = model(chats: chats)
        model.open(chat: 3)
        model.newThread()
        XCTAssertTrue(model.newThreadLimitShown, "the row stays clickable and offers the open threads")
        XCTAssertEqual(starts(sent), [], "nothing opens until one is closed")
        XCTAssertEqual(NewThreadRow.limitSentence(limit: 2), "Two threads are open, which is the most. Close one to start another.")
        let choices = model.threads.limitChoices(now: now)
        XCTAssertEqual(choices.map(\.label), ["Notes app login flow", "Onboarding copy"])
        XCTAssertEqual(choices.map(\.line), ["Thread 1 · working", "Thread 2 · needs you"])

        model.closeForNewThread(chat: 6)
        XCTAssertFalse(model.newThreadLimitShown)
        let start = try XCTUnwrap(starts(sent).last)
        XCTAssertEqual(start.chat, 3)
        XCTAssertNil(start.proposal)
        XCTAssertEqual(start.close, 6, "the gateway closes it as Close thread does, then opens the new one")
        XCTAssertTrue(model.isClosing(chat: 6))

        // Refused (the close's log step could not start): the thread stays, with the way out.
        model.apply(.error(ErrorMessage(code: "engine.start_failed", message: "the engine did not start", chat: 3, id: start.id)))
        XCTAssertNil(model.openingThread)
        XCTAssertFalse(model.isClosing(chat: 6))
        XCTAssertEqual(model.closeFailures[6]?.offersCloseWithoutLogging, true)
    }

    func testTheNewMessagesGoOutInTheirWireShape() throws {
        let start = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.threadStart(ThreadStart(chat: 3, id: "r1")))) as? [String: Any]
        XCTAssertEqual(start?["type"] as? String, "thread.start")
        XCTAssertNil(start?["proposal"], "no proposal key: the gateway reads that as the person's own thread")
        let discard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.threadDiscard(ThreadDiscard(chat: 5, id: "r2")))) as? [String: Any]
        XCTAssertEqual(discard?["type"] as? String, "thread.discard")
        XCTAssertEqual(discard?["chat"] as? Int, 5)
        let retitle = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.chatRetitle(ChatRetitle(chat: 5, id: "r3")))) as? [String: Any]
        XCTAssertEqual(retitle?["type"] as? String, "chat.retitle")
    }
}
