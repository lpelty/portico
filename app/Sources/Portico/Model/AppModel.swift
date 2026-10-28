import Foundation

// MARK: - Transcript items

/// One finished-or-running tool call, folded to a row: the tool, what it
/// touched, and (once finished) whether it went well and what came back.
struct ToolRow: Equatable, Sendable, Identifiable {
    var toolUseId: String
    var turn: Int
    var tool: String
    var summary: String
    var input: [String: JSONValue]
    var finished: Bool = false
    var ok: Bool? = nil
    /// The finish summary (a line count, an error) — distinct from `summary`,
    /// which stays what the start said.
    var result: String? = nil

    var id: String { toolUseId }
}

/// A turn ended; shown as a small marker between turns.
struct TurnMarker: Equatable, Sendable {
    var turn: Int
    var outcome: Outcome
}

/// What the conversation pane renders, oldest first.
enum TranscriptItem: Equatable, Sendable, Identifiable {
    case userText(UserText)
    case assistantText(id: String, text: String)
    case tool(ToolRow)
    case card(CardAsk)
    case turnMarker(TurnMarker)

    var id: String {
        switch self {
        case .userText(let u): "user:\(u.turn):\(u.text.hashValue)"
        case .assistantText(let id, _): "assistant:\(id)"
        case .tool(let row): "tool:\(row.toolUseId)"
        case .card(let card): "card:\(card.id)"
        case .turnMarker(let marker): "turn:\(marker.turn)"
        }
    }
}

/// Where a card stands from the app's side: still waiting, answered from
/// this app, or cancelled by the gateway (with the reason it gave).
enum CardStatus: Equatable, Sendable {
    case open
    case answered
    case cancelled(String)
}

// MARK: - AppModel

/// The app's state and the one reducer for gateway messages.
///
/// Every frame from the gateway goes through `apply`; everything the app
/// wants to send goes out through `outbound`, which the connection layer
/// sets to the socket and a test sets to an array. The reconnect policy
/// (`handleHello`, sequence watermarks) lives here too, next to the state
/// it protects.
@MainActor
final class AppModel: ObservableObject {
    /// The gateway's latest `hello`; `nil` until the first attach.
    @Published private(set) var hello: HelloServer?
    /// The sidebar, exactly as the gateway last listed it.
    @Published private(set) var chats: [ChatSummary] = []
    /// The chat shown in the conversation pane.
    @Published var selected: Int?
    /// Per chat, what the conversation pane renders.
    @Published private(set) var transcripts: [Int: [TranscriptItem]] = [:]
    /// Per chat, the cards still waiting for an answer, in arrival order.
    @Published private(set) var openCards: [Int: [CardAsk]] = [:]
    /// Per chat, every artifact reported, oldest first, one per id.
    @Published private(set) var artifacts: [Int: [Artifact]] = [:]
    /// Per chat, the last `status.set` line (or the last error's message).
    @Published private(set) var status: [Int: String] = [:]
    /// The last chat-less `status.set` line: lifecycle command output, "stopping".
    @Published private(set) var gatewayStatus: String?
    /// The last `error` frame, for the status strip.
    @Published private(set) var lastError: ErrorMessage?
    /// Per chat, cards that were answered or cancelled: id → why (`answered`, or the cancel reason).
    @Published private(set) var closedCards: [Int: [String: String]] = [:]
    /// Per chat, whether `chat.live` has arrived since the last `chat.open`.
    @Published private(set) var live: Set<Int> = []
    /// The socket's state, for the status strip.
    @Published private(set) var connection: ConnectionState = .disconnected
    /// Per chat, the attachment paths queued in the input bar: the Files
    /// pane and drag-and-drop add here; a send clears the chat's list.
    @Published private(set) var draftAttachments: [Int: [String]] = [:]
    /// Per chat, the text in the input bar's editor. Kept here rather than
    /// in the view so switching chats keeps a half-typed message, like the
    /// chips, and so a refused send can give the text back.
    @Published private(set) var drafts: [Int: String] = [:]

    /// A `message.send` the gateway has not answered yet. The gateway says
    /// nothing about the person's own text on a live turn (`user.text` is
    /// replay-only), so the app keeps it until `turn.started` names the
    /// turn — then it becomes the bubble — or an `error` with the send's id
    /// refuses it, and the text and chips go back into the input bar.
    struct PendingSend: Equatable, Sendable {
        var id: String
        var text: String
        var attachments: [String]
    }

    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// The last `seq` seen per chat, the watermark a reconnect asks for events since.
    private(set) var lastSeq: [Int: Int] = [:]

