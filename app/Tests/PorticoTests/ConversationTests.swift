import Foundation
import XCTest

@testable import Portico

/// What the conversation pane and input bar lean on in the model and in
/// their view-free helpers: sending text (with attachments), stopping a
/// turn, the draft attachments the Files pane and drag-and-drop feed, and
/// how a tool row presents a call. No window.
@MainActor
final class ConversationTests: XCTestCase {

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func summary(_ chat: Int, state: ChatStateWord = .idle) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-27T12:00:00Z")
    }

    private func hello(epoch: String) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: [], capabilities: [])
    }

    // MARK: - send and stop

    func testSendMessageEmitsMessageSendWithAttachmentsAndClearsDraft() {
        let (model, sent) = model()
        model.attach(["/tmp/demo/notes.md", "/tmp/demo/notes.md", "/tmp/demo/b.txt"], to: 1)
        XCTAssertEqual(model.draftAttachments[1], ["/tmp/demo/notes.md", "/tmp/demo/b.txt"], "attachments are de-duplicated, order kept")

        model.detach("/tmp/demo/b.txt", from: 1)
        model.sendMessage(chat: 1, text: "  Summarise the attached notes.\n")

        XCTAssertEqual(sent.frames.count, 1)
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(send.chat, 1)
        XCTAssertEqual(send.text, "Summarise the attached notes.")
        XCTAssertEqual(send.attachments, ["/tmp/demo/notes.md"])
        XCTAssertNotNil(send.id, "a send carries an id so a refusal can be correlated")
        XCTAssertEqual(model.draftAttachments[1] ?? [], [], "a send clears the chat's draft attachments")
    }

    func testSendMessageWithBlankTextSendsNothing() {
        let (model, sent) = model()
        model.sendMessage(chat: 1, text: "   \n")
        XCTAssertTrue(sent.frames.isEmpty)
    }

    func testActionTextIsSentAsMessageSend() {
        let (model, sent) = model()
        let action = Action(label: "Review", text: "/review")
        model.sendMessage(chat: 2, text: action.text)
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(send.text, "/review")
        XCTAssertEqual(send.attachments, [])
    }

    func testStopTurnEmitsTurnStop() {
        let (model, sent) = model()
        model.stopTurn(chat: 4)
        guard case .turnStop(let stop)? = sent.frames.first else { return XCTFail("expected turn.stop, got \(sent.frames)") }
        XCTAssertEqual(stop.chat, 4)
    }

    func testChatBusyFollowsTheStateWord() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1, state: .idle), summary(2, state: .working), summary(3, state: .waitingOnYou), summary(4, state: .stopped)])))
        XCTAssertFalse(model.isBusy(chat: 1))
        XCTAssertTrue(model.isBusy(chat: 2))
        XCTAssertTrue(model.isBusy(chat: 3))
        XCTAssertFalse(model.isBusy(chat: 4))
        XCTAssertFalse(model.isBusy(chat: 9), "an unknown chat is not busy")
    }

    // MARK: - the user bubble on a live send

    func testLiveSendShowsAUserBubbleWhenItsUserTextArrives() {
        let (model, sent) = model()
        model.sendMessage(chat: 1, text: "say hi")
        guard case .messageSend? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(model.transcripts[1] ?? [], [], "nothing is shown until the gateway accepts the send")

        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        XCTAssertEqual(model.transcripts[1] ?? [], [], "turn.started alone adds nothing; the gateway's user.text is the bubble")
        model.apply(.userText(UserText(chat: 1, turn: 1, text: "say hi\n\nAttached files:\n- /tmp/demo/a.md", seq: 2)))
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 3)))
        model.apply(.textDelta(TextDelta(chat: 1, turn: 1, text: "hi", seq: 4)))

        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 2, "the user bubble then the streamed reply; got \(items)")
        guard case .userText(let user)? = items.first else { return XCTFail("expected the user bubble first, got \(items)") }
        XCTAssertEqual(user.chat, 1)
        XCTAssertEqual(user.turn, 1, "the bubble carries the turn the gateway numbered")
        XCTAssertEqual(user.text, "say hi\n\nAttached files:\n- /tmp/demo/a.md", "the text as the engine received it")
        guard case .assistantText(_, let text)? = items.last else { return XCTFail("expected the reply last, got \(items)") }
        XCTAssertEqual(text, "hi")
        XCTAssertNil(model.pendingSends[1], "the send has been accepted")

        // A refusal arriving late for that send no longer puts the text back.
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "late", chat: 1, id: (sent.frames.first.flatMap { if case .messageSend(let m) = $0 { return m.id } else { return nil } }))))
        XCTAssertEqual(model.draft(for: 1), "")
    }

    func testSameLaunchReplayShowsThePersonsMessages() {
        // Quit the app mid-turn, reopen, pick the chat: the ring replay (seq'd
        // events, from the beginning) must read as a conversation, not a monologue.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertNil(open.since, "a fresh launch opens from the beginning")
        model.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                .chatState(ChatState(chat: 1, state: .idle, seq: 1)),
                .turnStarted(TurnStarted(chat: 1, turn: 1, seq: 2)),
                .userText(UserText(chat: 1, turn: 1, text: "write a summary", seq: 3)),
                .chatState(ChatState(chat: 1, state: .working, seq: 4)),
                .textDelta(TextDelta(chat: 1, turn: 1, text: "On it.", seq: 5)),
                .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 6)),
                .chatState(ChatState(chat: 1, state: .idle, seq: 7)),
            ],
            truncated: false, id: open.id)))
        model.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 7)))
        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 3, "user bubble, reply, turn marker; got \(items)")
        guard case .userText(let user)? = items.first else { return XCTFail("expected the user bubble first, got \(items)") }
        XCTAssertEqual(user.text, "write a summary")
        XCTAssertEqual(model.lastSeq[1], 7)
    }

    func testLiveSendBubbleArrivesThroughACatchUpReplay() {
        // The socket dropped right after the send; the same gateway's ring
        // replays the turn.started we missed and the bubble appears once.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        model.apply(.chatLive(ChatLive(chat: 1, seq: 0)))
        model.sendMessage(chat: 1, text: "say hi")

        model.apply(.hello(hello(epoch: "epoch-A")))
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        model.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                .turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)),
                .userText(UserText(chat: 1, turn: 1, text: "say hi", seq: 2)),
                .textDelta(TextDelta(chat: 1, turn: 1, text: "hi", seq: 3)),
            ],
            truncated: false, id: open.id)))
        let items = model.transcripts[1] ?? []
        guard case .userText(let user)? = items.first else { return XCTFail("expected the user bubble first, got \(items)") }
        XCTAssertEqual(user.text, "say hi")
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(model.pendingSends[1])
    }

    func testFullReplayAfterARestartDoesNotDuplicateTheBubble() {
        // The gateway restarted before answering: the in-flight send is gone,
        // and the replay from the beginning is the whole truth of the chat.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        model.sendMessage(chat: 1, text: "say hi")

        model.apply(.hello(hello(epoch: "epoch-B")))
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        model.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                .turnStarted(TurnStarted(chat: 1, turn: 1)),
                .userText(UserText(chat: 1, turn: 1, text: "say hi")),
                .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done)),
            ],
            truncated: false, id: open.id)))
        let bubbles = (model.transcripts[1] ?? []).filter { if case .userText = $0 { return true } else { return false } }
        XCTAssertEqual(bubbles.count, 1, "the replay's user.text is the bubble; got \(model.transcripts[1] ?? [])")
    }

    // MARK: - refused sends keep what was composed

    func testRefusedSendRestoresTheDraftTextAndAttachments() {
        let (model, sent) = model()
        model.setDraft("Summarise the attached notes.", for: 1)
        model.attach(["/tmp/demo/notes.md"], to: 1)
        model.sendMessage(chat: 1, text: model.draft(for: 1))
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(model.draft(for: 1), "", "the editor clears on send")
        XCTAssertEqual(model.draftAttachments[1] ?? [], [])

        model.apply(.error(ErrorMessage(
            code: "attachment.missing", message: "attachment does not exist: /tmp/demo/notes.md", chat: 1, id: send.id)))

        XCTAssertEqual(model.draft(for: 1), "Summarise the attached notes.", "a refusal gives the text back")
        XCTAssertEqual(model.draftAttachments[1], ["/tmp/demo/notes.md"], "and the chips")
        XCTAssertEqual(model.status[1], "attachment does not exist: /tmp/demo/notes.md")
        XCTAssertEqual(model.transcripts[1] ?? [], [], "nothing was sent, so nothing is shown")

        // The refused send is forgotten.
        XCTAssertNil(model.pendingSends[1])
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        XCTAssertEqual(model.transcripts[1] ?? [], [])
    }

    func testRefusedSendWithTextAlreadyRetypedKeepsBoth() {
        let (model, sent) = model()
        model.sendMessage(chat: 1, text: "first")
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send") }
        model.setDraft("second", for: 1)
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "a turn is already running in chat 1", chat: 1, id: send.id)))
        XCTAssertEqual(model.draft(for: 1), "first\nsecond")
    }

    func testAnErrorForAnotherRequestLeavesTheDraftAlone() {
        let (model, sent) = model()
        model.sendMessage(chat: 1, text: "say hi")
        guard case .messageSend? = sent.frames.first else { return XCTFail("expected message.send") }
        model.apply(.error(ErrorMessage(code: "chat.unknown", message: "no chat 7", chat: 1, id: "some-other-request")))
        XCTAssertEqual(model.draft(for: 1), "")
        XCTAssertNotNil(model.pendingSends[1], "the send is still in flight")
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        model.apply(.userText(UserText(chat: 1, turn: 1, text: "say hi", seq: 2)))
        guard case .userText(let user)? = (model.transcripts[1] ?? []).first else { return XCTFail("expected the bubble") }
        XCTAssertEqual(user.text, "say hi")
    }

    // MARK: - the draft text lives in the model

    func testDraftTextSurvivesSwitchingChats() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2)])))
        model.open(chat: 1)
        model.setDraft("half a thought", for: 1)
        model.open(chat: 2)
        XCTAssertEqual(model.draft(for: 2), "")
        model.open(chat: 1)
        XCTAssertEqual(model.draft(for: 1), "half a thought")
        model.remove(chat: 1)
        XCTAssertEqual(model.draft(for: 1), "", "a removed chat drops its draft")
    }

    // MARK: - tool row presentation

    func testToolRowPresentationIconAndPrettyInput() {
        let row = ToolRow(
            toolUseId: "tu-1", turn: 1, tool: "Read", summary: "/tmp/demo/a.md",
            input: ["file_path": .string("/tmp/demo/a.md"), "limit": .int(20)])
        let shown = ToolRowPresentation(row: row)
        XCTAssertEqual(shown.prettyInput, "{\n  \"file_path\" : \"/tmp/demo/a.md\",\n  \"limit\" : 20\n}")
        XCTAssertEqual(shown.stateText, "running")

        // Tool names are the agent's data, never the app's vocabulary (spec
        // section 3 anti-goal): every tool row wears the same icon.
        let generic = ToolRowPresentation.toolIcon
        XCTAssertEqual(shown.icon, generic)
        for name in ["Bash", "Write", "AskUserQuestion", "mcp__thing__do", "Mystery"] {
            XCTAssertEqual(ToolRowPresentation(row: ToolRow(toolUseId: "x", turn: 1, tool: name, summary: "", input: [:])).icon, generic, name)
        }

        var done = row
        done.finished = true
        done.ok = true
        done.result = "read 120 lines"
        XCTAssertEqual(ToolRowPresentation(row: done).stateText, "read 120 lines")

        var failed = row
        failed.finished = true
        failed.ok = false
        failed.result = "permission denied"
        XCTAssertEqual(ToolRowPresentation(row: failed).stateText, "failed: permission denied")
        XCTAssertEqual(ToolRowPresentation(row: ToolRow(toolUseId: "x", turn: 1, tool: "Bash", summary: "ls", input: [:])).prettyInput, "{\n\n}")
    }
}
