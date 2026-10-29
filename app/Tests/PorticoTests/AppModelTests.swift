import AppKit
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
        // A question card keeps its inline record (a permission card does
        // not: PermissionUnitTests).
        let card = CardAsk(
            chat: 1, id: "card-7", kind: .question, title: "File",
            permission: nil, questions: [Question(question: "Which file?", header: "File", options: [Option(label: "a.md", description: "")], multiSelect: false)], form: nil, seq: 2)
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
            chat: 1, id: "card-9", kind: .question, title: "File",
            permission: nil, questions: [Question(question: "Which file?", header: "File", options: [Option(label: "a.md", description: "")], multiSelect: false)], form: nil, seq: 2)
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
        XCTAssertEqual((model.transcripts[2] ?? []).count, 0, "a permission card leaves no copy of its own (V1)")

        // A second answer for the same card is a stale one: nothing is sent.
        let before = sent.frames.count
        model.answerCard(CardAnswer(chat: 2, id: "card-3", answer: ["decision": .string("deny")]))
        XCTAssertEqual(sent.frames.count, before)

        // The gateway confirms: the card stays closed, and the inline copy is still one.
        model.apply(.cardAnswered(CardAnswered(chat: 2, id: "card-3", seq: 2)))
        XCTAssertEqual(model.pinnedCards(for: 2), [])
        XCTAssertEqual(model.cardStatus(chat: 2, id: "card-3"), .answered)
        XCTAssertEqual((model.transcripts[2] ?? []).count, 0)
    }

    func testCardReSentAfterAnUnconfirmedAnswerIsOpenAgain() {
        // The person answers; the frame never reaches the gateway (the socket
        // was already dead). The gateway still holds the card open, so on the
        // reattach it re-sends it after chat.live. The app must not hide it
        // behind its own "answered" mark: nothing was answered, and with no
        // card to answer the chat would sit at "waiting on you" until the
        // gateway restarts.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello(epoch: "epoch-A"))
        model.open(chat: 1)
        model.apply(.chatLive(ChatLive(chat: 1, seq: 0)))
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1)))
        let card = CardAsk(
            chat: 1, id: "card-1", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/demo/a.md", input: [:]),
            questions: nil, form: nil, seq: 2)
        model.apply(.cardAsk(card))
        model.apply(.chatState(ChatState(chat: 1, state: .waitingOnYou, seq: 3)))
        model.answerCard(CardAnswer(chat: 1, id: "card-1", answer: ["decision": .string("allow")], scope: .once))
        XCTAssertEqual(sent.types().last, "card.answer")
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-1"), .answered)

        // The socket drops and comes back to the same gateway: chat.open
        // with our watermark, an empty catch-up, chat.live, then the open
        // card again exactly as first sent.
        model.apply(.hello(hello(epoch: "epoch-A")))
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open, got \(sent.types())") }
        XCTAssertEqual(open.since, 3)
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [], truncated: false, id: open.id)))
        model.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 3)))
        model.apply(.cardAsk(card))

        XCTAssertEqual(model.pinnedCards(for: 1).map(\.id), ["card-1"], "the card the gateway still holds is open again")
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-1"), .open)
        let inline = (model.transcripts[1] ?? []).filter { if case .card = $0 { return true } else { return false } }
        XCTAssertEqual(inline.count, 0, "a permission card has no inline copy to duplicate")

        // The person answers again; this time the gateway confirms and the card closes for good.
        let before = sent.frames.count
        model.answerCard(CardAnswer(chat: 1, id: "card-1", answer: ["decision": .string("allow")], scope: .once))
        XCTAssertEqual(sent.frames.count, before + 1)
        XCTAssertEqual(sent.types().last, "card.answer")
        model.apply(.cardAnswered(CardAnswered(chat: 1, id: "card-1", seq: 4)))
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-1"), .answered)

        // A card the gateway cancelled stays cancelled if its ask ever comes
        // back: the cancel was the gateway's word, not this app's guess.
        let other = CardAsk(
            chat: 1, id: "card-2", kind: .permission, title: "Run a command",
            permission: Permission(tool: "Bash", summary: "ls", input: [:]),
            questions: nil, form: nil, seq: 5)
        model.apply(.cardAsk(other))
        model.apply(.cardCancel(CardCancel(chat: 1, id: "card-2", reason: "turn stopped", seq: 6)))
        model.apply(.cardAsk(other))
        XCTAssertEqual(model.pinnedCards(for: 1), [])
        XCTAssertEqual(model.cardStatus(chat: 1, id: "card-2"), .cancelled("turn stopped"))
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
        XCTAssertEqual((second.transcripts[1] ?? []).filter { if case .card = $0 { return true } else { return false } }.count, 0, "a permission card leaves no record of its own")
        // Answering it sends nothing: there is no open card to answer.
        let before = sent.frames.count
        second.answerCard(CardAnswer(chat: 1, id: "card-1", answer: ["decision": .string("allow")]))
        XCTAssertEqual(sent.frames.count, before)
    }

    func testFirstOpenOfAChatHeardOnlyThroughBroadcastsAsksFromTheBeginning() {
        // Chat 2 is working; the gateway sends its frames to the attached app
        // although this app never opened it. The first open must still ask
        // from the beginning: a watermark from broadcasts alone names a point
        // mid-turn, and `since` would make the gateway replay only the tail.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2, state: .working)])))
        _ = model.handleHello(hello())
        model.apply(.chatState(ChatState(chat: 2, state: .working, seq: 40)))
        model.apply(delta(2, turn: 3, "…and so the answer is", seq: 41))

        model.open(chat: 2)
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open, got \(sent.frames)") }
        XCTAssertEqual(open.chat, 2)
        XCTAssertNil(open.since, "a chat never opened in this run is asked for from the beginning")

        // The replay from the beginning is the whole conversation, not the tail.
        model.apply(.chatHistory(ChatHistory(
            chat: 2,
            events: [
                .turnStarted(TurnStarted(chat: 2, turn: 3, seq: 38)),
                .userText(UserText(chat: 2, turn: 3, text: "what is the answer?", seq: 39)),
                .chatState(ChatState(chat: 2, state: .working, seq: 40)),
                delta(2, turn: 3, "…and so the answer is", seq: 41),
            ],
            truncated: false, id: open.id)))
        model.apply(.chatLive(ChatLive(chat: 2, id: open.id, seq: 41)))
        let items = model.transcripts[2] ?? []
        guard case .userText(let user)? = items.first else { return XCTFail("expected the user bubble first, got \(items)") }
        XCTAssertEqual(user.text, "what is the answer?")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(model.lastSeq[2], 41)

        // Opened once, the chat catches up from its watermark: a later open
        // and a same-epoch reattach both carry `since`.
        model.apply(delta(2, turn: 3, " forty-two.", seq: 42))
        model.open(chat: 2)
        guard case .chatOpen(let again)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertEqual(again.since, 42)
        let reattach = model.handleHello(hello())
        guard case .chatOpen(let reopened)? = reattach.first(where: { if case .chatOpen(let o) = $0 { return o.chat == 2 } else { return false } }) else {
            return XCTFail("expected chat 2 re-opened on reattach, got \(reattach)")
        }
        XCTAssertEqual(reopened.since, 42)
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

    func testTruncatedReplyToAnOpenFromTheBeginningIsAppliedNotReopened() {
        // The gateway's ring has wrapped and there is no transcript: a replay
        // from the beginning is the best there is. Asking again would only
        // get the same answer, so the events are shown and no chat.open follows.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        _ = model.handleHello(hello())
        model.open(chat: 1)
        guard case .chatOpen(let open)? = sent.frames.last else { return XCTFail("expected chat.open") }
        XCTAssertNil(open.since)

        let before = sent.frames.count
        model.apply(.chatHistory(ChatHistory(
            chat: 1,
            events: [
                delta(1, turn: 1, "tail of the ring", seq: 40),
                .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 41)),
            ],
            truncated: true, id: open.id)))
        XCTAssertEqual(sent.frames.count, before, "no second chat.open for a truncated reply to an open from the beginning")
        let items = model.transcripts[1] ?? []
        XCTAssertEqual(items.count, 2, "the events are applied; got \(items)")
        XCTAssertEqual(model.lastSeq[1], 41)
        model.apply(.chatLive(ChatLive(chat: 1, id: open.id, seq: 41)))
        XCTAssertTrue(model.isLive(chat: 1))
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

    func testTheChatFolderIsNotBrowsedTwiceWhenARootIsTheSameFolder() {
        let (model, _) = model()
        var hello = hello()
        hello.roots = [Root(name: "vault", path: "/tmp/demo/"), Root(name: "projects", path: "/Users/someone/projects")]
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [summary(1)])))

        XCTAssertEqual(model.browsableRoots(for: 1).map(\.name), ["vault", "projects"])
        XCTAssertEqual(model.rootPath(root: "chat", chat: 1), "/tmp/demo", "the chat root still resolves")
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

    func testFilesListReplyLandsOnTheDirectoryAsRequestedNotAsResolved() {
        // `root/link -> real`: the gateway lists the link's target and
        // echoes the resolved path, `real`. The tree asked under `link`
        // (the name it shows) and must find the entries there.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        sent.frames.removeAll()

        model.listFiles(chat: 1, root: "chat", path: "link")
        guard case .filesList(let request)? = sent.frames.last else { return XCTFail("expected files.list, got \(sent.types())") }
        let entries = [Entry(name: "a.txt", dir: false, size: 0)]
        model.apply(.filesList(FilesList(root: "chat", path: "real", entries: entries, chat: 1, id: request.id)))

        XCTAssertEqual(model.fileEntries(chat: 1, root: "chat", path: "link"), entries)
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: "real"), "the resolved path was never asked for")
        model.listFiles(chat: 1, root: "chat", path: "link")
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 1, "listed: not asked again")

        // A reply to a request a refresh dropped is stale and fills nothing.
        model.listFiles(chat: 1, root: "chat", path: "src")
        guard case .filesList(let dropped)? = sent.frames.last else { return XCTFail("expected files.list") }
        model.refreshFiles(chat: 1)
        model.apply(.filesList(FilesList(root: "chat", path: "src", entries: entries, chat: 1, id: dropped.id)))
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: "src"))
    }

    func testFilesListRefusalClearsThePendingDirectoryAndShowsWhy() {
        // `root/esc -> ../outside`: listed as a directory, refused on expand
        // with files.outside_root. The row must show the refusal and the
        // directory must be askable again, not pending forever.
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        sent.frames.removeAll()

        model.listFiles(chat: 1, root: "chat", path: "esc")
        guard case .filesList(let request)? = sent.frames.last else { return XCTFail("expected files.list, got \(sent.types())") }
        XCTAssertNil(model.fileListError(chat: 1, root: "chat", path: "esc"))

        // An error for some other request leaves the listing pending.
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "a turn is running", chat: 1, id: "other")))
        model.listFiles(chat: 1, root: "chat", path: "esc")
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 1)

        model.apply(.error(ErrorMessage(code: "files.outside_root", message: "path leaves the root: esc", chat: 1, id: request.id)))
        XCTAssertEqual(model.fileListError(chat: 1, root: "chat", path: "esc"), "path leaves the root: esc")
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: "esc"), "a refusal is not an empty directory")

        // Asking again (the row's click) sends once more and clears the refusal until the answer.
        model.listFiles(chat: 1, root: "chat", path: "esc")
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 2)
        XCTAssertNil(model.fileListError(chat: 1, root: "chat", path: "esc"))
        guard case .filesList(let again)? = sent.frames.last else { return XCTFail("expected files.list") }
        model.apply(.filesList(FilesList(root: "chat", path: "esc", entries: [], chat: 1, id: again.id)))
        XCTAssertEqual(model.fileEntries(chat: 1, root: "chat", path: "esc"), [])
    }

    func testFilesListInFlightWhenTheSocketDropsIsAskedAgainOnReattach() {
        // The listing went out, the socket died before the answer: on the
        // next hello the directory is asked for again under a new id, same
        // gateway or a restarted one, instead of saying "Listing…" until a refresh.
        let (model, sent) = model()
        model.apply(.hello(hello(epoch: "epoch-A")))
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        model.listFiles(chat: 1, root: "chat", path: "")
        model.listFiles(chat: 1, root: "chat", path: "src")
        guard case .filesList(let lost)? = sent.frames.last else { return XCTFail("expected files.list") }
        sent.frames.removeAll()

        model.apply(.hello(hello(epoch: "epoch-A")))
        XCTAssertEqual(sent.types(), ["chat.open", "files.list", "files.list"], "the chat is re-opened, then each unanswered directory asked for again")
        let asked = sent.frames.compactMap { if case .filesList(let r) = $0 { return r } else { return nil } }
        XCTAssertEqual(asked.map(\.path), ["", "src"])
        XCTAssertFalse(asked.map(\.id).contains(lost.id), "a fresh id: the old reply, if it ever comes, is stale")
        XCTAssertNil(model.fileEntries(chat: 1, root: "chat", path: "src"))

        // Pending once more: a redraw does not ask a third time; the new reply fills the row.
        model.listFiles(chat: 1, root: "chat", path: "src")
        XCTAssertEqual(sent.types().filter { $0 == "files.list" }.count, 2)
        let entries = [Entry(name: "lib", dir: true, size: nil)]
        model.apply(.filesList(FilesList(root: "chat", path: "src", entries: entries, chat: 1, id: asked[1].id)))
        XCTAssertEqual(model.fileEntries(chat: 1, root: "chat", path: "src"), entries)

        // A restarted gateway (new epoch) asks again too; the listed directory is kept.
        model.listFiles(chat: 1, root: "chat", path: "src/lib")
        sent.frames.removeAll()
        model.apply(.hello(hello(epoch: "epoch-B")))
        XCTAssertEqual(sent.types(), ["chat.open", "files.list", "files.list"])
        XCTAssertEqual(model.fileEntries(chat: 1, root: "chat", path: "src"), entries)
    }

    // MARK: - Status strip, settings and quit (Task 21)

    func testStatusStripSaysModelContextAndServices() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1), summary(2, state: .working, alias: "notes")])))

        // No state word, no folder (v0.4): before anything is known the
        // strip only says where the services stand.
        XCTAssertEqual(model.statusStrip(gateway: .stopped).text, "Gateway is down")

        model.selected = 2
        model.setConnection(.connected)
        model.apply(.contextUsage(ContextUsage(chat: 2, percent: 2.2, model: "claude-opus-5-5", seq: 2)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).text, "Claude Opus 5.5 · 2% context · Checking…")

        // status.set lines never reach the strip (v0.3).
        model.apply(.statusSet(StatusSet(text: "thinking", chat: 2, seq: 3)))
        model.apply(.servicesStatus(ServicesStatus(services: [])))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).text, "Claude Opus 5.5 · 2% context · All services up")

        // The gateway text stays for Settings.
        XCTAssertEqual(model.statusStrip(gateway: .starting).gatewayText, "gateway starting")
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 4321)).gatewayText, "gateway running :4321")
        XCTAssertEqual(model.statusStrip(gateway: .failed("no gateway command found")).gatewayText,
                       "gateway failed: no gateway command found")
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

        // Not connected and no gateway to find (no supervisor here): nothing
        // to stop, nothing sent, no waiting.
        sent.frames.removeAll()
        await model.prepareToQuit(behaviour: .stopEverything, timeout: .seconds(1))
        XCTAssertTrue(sent.frames.isEmpty)
    }

    func testStopEverythingAfterTheWindowClosedStillReachesTheGateway() async throws {
        // The main window was closed, so the connection loop ended: no
        // socket, `connection` is `.disconnected`. The gateway is still up.
        // Quit with "stop everything" must find it and tell it to stop,
        // not report success while it runs on.
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "tok\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let suite = "portico-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.gatewayURL = gateway.url.absoluteString
        let supervisor = GatewaySupervisor(stateDir: dir)
        let model = AppModel(settings: settings)
        model.supervisor = supervisor
        model.appVersion = "0.1.0-test"
        XCTAssertEqual(model.connection, .disconnected)

        // The gateway closes the socket once it has been told to stop: that is its answer.
        Task {
            if await gateway.waitForFrame(type: "gateway.stop", seconds: 5) != nil {
                gateway.dropConnection()
            }
        }
        let began = ContinuousClock.now
        let closed = await model.stopGateway(timeout: .seconds(5))
        XCTAssertTrue(closed, "the gateway closed the socket after gateway.stop")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(4), "no waiting out the timeout once the socket closed")
        XCTAssertEqual(gateway.received.map { $0["type"] as? String }, ["hello", "gateway.stop"])
        XCTAssertEqual(gateway.received.first?["app_version"] as? String, "0.1.0-test")
        XCTAssertEqual(supervisor.status, .stopped)
        XCTAssertFalse(model.autoStartGateway)

        // A gateway that takes the frame and never closes does not hold the quit forever.
        let silent = FakeGateway()
        try await silent.start()
        defer { silent.stop() }
        settings.gatewayURL = silent.url.absoluteString
        let gaveUp = await model.stopGateway(timeout: .milliseconds(300))
        XCTAssertFalse(gaveUp)
        XCTAssertEqual(silent.received.map { $0["type"] as? String }, ["hello", "gateway.stop"])
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

    // MARK: - the three columns

    func testSidebarTogglesAndStartsShown() throws {
        let model = AppModel()
        XCTAssertTrue(model.sidebarVisible, "the A1 frame opens with the sidebar")
        model.sidebarVisible.toggle()
        XCTAssertFalse(model.sidebarVisible)
    }

    func testThemeMeasuresMatchTheFrame() {
        XCTAssertEqual(Theme.defaultWindowSize, CGSize(width: 1440, height: 900))
        XCTAssertEqual(ColumnWidths.sidebarDefault, 260)
        XCTAssertEqual(ColumnWidths.viewerDefault, 440)
        XCTAssertEqual(Theme.toolbarHeight, 52)
        XCTAssertEqual(Theme.statusStripHeight, 30)
        // The pen variables, dark and light, read back exactly.
        XCTAssertEqual(NSColor(hex: "#1E1E20").hexString, "#1E1E20")
        XCTAssertEqual(NSColor(hex: "#F3F3F5").hexString, "#F3F3F5")
    }

    // MARK: - the start screen (A4)

    private func startModel() throws -> (AppModel, Sent, URL) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-start-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portico-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (model, sent, folder)
    }

    func testStartSendsChatNewThenOpensAndSendsTheFirstMessage() throws {
        let (model, sent, folder) = try startModel()
        model.chosenStartFolder = folder
        model.startDraft = "  Summarize this folder  "
        model.attachToStart(["/tmp/a.md", "/tmp/a.md", "/tmp/b.md"])
        model.startChat(text: model.startDraft)

        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new, got \(sent.frames)") }
        XCTAssertEqual(new.folder, folder.path)
        XCTAssertTrue(model.isStarting)
        XCTAssertEqual(model.startDraft, "", "the composer clears on send")
        XCTAssertTrue(model.startAttachments.isEmpty)
        XCTAssertEqual(model.settings.lastFolder, folder.path, "the folder is remembered for next time")

        model.apply(.chatState(ChatState(chat: 7, state: .idle, id: new.id, seq: 1)))
        XCTAssertEqual(model.selected, 7)
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(Array(sent.types().suffix(2)), ["chat.open", "message.send"])
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.chat, 7)
        XCTAssertEqual(message.text, "Summarize this folder")
        XCTAssertEqual(message.attachments, ["/tmp/a.md", "/tmp/b.md"])
    }

    func testRefusedStartPutsTheWordsBackWithTheReason() throws {
        let (model, sent, folder) = try startModel()
        model.chosenStartFolder = folder
        model.attachToStart(["/tmp/a.md"])
        model.startChat(text: "hello")
        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new") }
        model.startDraft = "more"
        model.apply(.error(ErrorMessage(code: "engine.start_failed", message: "the engine could not start", id: new.id)))
        XCTAssertEqual(model.startDraft, "hello\nmore")
        XCTAssertEqual(model.startAttachments, ["/tmp/a.md"])
        XCTAssertEqual(model.startError, "the engine could not start")
        XCTAssertFalse(model.isStarting)
        XCTAssertNil(model.selected)
    }

    func testStartNeedsAFolderAndWordsAndOneAtATime() throws {
        let (model, sent, folder) = try startModel()
        model.startChat(text: "no folder yet")
        XCTAssertTrue(sent.frames.isEmpty, "no folder: nothing is sent")
        model.chosenStartFolder = folder
        model.startChat(text: "   ")
        XCTAssertTrue(sent.frames.isEmpty, "blank: nothing is sent")
        model.startChat(text: "one")
        model.startChat(text: "two")
        XCTAssertEqual(sent.types(), ["chat.new"], "a second start waits for the first")
    }

    func testStartFolderFallsBackToTheLastThenTheFirstRoot() throws {
        let (model, _, folder) = try startModel()
        XCTAssertNil(model.startFolder)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portico-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = model.handleHello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [Root(name: "vault", path: root.path)],
            commands: [], capabilities: []))
        XCTAssertEqual(model.startFolder?.path, root.path)
        model.settings.lastFolder = folder.path
        XCTAssertEqual(model.startFolder?.path, folder.path)
        XCTAssertEqual(model.startFolderChoices.map(\.path), [folder.path, root.path])
        model.settings.lastFolder = "/nonexistent/\(UUID().uuidString)"
        XCTAssertEqual(model.startFolder?.path, root.path, "a folder that is gone is not offered")
    }

    func testActionChipStartsWithoutTakingTheTypedText() throws {
        let (model, sent, folder) = try startModel()
        model.chosenStartFolder = folder
        model.startDraft = "half typed"
        model.attachToStart(["/tmp/a.md"])
        model.startChat(text: "Summarize this folder", fromComposer: false)
        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new") }
        XCTAssertEqual(model.startDraft, "half typed")
        XCTAssertEqual(model.startAttachments, ["/tmp/a.md"])
        model.apply(.chatState(ChatState(chat: 2, state: .idle, id: new.id, seq: 1)))
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.attachments, [])
    }

    func testGreetingByTimeOfDayAndFirstName() {
        let cal = Calendar.current
        func at(_ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date())! }
        XCTAssertEqual(StartView.greeting(at: at(9), fullName: "Larry Paul Pelty"), "Good morning, Larry")
        XCTAssertEqual(StartView.greeting(at: at(14), fullName: "Larry Paul Pelty"), "Good afternoon, Larry")
        XCTAssertEqual(StartView.greeting(at: at(20), fullName: ""), "Good evening")
    }
}

extension NSColor {
    /// `#RRGGBB` of an sRGB colour, for the tests.
    var hexString: String {
        let c = usingColorSpace(.sRGB)!
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