    /// Chats this app has opened in this run; each is re-opened on reattach.
    private(set) var openedChats: Set<Int> = []

    /// Where outbound frames go. The connection layer points this at the
    /// socket; before it is set (or when the socket is down) frames are
    /// dropped, and the next `hello` re-opens every chat anyway.
    var outbound: ((ClientMessage) -> Void)?

    /// Per chat, the `since` the last `chat.open` carried, so the matching
    /// `chat.history` knows whether to replace the transcript or append.
    private var pendingOpenSince: [Int: Int?] = [:]
    /// `chat.new` request ids whose reply should select the new chat.
    private var pendingNewChats: Set<String> = []
    /// Per chat, the turn the last delta belonged to, for coalescing.
    private var currentTurn: [Int: Int] = [:]
    /// Per chat, the one send in flight (a second is refused `chat.busy`).
    private(set) var pendingSends: [Int: PendingSend] = [:]
    private var nextItemId = 0

    init() {}

    // MARK: - hello and reattach

    /// Record a `hello` from the gateway and return what to send to catch up.
    ///
    /// Same epoch as last time: the gateway is the one we were talking to, so
    /// re-open every chat with `since` set to its watermark and the ring
    /// buffer fills the gap. A different epoch: the gateway restarted, its
    /// sequence numbers started over, and the ring is empty — drop every
    /// watermark and open from the beginning so the transcript is replayed
    /// exactly once (Review Focus 2).
    func handleHello(_ incoming: HelloServer) -> [ClientMessage] {
        if let previous = hello, previous.epoch != incoming.epoch {
            lastSeq = [:]
            // A restarted gateway never saw (or will never answer) a send in
            // flight; the replay from the beginning carries any turn that ran.
            pendingSends = [:]
        }
        hello = incoming
        return openedChats.sorted().map { chat in
            .chatOpen(ChatOpen(chat: chat, since: lastSeq[chat], id: Self.requestId()))
        }
    }

    /// Remember that a chat has been opened, so a reattach re-opens it.
    func noteOpened(chat: Int) {
        openedChats.insert(chat)
    }

    /// Forget a chat (removed, or no longer shown).
    func noteClosed(chat: Int) {
        openedChats.remove(chat)
        lastSeq[chat] = nil
    }

    /// Advance a chat's watermark from a chat-scoped, sequenced event.
    /// Unsequenced events (a transcript replay) and re-sent frames with an
    /// older `seq` (open cards on `chat.open`) leave it alone.
    func noteSeq(of message: ServerMessage) {
        let envelope = message.envelope
        guard let chat = envelope.chat, let seq = envelope.seq else { return }
        if let seen = lastSeq[chat], seen >= seq { return }
        lastSeq[chat] = seq
    }

    func isLive(chat: Int) -> Bool { live.contains(chat) }

    func setConnection(_ state: ConnectionState) { connection = state }

    // MARK: - the reducer

    /// Apply one frame from the gateway.
    func apply(_ message: ServerMessage) {
        switch message {
        case .hello(let hello):
            for frame in handleHello(hello) {
                if case .chatOpen(let open) = frame {
                    pendingOpenSince[open.chat] = open.since
                    live.remove(open.chat)
                }
                send(frame)
            }

        case .chatList(let list):
            chats = list.chats
            if let selected, !list.chats.contains(where: { $0.chat == selected }) {
                self.selected = nil
            }
            for chat in Array(openedChats) where !list.chats.contains(where: { $0.chat == chat }) {
                forget(chat: chat)
            }

        case .chatState(let state):
            if let index = chats.firstIndex(where: { $0.chat == state.chat }) {
                chats[index].state = state.state
            }
            if let id = state.id, pendingNewChats.remove(id) != nil {
                open(chat: state.chat)
            }
            noteSeq(of: message)

        case .chatHistory(let history):
            applyHistory(history)

        case .chatLive(let liveMarker):
            live.insert(liveMarker.chat)
            pendingOpenSince[liveMarker.chat] = nil
            noteSeq(of: message)

        case .artifactCreated(let created):
            // Stored artifacts re-sent on chat.open carry no seq and arrive once each.
            applyEvent(message, to: created.chat)
            noteSeq(of: message)

        case .filesList:
            // Task 20 consumes these; nothing to keep in the model yet.
            break

        case .statusSet(let status):
            if let chat = status.chat {
                self.status[chat] = status.text
            } else {
                gatewayStatus = status.text
            }
            noteSeq(of: message)

        case .error(let error):
            lastError = error
            if let chat = error.chat {
                status[chat] = error.message
                if let id = error.id, let pending = pendingSends[chat], pending.id == id {
                    restore(pending, to: chat)
                }
            }

        case .turnStarted, .userText, .textDelta, .toolStarted, .toolFinished, .turnFinished, .cardAsk, .cardCancel:
            guard let chat = message.envelope.chat else { return }
            // A sequenced event we already hold (a re-sent card, a ring
            // overlap) is not applied twice; the card case de-duplicates by
            // id as well, for frames that arrive without a seq.
            if let seq = message.envelope.seq, let seen = lastSeq[chat], seq <= seen, !isCard(message) {
                return
            }
            applyEvent(message, to: chat)
            noteSeq(of: message)
        }
    }

