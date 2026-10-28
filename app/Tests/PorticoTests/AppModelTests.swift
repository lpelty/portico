import Foundation
import XCTest

@testable import Portico

/// `AppModel.apply`, the one reducer for gateway frames, and the sidebar's
/// view of a chat. Model-only: no socket, no window. Outbound frames are
/// captured through `model.outbound`.
@MainActor
final class AppModelTests: XCTestCase {

    // MARK: - helpers

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    /// Captures what the model asked to send, in order.
    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func hello(epoch: String = "epoch-A") -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: [], capabilities: [])
    }

    private func summary(_ chat: Int, state: ChatStateWord = .idle, alias: String? = nil) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: alias, state: state, created: "2026-10-27T12:00:00Z")
    }

    private func delta(_ chat: Int, turn: Int, _ text: String, seq: Int) -> ServerMessage {
        .textDelta(TextDelta(chat: chat, turn: turn, text: text, seq: seq))
    }

    // MARK: - Step 1 tests, as the plan names them

    func testApplyTextDeltasCoalesce() {
        let (model, _) = model()
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        model.apply(delta(1, turn: 1, "Hel", seq: 2))
        model.apply(delta(1, turn: 1, "lo, ", seq: 3))
        model.apply(delta(1, turn: 1, "world.", seq: 4))

        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 1, "consecutive deltas of one turn are one assistant item, got \(items)")
        guard case .assistantText(_, let text)? = items.first else { return XCTFail("expected assistantText, got \(items)") }
        XCTAssertEqual(text, "Hello, world.")

        // A tool row in between starts a new assistant item; the first keeps its text.
        model.apply(.toolStarted(ToolStarted(chat: 1, turn: 1, toolUseId: "t1", tool: "Read", summary: "/tmp/a", input: [:], seq: 5)))
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "t1", ok: true, summary: "12 lines", seq: 6)))
        model.apply(delta(1, turn: 1, "Done.", seq: 7))
        let after = model.transcripts[1] ?? []
        XCTAssertEqual(after.count, 3)
        guard case .assistantText(_, let tail)? = after.last else { return XCTFail("expected assistantText last, got \(after)") }
        XCTAssertEqual(tail, "Done.")

        // A new turn never coalesces into the previous turn's text.
        model.apply(.turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 8)))
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 2, seq: 9)))
        model.apply(delta(1, turn: 2, "Again.", seq: 10))
        let next = model.transcripts[1] ?? []
        guard case .assistantText(_, let fresh)? = next.last else { return XCTFail("expected assistantText last, got \(next)") }
        XCTAssertEqual(fresh, "Again.")
        XCTAssertEqual(model.lastSeq[1], 10)
    }

    func testApplyToolStartFinishPairs() {
        let (model, _) = model()
        model.apply(.turnStarted(TurnStarted(chat: 3, turn: 1, seq: 1)))
        model.apply(.toolStarted(ToolStarted(
            chat: 3, turn: 1, toolUseId: "tu-1", tool: "Write", summary: "/tmp/demo/a.md",
            input: ["file_path": .string("/tmp/demo/a.md")], seq: 2)))

        var rows = model.transcripts[3] ?? []
        XCTAssertEqual(rows.count, 1)
        guard case .tool(let started)? = rows.first else { return XCTFail("expected tool row, got \(rows)") }
        XCTAssertEqual(started.toolUseId, "tu-1")
        XCTAssertEqual(started.tool, "Write")
        XCTAssertEqual(started.summary, "/tmp/demo/a.md")
        XCTAssertFalse(started.finished)
        XCTAssertNil(started.ok)

        model.apply(.toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: "tu-1", ok: false, summary: "permission denied", seq: 3)))
        rows = model.transcripts[3] ?? []
        XCTAssertEqual(rows.count, 1, "a finish updates its row in place, it never adds one")
        guard case .tool(let finished)? = rows.first else { return XCTFail("expected tool row, got \(rows)") }
        XCTAssertTrue(finished.finished)
        XCTAssertEqual(finished.ok, false)
        XCTAssertEqual(finished.result, "permission denied")
        XCTAssertEqual(finished.summary, "/tmp/demo/a.md", "the start summary stays; the finish summary is the result")

        // A finish for a row we never saw (history fell off the ring) is shown, not dropped.
        model.apply(.toolFinished(ToolFinished(chat: 3, turn: 1, toolUseId: "tu-ghost", ok: true, summary: "ok", seq: 4)))
        rows = model.transcripts[3] ?? []
        XCTAssertEqual(rows.count, 2)
        guard case .tool(let ghost)? = rows.last else { return XCTFail("expected tool row, got \(rows)") }
        XCTAssertEqual(ghost.toolUseId, "tu-ghost")
        XCTAssertTrue(ghost.finished)
    }

    func testCardAskAppendsToOpenCardsAndTranscript() {
        let (model, _) = model()
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        let card = CardAsk(
            chat: 1, id: "card-7", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/demo/a.md", input: [:]),
            questions: nil, form: nil, seq: 2)
        model.apply(.cardAsk(card))
        model.apply(.chatState(ChatState(chat: 1, state: .waitingOnYou, seq: 3)))

        XCTAssertEqual(model.openCards[1]?.map(\.id), ["card-7"])
        let items = model.transcripts[1] ?? []
        guard case .card(let shown)? = items.last else { return XCTFail("expected card item, got \(items)") }
        XCTAssertEqual(shown.id, "card-7")

        // The same card re-sent on chat.open (same id, same seq) is not added twice.
        model.apply(.cardAsk(card))
        XCTAssertEqual(model.openCards[1]?.count, 1)
        XCTAssertEqual((model.transcripts[1] ?? []).count, 1, "turn.started adds no item; the card is the only one")

        // card.cancel closes it: gone from open cards, still in the transcript.
        model.apply(.cardCancel(CardCancel(chat: 1, id: "card-7", reason: "turn stopped", seq: 4)))
        XCTAssertEqual(model.openCards[1] ?? [], [])
        XCTAssertEqual((model.transcripts[1] ?? []).count, 1, "turn.started adds no item; the card is the only one")
        XCTAssertEqual(model.closedCards[1]?["card-7"], "turn stopped")
    }

    func testCardCancelRemovesPinned() {
        let (model, sent) = model()
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        let card = CardAsk(
            chat: 1, id: "card-9", kind: .permission, title: "Run a command",
            permission: Permission(tool: "Bash", summary: "ls", input: ["command": .string("ls")]),
            questions: nil, form: nil, seq: 2)
        model.apply(.cardAsk(card))
        model.apply(.chatState(ChatState(chat: 1, state: .waitingOnYou, seq: 3)))

        // While open the card is pinned above the input and inline in the transcript.
        XCTAssertEqual(model.pinnedCards(for: 1).map(\.id), ["card-9"])
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-9"), .open)
        XCTAssertEqual((model.transcripts[1] ?? []).last, .card(card))

        // card.cancel: the pinned copy goes; the inline one stays, marked cancelled with the reason.
        model.apply(.cardCancel(CardCancel(chat: 1, id: "card-9", reason: "turn stopped", seq: 4)))
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertEqual((model.transcripts[1] ?? []).last, .card(card), "the inline card is not removed")
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-9"), .cancelled("turn stopped"))
        XCTAssertEqual(CardStatusPresentation(status: model.cardStatus(chat: 1, id: "card-9")).label, "cancelled: turn stopped")

        // A cancel without a reason, or for a card never seen, is harmless.
        model.apply(.cardCancel(CardCancel(chat: 1, id: "card-9", reason: nil, seq: 5)))
        model.apply(.cardCancel(CardCancel(chat: 1, id: "ghost", reason: nil, seq: 6)))
        XCTAssertEqual(model.cardStatus(chat: 1, id: "ghost"), .cancelled("cancelled"))
        XCTAssertEqual(model.pinnedCards(for: 1), [])

        // Answering a cancelled card sends nothing: there is no open card to answer.
        model.answerCard(CardAnswer(chat: 1, id: "card-9", answer: ["decision": .string("allow")], scope: .once))
        XCTAssertFalse(sent.frames.contains { if case .cardAnswer = $0 { return true } else { return false } })
    }

    func testAnswerCardSendsCardAnswerAndUnpins() {
        let (model, sent) = model()
        let card = CardAsk(
            chat: 2, id: "card-3", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/demo/a.md", input: [:]),
            questions: nil, form: nil, seq: 1)
        model.apply(.cardAsk(card))
        XCTAssertEqual(model.pinnedCards(for: 2).map(\.id), ["card-3"])

        model.answerCard(CardAnswer(chat: 2, id: "card-3", answer: ["decision": .string("allow")], scope: .chat, note: "fine here"))
        guard case .cardAnswer(let sentAnswer)? = sent.frames.last else { return XCTFail("expected card.answer, got \(sent.frames)") }
        XCTAssertEqual(sentAnswer.chat, 2)
        XCTAssertEqual(sentAnswer.id, "card-3")
        XCTAssertEqual(sentAnswer.answer, ["decision": .string("allow")])
        XCTAssertEqual(sentAnswer.scope, .chat)
        XCTAssertEqual(sentAnswer.note, "fine here")

        XCTAssertEqual(model.pinnedCards(for: 2), [], "an answered card is no longer pinned")
        XCTAssertEqual(model.cardStatus(chat: 2, id: "card-3"), .answered)
        XCTAssertEqual(CardStatusPresentation(status: .answered).label, "answered")
        XCTAssertEqual((model.transcripts[2] ?? []).count, 1, "the inline copy stays")

        // A second answer for the same card is a stale one: nothing is sent.
        let before = sent.frames.count
        model.answerCard(CardAnswer(chat: 2, id: "card-3", answer: ["decision": .string("deny")]))
        XCTAssertEqual(sent.frames.count, before)

        // The same card re-sent later (a chat.open replay of a card the gateway still
        // holds) does not come back as open: the app already answered it.
        model.apply(.cardAsk(card))
        XCTAssertEqual(model.pinnedCards(for: 2), [])
    }

    func testAnsweredCardIsNotReopenedByARelaunchReplay() {
        // Run 1: a card is asked and answered; the gateway stamps card.answered.
        let (first, _) = model()
        first.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = first.handleHello(hello(epoch: "epoch-A"))
        first.open(chat: 1)
        first.apply(.chatLive(ChatLive(chat: 1, seq: 0)))
        let card = CardAsk(
            chat: 1, id: "card-1", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/demo/a.md", input: [:]),
            questions: nil, form: nil, seq: 2)
        first.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        first.apply(.cardAsk(card))
        first.answerCard(CardAnswer(chat: 1, id: "card-1", answer: ["decision": .string("allow")], scope: .once))
        first.apply(.cardAnswered(CardAnswered(chat: 1, id: "card-1", seq: 3)))
        first.apply(.turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 4)))
        XCTAssertEqual(first.pinnedCards(for: 1), [])
        XCTAssertEqual(first.cardStatus(chat: 1, id: "card-1"), .answered)

        // Run 2: a fresh app on the same gateway opens from the beginning and
        // gets the ring back, the card and its closing included.
        let (second, sent) = model()
        second.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = second.handleHello(hello(epoch: "epoch-A"))
        second.open(chat: 1)
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertNil(open.since)
        second.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                .turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)),
                .cardAsk(card),
                .cardAnswered(CardAnswered(chat: 1, id: "card-1", seq: 3)),
                .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 4)),
            ],
            truncated: false, id: open.id)))
        second.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 4)))

        XCTAssertEqual(second.pinnedCards(for: 1), [], "an answered card does not come back as open after a relaunch")
        XCTAssertEqual(second.cardStatus(chat: 1, id: "card-1"), .answered)
        XCTAssertEqual((second.transcripts[1] ?? []).filter { if case .card = $0 { return true } else { return false } }.count, 1, "the inline copy is still there")
        // Answering it sends nothing: there is no open card to answer.
        let before = sent.frames.count
        second.answerCard(CardAnswer(chat: 1, id: "card-1", answer: ["decision": .string("allow")]))
        XCTAssertEqual(sent.frames.count, before)
    }

    func testHistoryThenLiveReplacesTranscript() {
        let (model, sent) = model()
        // Before a restart the app held a live transcript for chat 1.
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        model.apply(delta(1, turn: 1, "stale", seq: 2))
        XCTAssertEqual((model.transcripts[1] ?? []).count, 1)

        // The gateway restarted: a new epoch re-opens from the beginning ...
        model.apply(.hello(hello(epoch: "epoch-B")))
        XCTAssertEqual(sent.types().last, "chat.open")
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertNil(open.since)

        // ... and the transcript replay (no seq) replaces what was shown.
        let replay: [ServerMessage] = [
            .turnStarted(TurnStarted(chat: 1, turn: 1)),
            .userText(UserText(chat: 1, turn: 1, text: "write a summary")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "On ")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "it.")),
            .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done)),
        ]
        model.apply(.chatHistory(ChatHistory(chat: 1, events: replay, truncated: false, id: open.id)))
        model.apply(.artifactCreated(ArtifactCreated(
            chat: 1,
            artifact: Artifact(id: "a-1", kind: .file, location: "/tmp/demo/summary.md", media: .markdown,
                               title: "summary.md", source: .tool, open: false))))
        model.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 0)))

        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 3, "user text, one coalesced assistant item, one turn marker; got \(items)")
        guard case .userText(let user)? = items.first else { return XCTFail("expected userText first, got \(items)") }
        XCTAssertEqual(user.text, "write a summary")
        guard case .assistantText(_, let text)? = items.dropFirst().first else { return XCTFail("expected assistantText, got \(items)") }
        XCTAssertEqual(text, "On it.")
        guard case .turnMarker(let marker)? = items.last else { return XCTFail("expected turnMarker last, got \(items)") }
        XCTAssertEqual(marker.outcome, .done)
        XCTAssertEqual(model.artifacts[1]?.map(\.id), ["a-1"])
        XCTAssertTrue(model.isLive(chat: 1))

        // Live events after chat.live append; transcript turns numbered on, seq from the new gateway.
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 2, seq: 1)))
        model.apply(delta(1, turn: 2, "fresh", seq: 2))
        XCTAssertEqual((model.transcripts[1] ?? []).count, 4)
        XCTAssertEqual(model.lastSeq[1], 2)
    }

    func testHistorySinceAppendsInsteadOfReplacing() {
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        model.apply(delta(1, turn: 1, "kept ", seq: 2))

        // Same gateway after a socket drop: open with since=2, the ring sends only what we missed.
        model.apply(.hello(hello(epoch: "epoch-A")))
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertEqual(open.since, 2)
        model.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                delta(1, turn: 1, "kept ", seq: 2),  // a duplicate of what we already saw is ignored
                delta(1, turn: 1, "and more", seq: 3),
                .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 4)),
            ],
            truncated: false, id: open.id)))
        model.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 4)))

        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 2, "got \(items)")
        guard case .assistantText(_, let text)? = items.first else { return XCTFail("expected assistantText, got \(items)") }
        XCTAssertEqual(text, "kept and more")
        XCTAssertEqual(model.lastSeq[1], 4)
    }

    func testTruncatedHistoryRefetchesFromTheBeginning() {
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello())
        model.open(chat: 1)
        model.apply(delta(1, turn: 1, "x", seq: 50))
        model.apply(.hello(hello()))
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertEqual(open.since, 50)

        let before = sent.frames.count
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [], truncated: true, id: open.id)))
        XCTAssertEqual(sent.frames.count, before + 1, "a truncated history is answered with one fresh chat.open")
        guard case .chatOpen(let again)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertEqual(again.chat, 1)
        XCTAssertNil(again.since, "the refetch starts from the beginning")
    }

    func testChatStateWordShown() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2, alias: "notes")])))
        XCTAssertEqual(model.chats.map(\.chat), [1, 2])

        let idle = ChatRow(summary: model.chats[0])
        XCTAssertEqual(idle.number, "#1")
        XCTAssertNil(idle.alias)
        XCTAssertEqual(idle.stateWord, "idle")

        model.apply(.chatState(ChatState(chat: 2, state: .waitingOnYou, seq: 7)))
        let waiting = ChatRow(summary: model.chats[1])
        XCTAssertEqual(waiting.number, "#2")
        XCTAssertEqual(waiting.alias, "notes")
        XCTAssertEqual(waiting.stateWord, "waiting on you", "the state is shown in exactly the protocol's words")

        for (state, word) in [(ChatStateWord.working, "working"), (.stopped, "stopped"), (.idle, "idle")] {
            model.apply(.chatState(ChatState(chat: 1, state: state, seq: 8)))
            XCTAssertEqual(ChatRow(summary: model.chats[0]).stateWord, word)
        }

        // The list is the gateway's: a chat.list without chat 2 drops it and clears the selection.
        model.selected = 2
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        XCTAssertEqual(model.chats.map(\.chat), [1])
        XCTAssertNil(model.selected)
    }

    // MARK: - sidebar actions

    func testNewChatSendsAndSelectsTheReply() {
        let (model, sent) = model()
        model.newChat(folder: URL(fileURLWithPath: "/tmp/demo"))
        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new, got \(sent.frames)") }
        XCTAssertEqual(new.folder, "/tmp/demo")
        let id = try! XCTUnwrap(new.id, "chat.new carries an id so the reply can be matched")

        // The gateway answers chat.state with that id, then chat.list.
        model.apply(.chatState(ChatState(chat: 4, state: .idle, id: id, seq: 1)))
        model.apply(.chatList(ChatList(chats: [summary(4)])))
        XCTAssertEqual(model.selected, 4)
        XCTAssertEqual(sent.types().last, "chat.open", "the new chat is opened so its events stream")
    }

    func testStopRemoveAliasSendTheRightFrames() {
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2)])))
        model.open(chat: 2)
        model.apply(delta(2, turn: 1, "x", seq: 1))

        model.stop(chat: 2)
        guard case .chatStop(let stop)? = sent.frames.last else { return XCTFail("expected chat.stop") }
        XCTAssertEqual(stop.chat, 2)

        model.alias(chat: 2, "notes")
        guard case .chatAlias(let alias)? = sent.frames.last else { return XCTFail("expected chat.alias") }
        XCTAssertEqual(alias.alias, "notes")
        model.alias(chat: 2, "")
        guard case .chatAlias(let cleared)? = sent.frames.last else { return XCTFail("expected chat.alias") }
        XCTAssertNil(cleared.alias, "an empty alias clears it")

        model.remove(chat: 2)
        guard case .chatRemove(let remove)? = sent.frames.last else { return XCTFail("expected chat.remove") }
        XCTAssertEqual(remove.chat, 2)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.transcripts[2])
        XCTAssertNil(model.lastSeq[2])
    }

    func testStatusAndErrorsLand() {
        let (model, _) = model()
        model.apply(.statusSet(StatusSet(text: "checking memory services")))
        XCTAssertEqual(model.gatewayStatus, "checking memory services")
        model.apply(.statusSet(StatusSet(text: "thinking", chat: 1, seq: 3)))
        XCTAssertEqual(model.status[1], "thinking")
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "a turn is running", chat: 1, id: "r1")))
        XCTAssertEqual(model.lastError?.code, "chat.busy")
        XCTAssertEqual(model.status[1], "a turn is running")
    }

    // MARK: - Settings

    func testSettingsDefaultsAndPersistence() throws {
        let suite = "portico-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.autoOpen)
        XCTAssertEqual(settings.autoOpenKinds, Settings.viewableKinds)
        XCTAssertEqual(settings.quitBehaviour, .keepRunning)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertNil(settings.gatewayURL)

        settings.autoOpen = false
        settings.autoOpenKinds = ["markdown"]
        settings.quitBehaviour = .stopEverything
        settings.appearance = .dark
        settings.gatewayURL = "ws://127.0.0.1:4321"

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.autoOpen)
        XCTAssertEqual(reloaded.autoOpenKinds, ["markdown"])
        XCTAssertEqual(reloaded.quitBehaviour, .stopEverything)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.gatewayURL, "ws://127.0.0.1:4321")
    }

    // MARK: - Files pane (Task 20)

    func testOpenFileFromTreeShowsInViewer() {
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        sent.frames.removeAll()

        // A click in the Files pane: a local artifact, in the viewer at once.
        model.openArtifact(file: "/tmp/demo/notes/report.md", in: 1)
        let shown = model.current[1]
        XCTAssertEqual(shown?.location, "/tmp/demo/notes/report.md")
        XCTAssertEqual(shown?.media, .markdown)
        XCTAssertEqual(shown?.kind, .file)
        XCTAssertEqual(shown?.source, .text)
        XCTAssertEqual(shown?.title, "report.md")
        XCTAssertTrue(model.isViewerShown(for: 1), "the viewer column is there for a file opened from the tree")
        XCTAssertEqual(model.artifacts[1]?.map(\.location), ["/tmp/demo/notes/report.md"], "listed in the history too")
        XCTAssertTrue(sent.frames.isEmpty, "no gateway round trip for a local open, got \(sent.types())")

        // Media follows the extension the way the gateway maps it; unknown is `other`.
        model.openArtifact(file: "/tmp/demo/shot.PNG", in: 1)
        XCTAssertEqual(model.current[1]?.media, .image)
        model.openArtifact(file: "/tmp/demo/data.csv", in: 1)
        XCTAssertEqual(model.current[1]?.media, .other)
        model.openArtifact(file: "/tmp/demo/readme.txt", in: 1)
        XCTAssertEqual(model.current[1]?.media, .text)

        // Opening the same file again does not duplicate it in the history.
        model.openArtifact(file: "/tmp/demo/notes/report.md", in: 1)
        XCTAssertEqual(model.artifacts[1]?.filter { $0.location == "/tmp/demo/notes/report.md" }.count, 1)
        XCTAssertEqual(model.current[1]?.location, "/tmp/demo/notes/report.md")

        // A replay from the beginning keeps what the person opened locally:
        // the gateway never lists it, so it must not vanish on reattach.
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [], truncated: false)))
        XCTAssertEqual(model.current[1]?.location, "/tmp/demo/notes/report.md")
        XCTAssertEqual(model.artifacts[1]?.count, 4)
    }

    func testFilesListRequestsAndRepliesFillTheTree() {
        let (model, sent) = model()
        var hello = hello()
        hello.roots = [Root(name: "projects", path: "/Users/someone/projects")]
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        sent.frames.removeAll()

        // The chat's folder is root "chat"; config roots come from hello.
        XCTAssertEqual(model.fileRoots(for: 1).map(\.name), ["chat", "projects"])
        XCTAssertEqual(model.rootPath(root: "chat", chat: 1), "/tmp/demo")
        XCTAssertEqual(model.rootPath(root: "projects", chat: 1), "/Users/someone/projects")
        XCTAssertNil(model.rootPath(root: "nope", chat: 1))

        // Nothing listed yet; asking sends one files.list and marks it pending.
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: ""))
        model.listFiles(chat: 1, root: "chat", path: "")
        model.listFiles(chat: 1, root: "chat", path: "")
        XCTAssertEqual(sent.types(), ["files.list"], "one request per directory while it is pending")
        guard case .filesList(let request)? = sent.frames.first else { return XCTFail("expected files.list, got \(sent.frames)") }
        XCTAssertEqual(request.chat, 1)
        XCTAssertEqual(request.root, "chat")
        XCTAssertEqual(request.path, "")

        // The reply is keyed by chat, root and the gateway's normalised path.
        let entries = [Entry(name: "src", dir: true, size: nil), Entry(name: "main.py", dir: false, size: 1204)]
        model.apply(.filesList(FilesList(root: "chat", path: "", entries: entries, chat: 1, id: request.id)))
        XCTAssertEqual(model.fileEntries(chat: 1, root: "chat", path: ""), entries)
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: "src"), "a child is fetched on its own expand")
        XCTAssertNil(model.fileEntries(chat: 2, root: "chat", path: ""), "another chat's folder is another tree")

        // A child path is joined with `/`, matching the gateway's posix form.
        model.listFiles(chat: 1, root: "chat", path: "src")
        guard case .filesList(let child)? = sent.frames.last else { return XCTFail("expected files.list, got \(sent.frames)") }
        XCTAssertEqual(child.path, "src")
        XCTAssertEqual(model.absolutePath(chat: 1, root: "chat", path: "src", name: "lib"), "/tmp/demo/src/lib")
        XCTAssertEqual(model.absolutePath(chat: 1, root: "projects", path: "", name: "demo"), "/Users/someone/projects/demo")

        // Refresh drops the cache so the next expand asks again.
        model.refreshFiles(chat: 1)
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: ""))
        model.listFiles(chat: 1, root: "chat", path: "")
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 3)
    }

    // MARK: - Status strip, settings and quit (Task 21)

    func testStatusStripTextComposition() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2, state: .working, alias: "notes")])))

        // Nothing selected, no gateway: the strip still says where things stand.
        XCTAssertEqual(model.statusStrip(gateway: .stopped).text, "no chat · gateway stopped")

        // A selected chat: its state word, its folder's name, the gateway with its port.
        model.selected = 2
        model.setConnection(.connected)
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).text, "working · demo · gateway running :4321")

        // The chat's last status.set line comes last, verbatim.
        model.apply(.statusSet(StatusSet(text: "thinking", chat: 2, seq: 3)))
        XCTAssertEqual(
            model.statusStrip(gateway: .running(port: 4321)).text,
            "working · demo · gateway running :4321 · thinking")

        // A later chat-less status.set (a lifecycle command's output line) replaces it: the newest line shows.
        model.apply(.statusSet(StatusSet(text: "checking memory services")))
        XCTAssertEqual(
            model.statusStrip(gateway: .running(port: 4321)).text,
            "working · demo · gateway running :4321 · checking memory services")
        model.apply(.statusSet(StatusSet(text: "still thinking", chat: 2, seq: 4)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).statusText, "still thinking")

        // The state word follows chat.state, in exactly the protocol's words.
        model.apply(.chatState(ChatState(chat: 2, state: .waitingOnYou, seq: 5)))
        XCTAssertTrue(model.statusStrip(gateway: .running(port: 4321)).text.hasPrefix("waiting on you · demo · "))

        // The gateway indicator: stopped / starting / running :port / failed.
        XCTAssertEqual(model.statusStrip(gateway: .starting).gatewayText, "gateway starting")
        XCTAssertEqual(model.statusStrip(gateway: .stopped).gatewayText, "gateway stopped")
        XCTAssertEqual(model.statusStrip(gateway: .failed("no gateway command found")).gatewayText,
                       "gateway failed: no gateway command found")

        // The socket's state is only mentioned when it is not simply connected.
        XCTAssertNil(model.statusStrip(gateway: .running(port: 4321)).connectionText)
        model.setConnection(.connecting)
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).connectionText, "connecting")
        XCTAssertEqual(
            model.statusStrip(gateway: .running(port: 4321)).text,
            "waiting on you · demo · gateway running :4321 · connecting · still thinking")
        model.setConnection(.disconnected)
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).connectionText, "not connected")
        XCTAssertNil(model.statusStrip(gateway: .stopped).connectionText, "a stopped gateway already says why there is no socket")
        model.setConnection(.failed("connection refused"))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).connectionText,
                       "cannot reach the gateway: connection refused")
        // ... but not twice when the gateway itself failed with the same reason.
        model.setConnection(.failed("no gateway command found"))
        XCTAssertNil(model.statusStrip(gateway: .failed("no gateway command found")).connectionText)
    }

    func testStopGatewaySendsGatewayStopAndWaitsForTheSocketToClose() async {
        let (model, sent) = model()
        model.setConnection(.connected)
        XCTAssertTrue(model.autoStartGateway)

        // The socket closes a moment after the gateway is asked to stop.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            model.setConnection(.disconnected)
        }
        let closed = await model.stopGateway(timeout: .seconds(5))
        XCTAssertTrue(closed, "stopGateway returns once the socket is gone")
        XCTAssertEqual(sent.types(), ["gateway.stop"])
        XCTAssertFalse(model.autoStartGateway, "after an explicit stop the app does not start a gateway on its own")

        // Start puts the automatic policy back.
        model.startGateway()
        XCTAssertTrue(model.autoStartGateway)
    }

    func testStopGatewayGivesUpWhenTheSocketStaysOpen() async {
        let (model, sent) = model()
        model.setConnection(.connected)
        let closed = await model.stopGateway(timeout: .milliseconds(200))
        XCTAssertFalse(closed, "a gateway that never closes the socket does not hold the app forever")
        XCTAssertEqual(sent.types(), ["gateway.stop"])
    }

    func testQuitBehaviourDecidesWhetherTheGatewayIsStopped() async {
        let (model, sent) = model()
        model.setConnection(.connected)

        // Keep the agent running (the default): quitting only detaches, nothing is sent.
        await model.prepareToQuit(behaviour: .keepRunning, timeout: .seconds(1))
        XCTAssertTrue(sent.frames.isEmpty, "keep running sends nothing, got \(sent.types())")

        // Stop everything: gateway.stop goes out and the app waits for the socket.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            model.setConnection(.disconnected)
        }
        await model.prepareToQuit(behaviour: .stopEverything, timeout: .seconds(5))
        XCTAssertEqual(sent.types(), ["gateway.stop"])

        // Not connected at all: nothing to stop, nothing sent, no waiting.
        sent.frames.removeAll()
        await model.prepareToQuit(behaviour: .stopEverything, timeout: .seconds(1))
        XCTAssertTrue(sent.frames.isEmpty)
    }

    func testSupervisorTokenFileOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-task21-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let override = dir.appendingPathComponent("elsewhere.token")
        try "  secret-token\n".write(to: override, atomically: true, encoding: .utf8)

        let supervisor = GatewaySupervisor(stateDir: dir)
        XCTAssertNil(supervisor.readToken(), "no token in the state dir")
        supervisor.tokenOverride = override
        XCTAssertEqual(supervisor.tokenURL, override)
        XCTAssertEqual(supervisor.readToken(), "secret-token")
        supervisor.tokenOverride = nil
        XCTAssertEqual(supervisor.tokenURL, dir.appendingPathComponent("token"))
    }

    func testDoctorRunnerCapturesLinesAndExitCode() {
        let lines = GatewaySupervisor.runCapturing(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo ok: python; echo FAIL: a provider credential >&2; exit 3"],
            environment: [:])
        XCTAssertEqual(lines, ["ok: python", "FAIL: a provider credential", "doctor exited with code 3"])
        XCTAssertEqual(
            GatewaySupervisor.runCapturing(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'one\\ntwo\\n\\n'"], environment: [:]),
            ["one", "two"], "trailing blank lines are dropped; a clean exit adds nothing")
        XCTAssertEqual(
            GatewaySupervisor.runCapturing(URL(fileURLWithPath: "/nonexistent/doctor"), [], environment: [:]).count, 1,
            "a doctor that cannot run is one line, not a crash")
    }
}
