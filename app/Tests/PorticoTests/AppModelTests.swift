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
}