    private func isCard(_ message: ServerMessage) -> Bool {
        if case .cardAsk = message { return true }
        if case .cardCancel = message { return true }
        return false
    }

    /// `chat.history`: a replay from the beginning replaces the transcript;
    /// a catch-up (`since` was sent) appends what the ring held after the
    /// watermark. `truncated` means the gap could not be filled: refetch
    /// from the beginning.
    private func applyHistory(_ history: ChatHistory) {
        let chat = history.chat
        if history.truncated {
            lastSeq[chat] = nil
            pendingOpenSince[chat] = .some(nil)
            send(.chatOpen(ChatOpen(chat: chat, since: nil, id: Self.requestId())))
            return
        }
        let since: Int? = pendingOpenSince[chat] ?? nil
        let fromBeginning = since == nil || history.events.contains { $0.envelope.seq == nil }
        if fromBeginning {
            transcripts[chat] = []
            openCards[chat] = []
            artifacts[chat] = []
            closedCards[chat] = [:]
            currentTurn[chat] = nil
            lastSeq[chat] = nil
            // The replay is the whole truth of the chat: its `user.text` is
            // the bubble for any send that ran, so the pending one must not add a second.
            pendingSends[chat] = nil
        }
        for event in history.events {
            if let seq = event.envelope.seq, let seen = lastSeq[chat], seq <= seen { continue }
            applyEvent(event, to: chat)
            noteSeq(of: event)
        }
    }

    /// The per-event reducer shared by live frames and a history replay.
    private func applyEvent(_ event: ServerMessage, to chat: Int) {
        var items = transcripts[chat] ?? []
        defer { transcripts[chat] = items }

        switch event {
        case .turnStarted(let started):
            currentTurn[chat] = started.turn
            if let pending = pendingSends.removeValue(forKey: chat) {
                items.append(.userText(UserText(chat: chat, turn: started.turn, text: pending.text)))
            }

        case .userText(let user):
            currentTurn[chat] = user.turn
            items.append(.userText(user))

        case .textDelta(let delta):
            if case .assistantText(let id, let text)? = items.last, currentTurn[chat] == delta.turn {
                items[items.count - 1] = .assistantText(id: id, text: text + delta.text)
            } else {
                currentTurn[chat] = delta.turn
                items.append(.assistantText(id: Self.itemId(&nextItemId), text: delta.text))
            }

        case .toolStarted(let started):
            currentTurn[chat] = started.turn
            let row = ToolRow(
                toolUseId: started.toolUseId, turn: started.turn, tool: started.tool,
                summary: started.summary, input: started.input)
            if let index = items.lastIndex(where: { if case .tool(let r) = $0 { return r.toolUseId == row.toolUseId } else { return false } }) {
                items[index] = .tool(row)
            } else {
                items.append(.tool(row))
            }

        case .toolFinished(let finished):
            if let index = items.lastIndex(where: { if case .tool(let r) = $0 { return r.toolUseId == finished.toolUseId } else { return false } }),
                case .tool(var row) = items[index]
            {
                row.finished = true
                row.ok = finished.ok
                row.result = finished.summary
                items[index] = .tool(row)
            } else {
                // The start fell off the ring; show the finish rather than lose it.
                items.append(.tool(ToolRow(
                    toolUseId: finished.toolUseId, turn: finished.turn, tool: "tool", summary: finished.summary,
                    input: [:], finished: true, ok: finished.ok, result: finished.summary)))
            }

        case .turnFinished(let finished):
            items.append(.turnMarker(TurnMarker(turn: finished.turn, outcome: finished.outcome)))
            if currentTurn[chat] == finished.turn { currentTurn[chat] = nil }

        case .cardAsk(let card):
            var open = openCards[chat] ?? []
            let known = open.contains { $0.id == card.id } || closedCards[chat]?[card.id] != nil
            if !known {
                open.append(card)
                openCards[chat] = open
                items.append(.card(card))
            }

        case .cardCancel(let cancel):
            closeCard(chat: chat, id: cancel.id, why: cancel.reason ?? "cancelled")

        case .artifactCreated(let created):
            var list = artifacts[chat] ?? []
            if let index = list.firstIndex(where: { $0.id == created.artifact.id }) {
                list[index] = created.artifact
            } else {
                list.append(created.artifact)
            }
            artifacts[chat] = list

        case .hello, .chatList, .chatState, .chatHistory, .chatLive, .filesList, .statusSet, .error:
            break
        }
    }

