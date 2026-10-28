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
    /// Per chat, the artifact the viewer shows: the last one that
    /// auto-opened or that the person picked from the history.
    @Published private(set) var current: [Int: Artifact] = [:]
    /// Whether the viewer column is wanted. A person collapses it; an
    /// auto-open or a pick from the history brings it back. It is only
    /// shown when the chat has artifacts at all (`isViewerShown`).
    @Published var viewerVisible: Bool = true
    /// Per chat, the last `status.set` line (or the last error's message).
    @Published private(set) var status: [Int: String] = [:]
    /// The last chat-less `status.set` line: lifecycle command output, "stopping".
    @Published private(set) var gatewayStatus: String?
    /// The last `error` frame, for the status strip.
    @Published private(set) var lastError: ErrorMessage?
    /// Whether the connection loop may start a gateway when it finds none.
    /// `true` until the person stops the gateway (menu, settings, or a quit
    /// with "stop everything"); Start puts it back.
    @Published private(set) var autoStartGateway: Bool = true
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
    /// The Files pane's cache: per chat, root and directory (the gateway's
    /// normalised relative path), the entries the last `files.list` gave.
    /// A directory is fetched when it is expanded, once, until a refresh.
    @Published private(set) var fileTree: [FilesKey: [Entry]] = [:]

    /// One directory in one root of one chat's Files pane.
    struct FilesKey: Hashable, Sendable {
        var chat: Int
        var root: String
        var path: String
    }

    /// A `message.send` the gateway has not answered yet. The gateway
    /// echoes the person's words as `user.text` right after `turn.started`
    /// (the one bubble, live or replayed), so the app keeps the send only
    /// until that arrives — or until an `error` with the send's id refuses
    /// it, and the text and chips go back into the input bar.
    struct PendingSend: Equatable, Sendable {
        var id: String
        var text: String
        var attachments: [String]
        /// Whether the text and chips came out of the composer (a typed
        /// message) and go back there on a refusal. An action button's
        /// send never touched the composer, so a refusal restores nothing.
        var fromComposer: Bool = true
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
    /// Per chat, the id of the artifact that was on screen when a replay
    /// from the beginning reset the list; put back when it is re-listed.
    private var restoreCurrent: [Int: String] = [:]
    /// Directories with a `files.list` in flight, so an expand asks once.
    private var pendingFileLists: Set<FilesKey> = []
    private var nextItemId = 0
    /// Ordering for status lines: per chat and chat-less, the strip shows
    /// whichever `status.set` (or error) came last.
    private var statusStamps: [Int: Int] = [:]
    private var gatewayStatusStamp = 0
    private var statusClock = 0
    /// The connection loop's pause between attempts; `startGateway` cancels it.
    private var reconnectWait: Task<Void, Never>?
    /// The loop's socket, while `run` is going; `stopGateway` closes it.
    private var client: GatewayClient?
    /// Whether `run` is going (the window is open).
    private var loopRunning = false

    /// The supervisor the app uses: set by `run`, and by the app at launch
    /// so Start works from the settings window before the main window's
    /// loop (or after it closed).
    weak var supervisor: GatewaySupervisor?

    /// The auto-open settings the reducer consults (spec §5.3).
    let settings: Settings

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

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
        guard incoming.protocol == protocolVersion else {
            // The connection layer refuses this before it gets here; the
            // reducer refuses it too so no path opens chats on a mismatch.
            connection = .failed(GatewayClient.protocolMismatchText(incoming.protocol))
            return []
        }
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

        case .filesList(let list):
            // A direct answer (`id`, no seq) to the Files pane's request;
            // keyed by the gateway's normalised path so a child's key is
            // what `listFiles` joins (`src/lib`).
            if let chat = list.chat {
                let key = FilesKey(chat: chat, root: list.root, path: list.path)
                fileTree[key] = list.entries
                pendingFileLists.remove(key)
            }

        case .statusSet(let status):
            if let chat = status.chat {
                setStatus(status.text, for: chat)
            } else {
                gatewayStatus = status.text
                gatewayStatusStamp = nextStatusStamp()
            }
            noteSeq(of: message)

        case .error(let error):
            lastError = error
            if let chat = error.chat {
                setStatus(error.message, for: chat)
                if let id = error.id, let pending = pendingSends[chat], pending.id == id {
                    restore(pending, to: chat)
                }
            }

        case .turnStarted, .userText, .textDelta, .toolStarted, .toolFinished, .turnFinished, .cardAsk, .cardAnswered, .cardCancel:
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
    /// watermark. `truncated` on a catch-up means the gap could not be
    /// filled: refetch from the beginning. `truncated` on a reply to an
    /// open from the beginning is as good as it gets (the ring wrapped and
    /// there is no transcript): apply it, asking again would only loop.
    private func applyHistory(_ history: ChatHistory) {
        let chat = history.chat
        let since: Int? = pendingOpenSince[chat] ?? nil
        if history.truncated, since != nil {
            lastSeq[chat] = nil
            pendingOpenSince[chat] = .some(nil)
            send(.chatOpen(ChatOpen(chat: chat, since: nil, id: Self.requestId())))
            return
        }
        let fromBeginning = since == nil || history.events.contains { $0.envelope.seq == nil }
        if fromBeginning {
            transcripts[chat] = []
            openCards[chat] = []
            // Files the person opened from the Files pane are this app's
            // alone: the gateway never lists them, so they stay.
            artifacts[chat] = (artifacts[chat] ?? []).filter { Self.isLocal($0) }
            // The stored artifacts follow as open=false; the one on screen
            // comes back if it is still among them (`applyEvent`), and
            // nothing else pops open on a replay.
            if let shown = current[chat], !Self.isLocal(shown) {
                restoreCurrent[chat] = shown.id
                current[chat] = nil
            }
            closedCards[chat] = [:]
            currentTurn[chat] = nil
            lastSeq[chat] = nil
            // The replay is the whole truth of the chat: its `user.text` is
            // the bubble for any send that ran; a send the gateway never saw is gone.
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

        case .userText(let user):
            // The gateway's echo is the bubble, live or replayed; the send
            // that started this turn has been accepted and owes nothing more.
            currentTurn[chat] = user.turn
            items.append(.userText(user))
            pendingSends[chat] = nil

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

        case .cardAnswered(let answered):
            // The gateway accepted an answer (ours, or one given before a
            // relaunch and now replayed): the card is closed either way.
            closeCard(chat: chat, id: answered.id, why: Self.answeredMarker)

        case .cardCancel(let cancel):
            closeCard(chat: chat, id: cancel.id, why: cancel.reason ?? "cancelled")

        case .artifactCreated(let created):
            let artifact = created.artifact
            var list = artifacts[chat] ?? []
            if let index = list.firstIndex(where: { $0.id == artifact.id }) {
                list[index] = artifact
            } else {
                list.append(artifact)
            }
            artifacts[chat] = list
            // Auto-open (spec §5.3): the gateway marks exactly the artifact
            // that may open (`open`), and the settings say whether this app
            // lets it, overall and per kind. Non-viewable kinds never pass
            // `shouldAutoOpen`, whatever `open` says.
            if artifact.open && settings.shouldAutoOpen(media: artifact.media.rawValue) {
                show(artifact, in: chat)
            } else if restoreCurrent[chat] == artifact.id {
                current[chat] = artifact
            }
            if restoreCurrent[chat] == artifact.id { restoreCurrent[chat] = nil }

        case .hello, .chatList, .chatState, .chatHistory, .chatLive, .filesList, .statusSet, .error:
            break
        }
    }

    /// Take a card out of the open set and record why. Called on
    /// `card.answered` and `card.cancel`, and by `answerCard` as soon as an
    /// answer is sent (the gateway's `card.answered` then confirms).
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

    // MARK: - viewer

    /// Put an artifact in the viewer, make sure the column is showing, and
    /// tell the gateway (`artifact.opened`, telemetry only). Used by the
    /// auto-open rule and by a pick from the history list.
    func show(_ artifact: Artifact, in chat: Int) {
        current[chat] = artifact
        viewerVisible = true
        send(.artifactOpened(ArtifactOpened(chat: chat, artifactId: artifact.id, id: Self.requestId())))
    }

    /// The chat's artifacts, newest first, for the history list.
    func history(for chat: Int) -> [Artifact] {
        (artifacts[chat] ?? []).reversed()
    }

    /// The viewer column is there when the chat has produced something
    /// and the person has not collapsed it. Nothing produced: no column.
    func isViewerShown(for chat: Int) -> Bool {
        viewerVisible && !(artifacts[chat] ?? []).isEmpty
    }

    // MARK: - sidebar actions

    /// Ask the gateway for a chat in `folder`; the reply selects it.
    func newChat(folder: URL) {
        let id = Self.requestId()
        pendingNewChats.insert(id)
        send(.chatNew(ChatNew(folder: folder.path, id: id)))
    }

    /// Show a chat and ask the gateway for its events: since our watermark
    /// for a chat this app opened before, from the beginning otherwise.
    ///
    /// `since` means "I hold everything up to here", which is true only of
    /// a chat opened in this run. The gateway sends every chat's frames to
    /// the attached app, opened or not, so a never-opened chat's watermark
    /// names a point mid-stream: opening from there would show the tail
    /// alone, and (`since` suppresses the transcript read) never the
    /// conversation before it.
    func open(chat: Int) {
        selected = chat
        let since = openedChats.contains(chat) ? lastSeq[chat] : nil
        noteOpened(chat: chat)
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
    ///
    /// One send in flight per chat: while the last one is unanswered
    /// (`isSending`), another is not sent and the composer keeps what it
    /// has. The gateway would refuse it `chat.busy` anyway, but only after
    /// it has started the first turn — and between a send and its
    /// `turn.started` the engine may take seconds to start, with the state
    /// word still `idle`, so the state word alone cannot gate the composer.
    func sendMessage(chat: Int, text: String) {
        dispatch(chat: chat, text: text, attachments: draftAttachments[chat] ?? [], fromComposer: true)
    }

    /// Send an action button's text (`hello.actions`) on its own. The
    /// composer is not involved: whatever is typed stays typed, and the
    /// chips stay queued for the message they were attached to. Same
    /// one-in-flight rule as `sendMessage`.
    func sendAction(chat: Int, text: String) {
        dispatch(chat: chat, text: text, attachments: [], fromComposer: false)
    }

    private func dispatch(chat: Int, text: String, attachments: [String], fromComposer: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending(chat: chat) else { return }
        let id = Self.requestId()
        pendingSends[chat] = PendingSend(id: id, text: trimmed, attachments: attachments, fromComposer: fromComposer)
        send(.messageSend(MessageSend(chat: chat, text: trimmed, attachments: attachments, id: id)))
        if fromComposer {
            draftAttachments[chat] = nil
            drafts[chat] = nil
        }
    }

    /// Put a refused send back where it was composed. Text typed since the
    /// send stays, after the returned text; chips are re-added ahead of any
    /// attached since. An action's send was never in the composer: its
    /// refusal is forgotten (the status line carries the message).
    private func restore(_ pending: PendingSend, to chat: Int) {
        pendingSends[chat] = nil
        guard pending.fromComposer else { return }
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

    /// A send the gateway has not answered yet (no `turn.started` and no
    /// refusal so far): the composer holds the next one until it is.
    func isSending(chat: Int) -> Bool {
        pendingSends[chat] != nil
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
        current[chat] = nil
        restoreCurrent[chat] = nil
        status[chat] = nil
        statusStamps[chat] = nil
        closedCards[chat] = nil
        live.remove(chat)
        pendingOpenSince[chat] = nil
        currentTurn[chat] = nil
        fileTree = fileTree.filter { $0.key.chat != chat }
        pendingFileLists = pendingFileLists.filter { $0.chat != chat }
        if selected == chat { selected = nil }
    }

    private func setStatus(_ text: String, for chat: Int) {
        status[chat] = text
        statusStamps[chat] = nextStatusStamp()
    }

    private func nextStatusStamp() -> Int {
        statusClock += 1
        return statusClock
    }

    /// The newest status line that concerns `chat`: its own `status.set`
    /// (or last error) or a chat-less one (a lifecycle command's output,
    /// "stopping"), whichever the gateway sent last. No chat: the chat-less one.
    func latestStatusLine(for chat: Int?) -> String? {
        guard let chat, let own = status[chat] else { return gatewayStatus }
        guard gatewayStatus != nil else { return own }
        return (statusStamps[chat] ?? 0) >= gatewayStatusStamp ? own : gatewayStatus
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

// MARK: - The Files pane

extension AppModel {
    /// The root name the gateway gives every chat's own folder (spec §5.6).
    static let chatRoot = "chat"

    /// The prefix of an artifact this app made for a file opened from the
    /// Files pane. The gateway never hears of these, so a replay keeps them.
    static let localArtifactPrefix = "local:"

    static func isLocal(_ artifact: Artifact) -> Bool {
        artifact.id.hasPrefix(localArtifactPrefix)
    }

    /// The roots the Files pane offers a chat: its own folder first, as
    /// `chat`, then the deployment's roots from `hello`, in their order.
    func fileRoots(for chat: Int) -> [Root] {
        var roots: [Root] = []
        if let folder = chats.first(where: { $0.chat == chat })?.folder {
            roots.append(Root(name: Self.chatRoot, path: folder))
        }
        for root in hello?.roots ?? [] where root.name != Self.chatRoot {
            roots.append(root)
        }
        return roots
    }

    /// The absolute directory a root name stands for, or `nil` for a name
    /// neither the chat nor `hello` offers.
    func rootPath(root: String, chat: Int) -> String? {
        fileRoots(for: chat).first { $0.name == root }?.path
    }

    /// The absolute path of `name` inside `path` under `root`; `nil` when
    /// the root is unknown.
    func absolutePath(chat: Int, root: String, path: String, name: String) -> String? {
        guard let base = rootPath(root: root, chat: chat) else { return nil }
        var url = URL(fileURLWithPath: base)
        if !path.isEmpty { url.appendPathComponent(path) }
        url.appendPathComponent(name)
        return url.path
    }

    /// The gateway's relative path of `name` inside `path`: `/`-joined,
    /// as the gateway normalises it, so the reply lands on the same key.
    static func childPath(_ path: String, _ name: String) -> String {
        path.isEmpty ? name : path + "/" + name
    }

    /// What the last `files.list` gave for a directory; `nil` until asked.
    func fileEntries(chat: Int, root: String, path: String) -> [Entry]? {
        fileTree[FilesKey(chat: chat, root: root, path: path)]
    }

    /// Ask the gateway for a directory's entries, once: a directory already
    /// listed, or with a request in flight, is not asked again (a refresh
    /// clears both).
    func listFiles(chat: Int, root: String, path: String) {
        let key = FilesKey(chat: chat, root: root, path: path)
        guard fileTree[key] == nil, !pendingFileLists.contains(key) else { return }
        pendingFileLists.insert(key)
        send(.filesList(FilesListRequest(root: root, path: path, chat: chat, id: Self.requestId())))
    }

    /// Drop the chat's tree so every expanded directory is listed afresh.
    func refreshFiles(chat: Int) {
        fileTree = fileTree.filter { $0.key.chat != chat }
        pendingFileLists = pendingFileLists.filter { $0.chat != chat }
    }

    /// Show a file from the Files pane in the viewer, as a local artifact:
    /// no gateway round trip, the media from the extension the way the
    /// gateway maps it, listed once in the chat's history, and the viewer
    /// column brought back if it was collapsed.
    func openArtifact(file path: String, in chat: Int) {
        let id = Self.localArtifactPrefix + path
        let artifact = Artifact(
            id: id, kind: .file, location: path, media: Media.of(path: path),
            title: URL(fileURLWithPath: path).lastPathComponent, source: .text, open: true)
        var list = artifacts[chat] ?? []
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index] = artifact
        } else {
            list.append(artifact)
        }
        artifacts[chat] = list
        current[chat] = artifact
        viewerVisible = true
    }
}

extension Media {
    /// The media kind the gateway would give a path, by extension
    /// (`artifacts.MEDIA_BY_EXTENSION`); anything else is `other`.
    static func of(path: String) -> Media {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "svg": .image
        case "html", "htm": .html
        case "pdf": .pdf
        case "txt": .text
        default: .other
        }
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
        self.client = client
        self.supervisor = supervisor
        loopRunning = true
        outbound = { message in
            Task { try? await client.send(message) }
        }
        defer {
            outbound = nil
            loopRunning = false
            self.client = nil
            Task { await client.disconnect() }
        }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            supervisor.tokenOverride = Self.tokenOverride(settings.tokenFile)
            connection = .connecting
            guard let endpoint = await endpoint(supervisor: supervisor, settings: settings) else {
                // Nothing to attach to. With automatic start off this is
                // the quiet state after Stop, not a failure.
                connection = autoStartGateway ? .failed(supervisor.statusText) : .disconnected
                await pause(backoff)
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
            await pause(backoff)
            backoff = min(backoff * 2, .seconds(10))
        }
    }

    /// Sleep between attempts, early-out on `startGateway`.
    private func pause(_ duration: Duration) async {
        let waiter: Task<Void, Never> = Task { try? await Task.sleep(for: duration) }
        reconnectWait = waiter
        await waiter.value
        if reconnectWait == waiter { reconnectWait = nil }
    }

    /// The token file the settings name, as a URL; `nil` for the default.
    static func tokenOverride(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
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
        guard autoStartGateway, let started = try? await supervisor.start() else { return nil }
        return (URL(string: "ws://127.0.0.1:\(started.port)")!, started.token)
    }
}

// MARK: - Gateway lifecycle from the app

extension AppModel {
    /// Stop the gateway: `gateway.stop` through the socket (the gateway
    /// interrupts every turn, runs the deployment's stop command, closes
    /// the socket and exits), then wait up to `timeout` for the socket to
    /// close. Returns whether it did. Automatic start is off afterwards,
    /// so the loop does not bring the gateway straight back; Start turns
    /// it on again. Not connected: nothing to tell, nothing to wait for.
    @discardableResult
    func stopGateway(timeout: Duration = .seconds(10)) async -> Bool {
        autoStartGateway = false
        guard connection == .connected else {
            supervisor?.noteStopped()
            return true
        }
        send(.gatewayStop(GatewayStop()))
        let closed = await waitForDisconnect(timeout)
        if closed { supervisor?.noteStopped() }
        return closed
    }

    /// Start (or attach to) a gateway: automatic start goes back on and
    /// the connection loop is woken; without a loop (no window open) the
    /// supervisor is started directly and the next loop attaches to it.
    func startGateway() {
        autoStartGateway = true
        if loopRunning {
            reconnectWait?.cancel()
        } else if let supervisor {
            Task { _ = try? await supervisor.start() }
        }
    }

    /// What quitting does to the gateway (spec §5.5, D19): keep it running
    /// (the default: the app only detaches) or stop everything and wait
    /// for the socket to close, up to `timeout`.
    func prepareToQuit(behaviour: Settings.QuitBehaviour, timeout: Duration = .seconds(10)) async {
        switch behaviour {
        case .keepRunning:
            return
        case .stopEverything:
            await stopGateway(timeout: timeout)
        }
    }

    private func waitForDisconnect(_ timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while connection == .connected {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

extension GatewaySupervisor {
    /// One line for the status strip.
    var statusText: String {
        StatusStripPresentation.gatewayText(status)
    }
}
