import Foundation
import XCTest

@testable import Portico

/// v0.16 threads in the protocol and the model (Task 4): Main plus up to
/// two threads, proposals from Main's agent, starting (which leaves the
/// window where it is), closing, the sidebar's rows and the calling card.
@MainActor
final class ThreadsTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
    }

    // MARK: - fixtures

    private static let created = "2026-11-02T12:00:00Z"

    private static func main(_ chat: Int = 3, state: ChatStateWord = .idle, lastReply: String? = nil) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: state, created: created)
        summary.title = "Acme launch plan"
        summary.lastReply = lastReply
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

    private static func proposal(
        _ id: String = "p1", files: [String] = [], state: ProposalState = .pending, thread: Int? = nil
    ) -> ThreadProposal {
        ThreadProposal(
            chat: 3, proposal: id, toolUseId: "toolu_\(id)", brief: "Review the pricing page on its own.",
            files: files, state: state, thread: thread)
    }

    private func model(threads: Bool = true, threadsMax: Int? = nil, chats: [ChatSummary]) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        var hello = Self.hello(threads: threads)
        hello.threadsMax = threadsMax
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: chats)))
        return (model, sent)
    }

    private static func hello(threads: Bool) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: ["log"],
            capabilities: threads ? ["sessions", "threads.v1"] : ["sessions"], presentation: "single", canLog: true)
    }

    private static var examples: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("protocol/examples", isDirectory: true)
    }

    // MARK: - the wire

    func testTheProposalExampleAndAChatListWithAThreadDecode() throws {
        let data = try Data(contentsOf: Self.examples.appendingPathComponent("server.thread.proposal.json"))
        guard case .threadProposal(let proposal) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            return XCTFail("expected thread.proposal")
        }
        XCTAssertEqual(proposal.chat, 14)
        XCTAssertEqual(proposal.proposal, "p-3f9a")
        XCTAssertEqual(proposal.toolUseId, "toolu_09")
        XCTAssertEqual(proposal.files, ["/Users/someone/projects/demo/pricing.html"])
        XCTAssertEqual(proposal.state, .started)
        XCTAssertEqual(proposal.thread, 15)

        let list = try Data(contentsOf: Self.examples.appendingPathComponent("server.chat.list.json"))
        guard case .chatList(let chats) = try JSONDecoder().decode(ServerMessage.self, from: list) else {
            return XCTFail("expected chat.list")
        }
        let thread = try XCTUnwrap(chats.chats.first { $0.chat == 3 }?.thread)
        XCTAssertEqual(thread.label, "Thread 1")
        XCTAssertEqual(thread.slot, 1)
        XCTAssertEqual(thread.parent, 1)
        XCTAssertEqual(thread.openedAt, "2026-10-27T12:00:00Z")
        XCTAssertNil(chats.chats.first { $0.chat == 1 }?.thread)
    }

    func testAnOlderChatListWithoutThreadStillDecodes() throws {
        let json = #"{"type":"chat.list","chats":[{"chat":1,"folder":"/tmp/acme","state":"idle","created":"2026-11-02T12:00:00Z"}],"ts":"2026-11-02T12:00:00Z"}"#
        guard case .chatList(let list) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("expected chat.list")
        }
        XCTAssertNil(list.chats.first?.thread)
    }

    func testTheAppListsThreadsV1() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("threads.v1"))
    }

    func testThreadsAreOnlyOnWithTheCapabilityInSinglePresentation() {
        XCTAssertTrue(model(chats: [Self.main()]).0.threadsOn)
        XCTAssertFalse(model(threads: false, chats: [Self.main()]).0.threadsOn)
    }

    // MARK: - Main

    func testLiveSessionIsMainWhenANewerThreadIsLive() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        XCTAssertEqual(model.liveSession?.chat, 3)
        XCTAssertTrue(model.canRenew(chat: 3))
        XCTAssertFalse(model.canRenew(chat: 5), "a thread never renews; it closes")
        XCTAssertTrue(model.canLogSession(chat: 5), "the thread's card keeps Log session")
        XCTAssertEqual(model.thread(of: 5)?.label, "Thread 1")
        XCTAssertNil(model.thread(of: 3))
    }

    func testNewTypedInAThreadGoesToTheAgent() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.sendMessage(chat: 5, text: "/new")
        guard case .messageSend(let send)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(send.text, "/new")
    }

    // MARK: - ThreadsPresentation

    func testSlotsFreeSlotAndTheLimit() {
        let one = ThreadsPresentation(chats: [Self.main(3), Self.thread(5, slot: 1)], current: 3)
        XCTAssertEqual(one.main?.chat, 3)
        XCTAssertEqual(one.open.map(\.chat), [5])
        XCTAssertEqual(one.freeSlot, 2)
        XCTAssertFalse(one.atLimit)
        XCTAssertNil(one.currentThread)

        // Slot 1 freed and taken again by a newer number: open is by slot.
        let two = ThreadsPresentation(
            chats: [Self.main(3), Self.thread(6, slot: 2), Self.thread(7, slot: 1), Self.thread(5, slot: 1, ended: Self.created)],
            current: 7)
        XCTAssertEqual(two.open.map(\.chat), [7, 6])
        XCTAssertNil(two.freeSlot)
        XCTAssertTrue(two.atLimit)
        XCTAssertEqual(two.currentThread?.label, "Thread 1")

        let none = ThreadsPresentation(chats: [Self.main(3)], current: 3)
        XCTAssertEqual(none.freeSlot, 1)
    }

    func testRowsPutNeedsYouFirstThenMainAndTheThreads() throws {
        let now = try XCTUnwrap(SessionTime.parse("2026-11-02T14:05:00Z"))
        let lastReply = now.addingTimeInterval(-5 * 60)
        let chats = [
            Self.main(3, lastReply: "2026-11-02T14:00:00Z"),
            Self.thread(5, slot: 1, state: .working, title: "Pricing review"),
            Self.thread(6, slot: 2, state: .waitingOnYou, title: "Onboarding copy"),
        ]
        let rows = ThreadsPresentation(chats: chats, current: 5).rows(now: now)
        XCTAssertEqual(rows.map(\.chat), [6, 3])
        XCTAssertEqual(rows[0].label, "Thread 2")
        XCTAssertEqual(rows[0].title, "Onboarding copy")
        XCTAssertEqual(rows[0].status, .needsYou)
        XCTAssertEqual(rows[0].keyName, "Control-2")
        XCTAssertEqual(rows[0].help, "Go to Thread 2 (Control-2)", "the tooltip spells the key; the row shows none")
        XCTAssertEqual(rows[1].label, "Main")
        XCTAssertEqual(rows[1].title, "Acme launch plan")
        XCTAssertEqual(rows[1].status, .lastReply(SessionTime.ago(lastReply, now: now)))
        XCTAssertEqual(rows[1].keyName, "Control-0")

        let fromMain = ThreadsPresentation(chats: chats, current: 3).rows(now: now)
        XCTAssertEqual(fromMain.map(\.chat), [6, 5])
        XCTAssertEqual(fromMain[1].status, .working)
        XCTAssertEqual(fromMain[1].keyName, "Control-1")
    }

    // MARK: - ProposalPresentation

    func testTheOfferAndItsTakesLine() {
        let threads = ThreadsPresentation(chats: [Self.main(3)], current: 3)
        let offer = ProposalPresentation(proposal: Self.proposal(files: ["/w/pricing.html"]), threads: threads)
        XCTAssertEqual(offer.kind, .offer)
        XCTAssertEqual(offer.title, "Start Thread 1")
        XCTAssertEqual(offer.takesLine, "It takes this brief and pricing.html, not this conversation.")
        XCTAssertNil(offer.record)

        XCTAssertEqual(
            ProposalPresentation(proposal: Self.proposal(), threads: threads).takesLine,
            "It takes this brief, not this conversation.")
        XCTAssertEqual(
            ProposalPresentation(proposal: Self.proposal(files: ["/w/a.html", "/w/b.md", "/w/c.csv"]), threads: threads).takesLine,
            "It takes this brief and a.html, b.md and c.csv, not this conversation.")
        XCTAssertEqual(
            ProposalPresentation(proposal: Self.proposal(files: ["/w/a.html", "/w/b.md"]), threads: threads).takesLine,
            "It takes this brief and a.html and b.md, not this conversation.")
    }

    func testAtTheLimitTheCardAsksToCloseOne() {
        let threads = ThreadsPresentation(
            chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)], current: 3)
        let card = ProposalPresentation(proposal: Self.proposal(), threads: threads)
        XCTAssertEqual(card.kind, .atLimit)
        XCTAssertEqual(card.title, "Close a thread to start another")
        XCTAssertNil(card.record)
    }

    func testTheRecords() {
        let open = ThreadsPresentation(chats: [Self.main(3), Self.thread(5, slot: 1)], current: 3)
        let started = ProposalPresentation(proposal: Self.proposal(state: .started, thread: 5), threads: open)
        XCTAssertEqual(started.kind, .started)
        XCTAssertEqual(started.record, "Thread 1 started")
        XCTAssertEqual(started.goLabel, "Go to Thread 1")
        XCTAssertEqual(started.goHelp, "Control-1")
        XCTAssertEqual(started.goSlot, 1)

        let closed = ThreadsPresentation(chats: [Self.main(3), Self.thread(5, slot: 1, ended: Self.created)], current: 3)
        let afterClose = ProposalPresentation(proposal: Self.proposal(state: .started, thread: 5), threads: closed)
        XCTAssertEqual(afterClose.record, "Thread 1 started")
        XCTAssertNil(afterClose.goLabel, "a closed thread has nowhere to go")
        XCTAssertNil(afterClose.goSlot)

        let dismissed = ProposalPresentation(proposal: Self.proposal(state: .dismissed), threads: open)
        XCTAssertEqual(dismissed.kind, .notStarted)
        XCTAssertEqual(dismissed.record, "Not started")
        XCTAssertNil(dismissed.goLabel)
    }

    // MARK: - starting

    func testStartThreadSendsThreadStartOnTheWire() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }
        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.16.0-test")
        let model = AppModel()
        model.apply(.hello(Self.hello(threads: true)))
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])))
        model.outbound = { message in Task { try? await client.send(message) } }

        model.startThread(Self.proposal(), closing: 5)

        let received = await gateway.waitForFrame(type: "thread.start", seconds: 5)
        let frame = try XCTUnwrap(received)
        XCTAssertEqual(frame["chat"] as? Int, 3)
        XCTAssertEqual(frame["proposal"] as? String, "p1")
        XCTAssertEqual(frame["close"] as? Int, 5)
        XCTAssertNotNil(frame["id"] as? String, "a request: its answer and its errors carry the id")
        await client.disconnect()
    }

    func testStartThreadBelowTheLimitCarriesNoClose() throws {
        let (model, sent) = model(chats: [Self.main(3)])
        model.startThread(Self.proposal(), closing: nil)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.threadStart(start))) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "thread.start")
        XCTAssertEqual(object["chat"] as? Int, 3)
        XCTAssertEqual(object["proposal"] as? String, "p1")
        XCTAssertNil(object["close"])
        XCTAssertEqual(model.startingProposal, "p1")

        // A second Start while the first is out sends nothing (Review Focus 1).
        let count = sent.frames.count
        model.startThread(Self.proposal(), closing: nil)
        XCTAssertEqual(sent.frames.count, count)
    }

    func testStartingLeavesTheWindowWhereItIs() throws {
        let (model, sent) = model(chats: [Self.main(3)])
        model.open(chat: 3)
        model.apply(.threadProposal(Self.proposal()))
        XCTAssertEqual(model.proposal(forToolUse: "toolu_p1")?.proposal, "p1")
        XCTAssertEqual(model.proposalPresentation(for: try XCTUnwrap(model.proposal(forToolUse: "toolu_p1"))).kind, .offer)

        model.startThread(try XCTUnwrap(model.proposals["p1"]), closing: nil)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }

        // The answer, in the gateway's order: chat.state (with the id), chat.list, thread.proposal.
        model.apply(.chatState(ChatState(chat: 5, state: .idle, id: start.id)))
        XCTAssertEqual(model.selected, 3, "Start does not switch the window (Ruling 6, overridden)")
        XCTAssertTrue(model.openedChats.contains(5), "the new thread is loaded, not shown")
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1, state: .working)])))
        model.apply(.threadProposal(Self.proposal(state: .started, thread: 5)))
        XCTAssertEqual(model.selected, 3)
        XCTAssertNil(model.startingProposal)

        let card = model.proposalPresentation(for: try XCTUnwrap(model.proposals["p1"]))
        XCTAssertEqual(card.kind, .started)
        XCTAssertEqual(card.record, "Thread 1 started")
        XCTAssertEqual(card.goLabel, "Go to Thread 1")
    }

    func testARefusedStartClearsTheDimmedCard() throws {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.startThread(Self.proposal(), closing: 5)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        XCTAssertEqual(start.close, 5)
        XCTAssertEqual(model.startingProposal, "p1")

        // The close's log step could not start: nothing new, the card usable again (Review Focus 2).
        model.apply(.error(ErrorMessage(code: "engine.send_failed", message: "The log step couldn't start.", chat: 3, id: start.id)))
        XCTAssertNil(model.startingProposal)
        model.startThread(Self.proposal(), closing: 6)
        guard case .threadStart(let again)? = sent.frames.last else { return XCTFail("expected a second thread.start") }
        XCTAssertEqual(again.close, 6)
    }

    func testDismissSendsThreadDismiss() {
        let (model, sent) = model(chats: [Self.main(3)])
        model.dismissProposal(Self.proposal())
        guard case .threadDismiss(let dismiss)? = sent.frames.last else { return XCTFail("expected thread.dismiss") }
        XCTAssertEqual(dismiss.chat, 3)
        XCTAssertEqual(dismiss.proposal, "p1")
        XCTAssertNotNil(dismiss.id)
    }

    func testADoubleClickOnNotNowSendsOneDismiss() {
        let (model, sent) = model(chats: [Self.main(3)])
        model.dismissProposal(Self.proposal())
        model.dismissProposal(Self.proposal())
        let dismisses = sent.frames.compactMap { if case .threadDismiss(let d) = $0 { d } else { nil } }
        XCTAssertEqual(dismisses.count, 1)
        XCTAssertTrue(model.dismissingProposals.contains("p1"))

        // Refused: Not now works again. Answered: no longer in flight.
        model.apply(.error(ErrorMessage(code: "thread.proposal_resolved", message: "already started", chat: 3, id: dismisses[0].id)))
        XCTAssertFalse(model.dismissingProposals.contains("p1"))
        model.dismissProposal(Self.proposal())
        model.apply(.threadProposal(Self.proposal(state: .dismissed)))
        XCTAssertFalse(model.dismissingProposals.contains("p1"))
        XCTAssertEqual(sent.frames.filter { if case .threadDismiss = $0 { true } else { false } }.count, 2)
    }

    func testAStartedCardStaysDimmedUntilItsThreadIsListed() {
        let (model, sent) = model(chats: [Self.main(3)])
        model.startThread(Self.proposal(), closing: nil)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        model.apply(.chatState(ChatState(chat: 5, state: .idle, id: start.id)))
        model.apply(.threadProposal(Self.proposal(state: .started, thread: 5)))
        XCTAssertEqual(model.startingProposal, "p1", "no \"Thread started\" placeholder: dimmed until listed")
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1)])))
        XCTAssertNil(model.startingProposal)
    }

    // MARK: - closing

    func testClosingAWorkingThreadAsksFirst() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1, state: .working)])
        let count = sent.frames.count
        model.requestCloseThread(chat: 5)
        XCTAssertEqual(model.closingThread, 5)
        XCTAssertEqual(sent.frames.count, count, "nothing goes until the person confirms")

        model.confirmCloseThread()
        XCTAssertNil(model.closingThread)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        XCTAssertEqual(close.chat, 5)
        XCTAssertTrue(close.log)
        XCTAssertNotNil(close.id)
    }

    func testClosingAnIdleThreadSendsAtOnce() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.requestCloseThread(chat: 5)
        XCTAssertNil(model.closingThread)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        XCTAssertEqual(close.chat, 5)
        XCTAssertEqual(model.closingThreads[5], close.id)

        // Main is not a thread: nothing to close.
        let count = sent.frames.count
        model.requestCloseThread(chat: 3)
        XCTAssertEqual(sent.frames.count, count)
    }

    func testACloseThatCannotLogOffersClosingWithoutLogging() throws {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.requestCloseThread(chat: 5)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(code: "engine.send_failed", message: "The log step couldn't start.", chat: 5, id: close.id)))
        XCTAssertNil(model.closingThreads[5])
        XCTAssertEqual(model.closeFailures[5]?.message, "The log step couldn't start.")
        XCTAssertEqual(model.closeFailures[5]?.offersCloseWithoutLogging, true)

        model.closeThreadWithoutLogging(chat: 5)
        guard case .threadClose(let plain)? = sent.frames.last else { return XCTFail("expected thread.close") }
        XCTAssertFalse(plain.log)
        XCTAssertNil(model.closeFailures[5])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.threadClose(plain))) as? [String: Any])
        XCTAssertEqual(object["log"] as? Bool, false)

        model.apply(.chatState(ChatState(chat: 5, state: .stopped, id: plain.id)))
        XCTAssertNil(model.closingThreads[5])
    }

    func testOnlyALogStepThatCannotStartOffersClosingWithoutLogging() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.requestCloseThread(chat: 5)
        guard case .threadClose(let busy)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "a log step is running in chat 5", chat: 5, id: busy.id)))
        XCTAssertNil(model.closeFailures[5], "a refusal Close without logging cannot help draws no red line")
        XCTAssertNil(model.closingThreads[5], "the close is no longer in flight")
        XCTAssertEqual(model.status[5], "a log step is running in chat 5", "the status line says why, as any refusal")

        model.requestCloseThread(chat: 6)
        guard case .threadClose(let start)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(code: "engine.start_failed", message: "the engine could not start", chat: 6, id: start.id)))
        XCTAssertEqual(model.closeFailures[6]?.offersCloseWithoutLogging, true)
    }

    /// Close thread on the thread a Close and start is closing: the gateway
    /// would refuse it (`thread.not_open`), so it is not offered until the
    /// start is answered.
    func testCloseThreadWaitsWhileACloseAndStartIsClosingThatThread() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.startThread(Self.proposal(), closing: 5)
        guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
        XCTAssertTrue(model.isClosing(chat: 5), "the Close and start is closing it")
        XCTAssertFalse(model.isClosing(chat: 6))
        let count = sent.frames.count
        model.requestCloseThread(chat: 5)
        model.closeThreadWithoutLogging(chat: 5)
        XCTAssertEqual(sent.frames.count, count, "no thread.close for a thread already being closed")
        model.requestCloseThread(chat: 6)
        XCTAssertEqual(sent.frames.count, count + 1, "the other thread still closes")

        // Refused (not the log step): the thread is open again and Close thread is offered.
        model.apply(.error(ErrorMessage(code: "thread.limit", message: "two threads are open", chat: 3, id: start.id)))
        XCTAssertFalse(model.isClosing(chat: 5))
        XCTAssertNil(model.closeFailures[5])
    }

    func testARaceRefusedCloseDrawsNoRedLine() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.requestCloseThread(chat: 5)
        guard case .threadClose(let close)? = sent.frames.last else { return XCTFail("expected thread.close") }
        model.apply(.error(ErrorMessage(code: "thread.not_open", message: "chat 5 is not an open thread", chat: 5, id: close.id)))
        XCTAssertNil(model.closeFailures[5], "only a log step that could not start goes on the red line")
        XCTAssertNil(model.closingThreads[5])
    }

    /// A refused `thread.start` that is not a log-step failure still tells
    /// the person: the card is usable again and Main's status line says why.
    func testARefusedStartSaysWhyOnMainsStatusLine() {
        for (code, message) in [
            ("thread.limit", "At most 2 threads can be open. Close one to start another."),
            ("thread.not_open", "chat 5 is not an open thread"),
            ("gateway.error", "thread.start failed: boom"),
        ] {
            let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
            model.open(chat: 3)
            model.startThread(Self.proposal(), closing: 5)
            guard case .threadStart(let start)? = sent.frames.last else { return XCTFail("expected thread.start") }
            model.apply(.error(ErrorMessage(code: code, message: message, chat: 3, id: start.id)))
            XCTAssertNil(model.startingProposal, code)
            XCTAssertEqual(model.status[3], message, "\(code): the person sees why under Main's conversation")
            XCTAssertNil(model.closeFailures[5], code)
        }
    }

    // MARK: - the limit the gateway sets

    func testMaxOneWithOneOpenThreadIsAtTheLimit() throws {
        let (model, _) = model(threadsMax: 1, chats: [Self.main(3), Self.thread(5, slot: 1)])
        XCTAssertEqual(model.threads.limit, 1)
        XCTAssertTrue(model.threads.atLimit)
        let card = model.proposalPresentation(for: Self.proposal())
        XCTAssertEqual(card.kind, .atLimit)
        XCTAssertEqual(card.title, "Close a thread to start another")
    }

    func testNoThreadsMaxBehavesAsTwo() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        XCTAssertNil(model.hello?.threadsMax)
        XCTAssertEqual(model.threads.limit, 2)
        let card = model.proposalPresentation(for: Self.proposal())
        XCTAssertEqual(card.kind, .offer)
        XCTAssertEqual(card.title, "Start Thread 2")
    }

    func testTheHelloCarriesThreadsMax() throws {
        let json = #"{"type":"hello","protocol":1,"gateway_version":"0.16.0","epoch":"e","brand":{"name":"Portico","agent_name":"Acme"},"actions":[],"roots":[],"commands":[],"capabilities":["threads.v1"],"threads_max":1,"ts":"2026-11-02T12:00:00Z"}"#
        guard case .hello(let hello) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(hello.threadsMax, 1)
    }

    // MARK: - a thread calling you

    private static func question(chat: Int, id: String) -> CardAsk {
        CardAsk(
            chat: chat, id: id, kind: .question, title: "Acme has a question", permission: nil,
            questions: [Question(
                question: "Which tone for step 2?\nPick the one that reads best.", header: "Tone",
                options: [Option(label: "Plain", description: "Short words")], multiSelect: false)],
            form: nil, toolUseId: "toolu_\(id)", seq: 4)
    }

    func testAThreadAskingShowsACallingCardInMainOnly() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.open(chat: 3)
        let count = sent.frames.count

        model.apply(.cardAsk(Self.question(chat: 6, id: "card-1")))
        let cards = model.callingCards(in: 3)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.thread, 6)
        XCTAssertEqual(cards.first?.slot, 2)
        XCTAssertEqual(cards.first?.cardId, "card-1")
        XCTAssertEqual(cards.first?.title, "Thread 2 has a question")
        XCTAssertEqual(cards.first?.line, "Which tone for step 2?")
        XCTAssertEqual(cards.first?.goLabel, "Go to Thread 2")
        XCTAssertEqual(cards.first?.goHelp, "Control-2")
        XCTAssertEqual(model.callingCards(in: 5), [], "a thread never shows another's call")
        // Review Focus 4: never a transcript item in Main, never sent anywhere.
        XCTAssertFalse((model.transcripts[3] ?? []).contains { if case .card = $0 { true } else { false } })
        XCTAssertEqual(sent.frames.count, count)

        // Answered in the thread: the call goes.
        model.apply(.cardAnswered(CardAnswered(chat: 6, id: "card-1", seq: 5)))
        XCTAssertEqual(model.callingCards(in: 3), [])
    }

    func testLaterHidesTheCardButTheRowStillNeedsYou() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.open(chat: 3)
        model.apply(.cardAsk(Self.question(chat: 6, id: "card-2")))
        let card = model.callingCards(in: 3)[0]
        model.dismissCalling(card)
        XCTAssertEqual(model.callingCards(in: 3), [])
        XCTAssertEqual(model.threads.rows(now: Date()).first { $0.chat == 6 }?.status, .needsYou)
    }

    func testAPermissionCallsWithItsSummary() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.apply(.cardAsk(CardAsk(
            chat: 5, id: "card-3", kind: .permission, title: "Allow Bash?",
            permission: Permission(tool: "Bash", summary: "Run npm test", input: [:]), questions: nil, form: nil,
            toolUseId: "toolu_b", seq: 2)))
        let cards = model.callingCards(in: 3)
        XCTAssertEqual(cards.map(\.title), ["Thread 1 has a question"])
        XCTAssertEqual(cards.map(\.line), ["Run npm test"])
    }

    func testNoCallingCardsWithThreadsOff() {
        let (model, _) = model(threads: false, chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.apply(.cardAsk(Self.question(chat: 5, id: "card-4")))
        XCTAssertEqual(model.callingCards(in: 3), [])
    }

    // MARK: - a thread finishing (§9.3)

    /// One live turn in `chat`: the person's message, the agent's reply, the finish.
    private func runTurn(_ model: AppModel, chat: Int, turn: Int = 1, reply: String, seq: Int = 1) {
        model.apply(.turnStarted(TurnStarted(chat: chat, turn: turn, seq: seq)))
        model.apply(.userText(UserText(chat: chat, turn: turn, text: "Go on.", seq: seq + 1)))
        model.apply(.textDelta(TextDelta(chat: chat, turn: turn, text: reply, seq: seq + 2)))
        model.apply(.turnFinished(TurnFinished(chat: chat, turn: turn, outcome: .done, seq: seq + 3)))
    }

    func testTheReplyLineIsTheFirstLineOfTheLastTurnsReply() {
        let items: [TranscriptItem] = [
            .userText(UserText(chat: 5, turn: 1, text: "Start.")),
            .assistantText(id: "a1", text: "Older reply."),
            .userText(UserText(chat: 5, turn: 2, text: "Go on.")),
            .assistantText(id: "a2", text: "Looking."),
            .assistantText(id: "a3", text: "\n   The notes page is built.  \nIt saves per email."),
            .turnMarker(TurnMarker(turn: 2, outcome: .done)),
        ]
        XCTAssertEqual(DoneCard.replyLine(in: items), "The notes page is built.")
        XCTAssertNil(
            DoneCard.replyLine(in: Array(items.prefix(3))), "a turn with no reply of its own has no line, not an older one")
        XCTAssertNil(DoneCard.replyLine(in: []))
    }

    func testANewReplyRowAndItsOrder() throws {
        let now = try XCTUnwrap(SessionTime.parse("2026-11-02T14:05:00Z"))
        let chats = [Self.main(3), Self.thread(5, slot: 1, lastReply: "2026-11-02T14:00:00Z"), Self.thread(6, slot: 2, state: .working)]
        let rows = ThreadsPresentation(chats: chats, current: 3, newReplies: [5, 6]).rows(now: now)
        XCTAssertEqual(rows.map(\.chat), [5, 6], "a new reply does not reorder the rows")
        XCTAssertEqual(rows[0].status, .newReply)
        XCTAssertEqual(rows[0].spokenLabel, "Thread 1, new reply")
        XCTAssertEqual(rows[1].status, .working, "working again: the spinner, not the dot")
        let waiting = ThreadsPresentation(chats: chats, current: 3, waiting: [5], newReplies: [5]).rows(now: now)
        XCTAssertEqual(waiting.first { $0.chat == 5 }?.status, .needsYou, "Needs you wins over a new reply")
    }

    func testAThreadFinishingWhileYouAreInMainShowsADoneCard() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.open(chat: 3)
        let count = sent.frames.count
        runTurn(model, chat: 5, reply: "The notes page is built.\nIt saves per email.")

        XCTAssertEqual(model.doneCards(in: 3), [DoneCard(
            thread: 5, slot: 1, title: "Thread 1 is done", line: "The notes page is built.", goLabel: "Go to Thread 1",
            goHelp: "Control-1")])
        XCTAssertEqual(model.doneCards(in: 5), [], "only Main shows it")
        XCTAssertEqual(model.doneCards(in: 6), [])
        XCTAssertEqual(model.threads.rows(now: Date()).first { $0.chat == 5 }?.status, .newReply)
        // Never in Main's transcript, never sent.
        XCTAssertEqual(model.transcripts[3] ?? [], [])
        XCTAssertEqual(sent.frames.count, count)
    }

    func testOpeningTheThreadClearsTheCardAndTheDot() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 3)
        runTurn(model, chat: 5, reply: "Done.")
        XCTAssertEqual(model.doneCards(in: 3).count, 1)

        model.switchToConversation(slot: 1)
        model.switchToConversation(slot: 0)
        XCTAssertEqual(model.doneCards(in: 3), [])
        XCTAssertNotEqual(model.threads.rows(now: Date()).first { $0.chat == 5 }?.status, .newReply)
    }

    func testDismissClearsTheCardOnlyAndTheNextTurnShowsItAgain() throws {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 3)
        runTurn(model, chat: 5, reply: "Done.")
        model.dismissDone(try XCTUnwrap(model.doneCards(in: 3).first))
        XCTAssertEqual(model.doneCards(in: 3), [])
        XCTAssertEqual(model.threads.rows(now: Date()).first { $0.chat == 5 }?.status, .newReply, "the dot stays")

        runTurn(model, chat: 5, turn: 2, reply: "Done again.", seq: 5)
        XCTAssertEqual(model.doneCards(in: 3).map(\.line), ["Done again."])
    }

    func testATurnEndingInTheThreadOnScreenShowsNothing() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 5)
        runTurn(model, chat: 5, reply: "Done.")
        model.switchToConversation(slot: 0)
        XCTAssertEqual(model.doneCards(in: 3), [])
        XCTAssertNotEqual(model.threads.rows(now: Date()).first { $0.chat == 5 }?.status, .newReply)
    }

    func testACallingCardTakesPrecedenceOverADoneCard() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 3)
        runTurn(model, chat: 5, reply: "Done.")
        model.apply(.cardAsk(Self.question(chat: 5, id: "card-9")))
        XCTAssertEqual(model.callingCards(in: 3).map(\.thread), [5])
        XCTAssertEqual(model.doneCards(in: 3), [], "the question shows, not the done card")
    }

    func testAReplayedTurnIsNotADoneCard() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 3)
        model.apply(.chatHistory(ChatHistory(chat: 5, events: [
            .turnStarted(TurnStarted(chat: 5, turn: 1, seq: 1)),
            .textDelta(TextDelta(chat: 5, turn: 1, text: "Done before the restart.", seq: 2)),
            .turnFinished(TurnFinished(chat: 5, turn: 1, outcome: .done, seq: 3)),
        ], truncated: false)))
        XCTAssertEqual(model.doneCards(in: 3), [], "turns that ended before this run are not news")
    }

    func testMainFinishingIsNeverADoneCard() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 5)
        runTurn(model, chat: 3, reply: "Main's reply.")
        model.switchToConversation(slot: 0)
        XCTAssertEqual(model.doneCards(in: 3), [])
    }

    // MARK: - loading and switching

    func testAChatListNamingALiveThreadLoadsIt() {
        let (model, sent) = model(chats: [Self.main(3)])
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(4, slot: 2, ended: Self.created)])))
        let opens = sent.frames.compactMap { if case .chatOpen(let open) = $0 { open.chat } else { nil } }
        XCTAssertTrue(opens.contains(5))
        XCTAssertFalse(opens.contains(4), "a closed thread is History, not loaded")
        XCTAssertNil(model.selected)

        // Listed again: not opened twice.
        let before = opens.filter { $0 == 5 }.count
        model.apply(.chatList(ChatList(chats: [Self.main(3), Self.thread(5, slot: 1)])))
        let after = sent.frames.compactMap { if case .chatOpen(let open) = $0 { open.chat } else { nil } }.filter { $0 == 5 }.count
        XCTAssertEqual(before, after)
    }

    func testSwitchToConversationBySlot() {
        let (model, _) = model(chats: [Self.main(3), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])
        model.openDocumentView()
        model.switchToConversation(slot: 2)
        XCTAssertEqual(model.selected, 6)
        XCTAssertFalse(model.documentMode, "switching leaves the document view")
        model.switchToConversation(slot: 0)
        XCTAssertEqual(model.selected, 3)
        model.switchToConversation(slot: 1)
        XCTAssertEqual(model.selected, 5)
    }

    // MARK: - answers on the tool row

    func testToolFinishedAnswersLandOnTheRow() {
        let (model, _) = model(chats: [Self.main(3)])
        model.apply(.toolStarted(ToolStarted(
            chat: 3, turn: 1, toolUseId: "toolu_q", tool: "AskUserQuestion", summary: "Asking a question", input: [:], seq: 1)))
        model.apply(.toolFinished(ToolFinished(
            chat: 3, turn: 1, toolUseId: "toolu_q", ok: true, summary: "Answered",
            answers: ["Which tone for step 2?": .one("Plain"), "Which steps?": .many(["One", "Two"])], seq: 2)))
        guard case .tool(let row)? = model.transcripts[3]?.last else { return XCTFail("expected a tool row") }
        XCTAssertEqual(row.answers?["Which tone for step 2?"], .one("Plain"))
        XCTAssertEqual(row.answers?["Which steps?"]?.labels, ["One", "Two"])
    }
}