    /// Take a card out of the open set and record why. Called on
    /// `card.cancel`, and by `answerCard` once an answer is sent.
    func closeCard(chat: Int, id: String, why: String) {
        openCards[chat] = (openCards[chat] ?? []).filter { $0.id != id }
        var closed = closedCards[chat] ?? [:]
        closed[id] = why
        closedCards[chat] = closed
    }

    // MARK: - cards

    /// The `closedCards` reason that means "answered from this app".
    static let answeredMarker = "answered"

    /// The cards pinned above the input: the chat's open cards, oldest first.
    func pinnedCards(for chat: Int) -> [CardAsk] {
        openCards[chat] ?? []
    }

    /// How the transcript's inline copy of a card reads: open while the
    /// gateway waits, `answered` once this app answered, `cancelled` with
    /// the gateway's reason after a `card.cancel`.
    func cardStatus(chat: Int, id: String) -> CardStatus {
        guard let why = closedCards[chat]?[id] else { return .open }
        return why == Self.answeredMarker ? .answered : .cancelled(why)
    }

    /// Send a card's answer and unpin it. A card that is not open (answered
    /// already, cancelled, never seen) gets nothing: the gateway would only
    /// refuse it as `card.stale`, and there is nothing to show for it.
    func answerCard(_ answer: CardAnswer) {
        guard pinnedCards(for: answer.chat).contains(where: { $0.id == answer.id }) else { return }
        send(.cardAnswer(answer))
        closeCard(chat: answer.chat, id: answer.id, why: Self.answeredMarker)
    }

    // MARK: - sidebar actions

    /// Ask the gateway for a chat in `folder`; the reply selects it.
    func newChat(folder: URL) {
        let id = Self.requestId()
        pendingNewChats.insert(id)
        send(.chatNew(ChatNew(folder: folder.path, id: id)))
    }

    /// Show a chat and ask the gateway for its events (since our watermark).
    func open(chat: Int) {
        selected = chat
        noteOpened(chat: chat)
        let since = lastSeq[chat]
        pendingOpenSince[chat] = since
        live.remove(chat)
        send(.chatOpen(ChatOpen(chat: chat, since: since, id: Self.requestId())))
    }

    func stop(chat: Int) {
        send(.chatStop(ChatStop(chat: chat, id: Self.requestId())))
    }

    /// Remove a chat: the gateway forgets it and the app drops its state.
    func remove(chat: Int) {
        send(.chatRemove(ChatRemove(chat: chat, id: Self.requestId())))
        forget(chat: chat)
    }

    /// Set or clear (empty or `nil`) a chat's alias.
    func alias(chat: Int, _ alias: String?) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        send(.chatAlias(ChatAlias(chat: chat, alias: trimmed.isEmpty ? nil : trimmed, id: Self.requestId())))
    }

    // MARK: - conversation actions

    /// Send `text` (trimmed) with the chat's draft attachments as one
    /// `message.send`, then clear the draft. Blank text sends nothing: the
    /// gateway would have nothing to give the engine. The send is remembered
    /// until the gateway starts its turn (the user bubble) or refuses it
    /// (the text and chips come back).
    func sendMessage(chat: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attachments = draftAttachments[chat] ?? []
        let id = Self.requestId()
        pendingSends[chat] = PendingSend(id: id, text: trimmed, attachments: attachments)
        send(.messageSend(MessageSend(chat: chat, text: trimmed, attachments: attachments, id: id)))
        draftAttachments[chat] = nil
        drafts[chat] = nil
    }

    /// Put a refused send back where it was composed. Text typed since the
    /// send stays, after the returned text; chips are re-added ahead of any
    /// attached since.
    private func restore(_ pending: PendingSend, to chat: Int) {
        pendingSends[chat] = nil
        let typedSince = draft(for: chat)
        drafts[chat] = typedSince.isEmpty ? pending.text : pending.text + "\n" + typedSince
        let attachedSince = draftAttachments[chat] ?? []
        draftAttachments[chat] = nil
        attach(pending.attachments + attachedSince, to: chat)
    }

    /// The input bar's text for a chat (empty when nothing is typed).
    func draft(for chat: Int) -> String {
        drafts[chat] ?? ""
    }

    func setDraft(_ text: String, for chat: Int) {
        drafts[chat] = text.isEmpty ? nil : text
    }

    /// Interrupt the running turn; the gateway answers with
    /// `turn.finished outcome=stopped` (nothing, when nothing is running).
    func stopTurn(chat: Int) {
        send(.turnStop(TurnStop(chat: chat, id: Self.requestId())))
    }

    /// Queue attachment paths for the chat's next send, de-duplicated, in order.
    func attach(_ paths: [String], to chat: Int) {
        var list = draftAttachments[chat] ?? []
        for path in paths where !list.contains(path) {
            list.append(path)
        }
        draftAttachments[chat] = list
    }

    func detach(_ path: String, from chat: Int) {
        draftAttachments[chat] = (draftAttachments[chat] ?? []).filter { $0 != path }
    }

    /// The chat's state word as the sidebar last heard it.
    func state(of chat: Int) -> ChatStateWord? {
        chats.first { $0.chat == chat }?.state
    }

    /// A turn is running or a card is waiting: a send would be refused
    /// (`chat.busy`), so the input bar offers Stop instead.
    func isBusy(chat: Int) -> Bool {
        switch state(of: chat) {
        case .working, .waitingOnYou: true
        case .idle, .stopped, nil: false
        }
    }

    private func forget(chat: Int) {
        noteClosed(chat: chat)
        draftAttachments[chat] = nil
        drafts[chat] = nil
        pendingSends[chat] = nil
        transcripts[chat] = nil
        openCards[chat] = nil
        artifacts[chat] = nil
        status[chat] = nil
        closedCards[chat] = nil
        live.remove(chat)
        pendingOpenSince[chat] = nil
        currentTurn[chat] = nil
        if selected == chat { selected = nil }
    }

    // MARK: - outbound

    func send(_ message: ClientMessage) {
        outbound?(message)
    }

    static func requestId() -> String {
        UUID().uuidString.lowercased()
    }

    private static func itemId(_ counter: inout Int) -> String {
        counter += 1
        return String(counter)
    }
}

// MARK: - The connection loop

extension AppModel {
    /// Attach to the gateway and keep attached: find one (or start one),
    /// connect, feed every frame to `apply`, and when the socket drops wait
    /// a moment and do it again. `hello` on each connect re-opens the chats
    /// this app had open, with `since` where the gateway is the same one.
    ///
    /// Runs until the task is cancelled (the window closed).
    func run(supervisor: GatewaySupervisor, settings: Settings, appVersion: String) async {
        let client = GatewayClient()
        outbound = { message in
            Task { try? await client.send(message) }
        }
        defer {
            outbound = nil
            Task { await client.disconnect() }
        }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            connection = .connecting
            guard let endpoint = await endpoint(supervisor: supervisor, settings: settings) else {
                connection = .failed(supervisor.statusText)
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(10))
                continue
            }
            do {
                let hello = try await client.connect(url: endpoint.url, token: endpoint.token, appVersion: appVersion)
                connection = .connected
                backoff = .seconds(1)
                apply(.hello(hello))
                for await message in await client.messages {
                    apply(message)
                }
                connection = .disconnected
            } catch {
                connection = .failed("\(error)")
            }
            if Task.isCancelled { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(10))
        }
    }

    /// Where to connect: the settings override when set, else a running
    /// gateway found through the ledger, else one this app starts.
    private func endpoint(supervisor: GatewaySupervisor, settings: Settings) async -> (url: URL, token: String)? {
        if let override = settings.gatewayURL, let url = URL(string: override) {
            guard let token = supervisor.readToken() else { return nil }
            return (url, token)
        }
        if let found = await supervisor.discover() {
            return (URL(string: "ws://127.0.0.1:\(found.port)")!, found.token)
        }
        guard let started = try? await supervisor.start() else { return nil }
        return (URL(string: "ws://127.0.0.1:\(started.port)")!, started.token)
    }
}

extension GatewaySupervisor {
    /// One line for the status strip.
    var statusText: String {
        switch status {
        case .stopped: "gateway stopped"
        case .starting: "starting the gateway"
        case .running(let port): "gateway on port \(port)"
        case .failed(let reason): reason
        }
    }
}
