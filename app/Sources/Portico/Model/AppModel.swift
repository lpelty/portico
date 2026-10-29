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
    /// What became of this use's permission (v0.3): drawn at the row's end.
    var permission: PermissionOutcome? = nil
    /// The person's note on a decline, drawn under the row.
    var note: String? = nil
    /// The gateway cancelled this use's permission card before anyone
    /// answered it (its reason): the row says so instead of an outcome.
    var unanswered: String? = nil
    /// When the use last moved: its start's `ts`, then its finish's (v0.4:
    /// "Changed this session" shows when a file last changed).
    var at: String? = nil

    var id: String { toolUseId }
}

/// A turn ended. Kept in the model; the conversation draws a note only
/// under a stopped or failed turn (v0.4: no rule between turns).
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
    /// The engine summarized earlier conversation to make room (`chat.compacted`).
    case compacted(id: String, trigger: String)
    /// A quiet line from the gateway (`chat.notice`), e.g. an unknown command.
    case notice(id: String, text: String)

    var id: String {
        switch self {
        case .userText(let u): "user:\(u.turn):\(u.text.hashValue)"
        case .assistantText(let id, _): "assistant:\(id)"
        case .tool(let row): "tool:\(row.toolUseId)"
        case .card(let card): "card:\(card.id)"
        case .turnMarker(let marker): "turn:\(marker.turn)"
        case .compacted(let id, _): "compacted:\(id)"
        case .notice(let id, _): "notice:\(id)"
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
    /// The chat shown in the conversation pane. Showing another ends focus.
    @Published var selected: Int? {
        didSet {
            if let focus = viewerFocus, focus.chat != selected { endFocus() }
            if selected != nil { conversationShown = true }
            if let selected, selected == heldViewer { applyViewerRestore(chat: selected) }
        }
    }
    /// The first `chat.list` of this run has arrived (v0.6). Until then the
    /// main column draws nothing rather than a welcome that may change
    /// (`MainScreen`). A reconnect does not reset it.
    @Published private(set) var chatsListed = false
    /// A conversation has been shown in this run (v0.6): from then on, no
    /// selection means the live session, not the welcome.
    private(set) var conversationShown = false
    /// Per chat, what the conversation pane renders.
    @Published private(set) var transcripts: [Int: [TranscriptItem]] = [:]
    /// Per chat, the cards still waiting for an answer, in arrival order.
    @Published private(set) var openCards: [Int: [CardAsk]] = [:]
    /// Per chat, every artifact reported, oldest first, one per id.
    @Published private(set) var artifacts: [Int: [Artifact]] = [:]
    /// Per chat, the artifact the viewer shows: the last one that
    /// auto-opened or that the person picked from the history.
    @Published private(set) var current: [Int: Artifact] = [:]
    /// Per chat, whether the person collapsed or opened the viewer column
    /// by hand. Unset, the column follows the chat: shown when something is
    /// set to show, hidden otherwise (`isViewerShown`). An auto-open
    /// or a pick from the history opens it again.
    @Published private(set) var viewerVisible: [Int: Bool] = [:]
    /// Whether the sidebar column (chats and files) is shown.
    @Published var sidebarVisible: Bool = true
    /// Focus (V3): the viewer has most of the window and the sidebar is
    /// hidden; holds what to put back. Not remembered across launches.
    @Published private(set) var viewerFocus: ViewerFocus?

    struct ViewerFocus: Equatable, Sendable {
        var chat: Int
        var sidebarWasVisible: Bool
    }
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
    @Published private(set) var connection: ConnectionState = .disconnected {
        didSet { if gaveUpConnecting { gaveUpBeforeList = true } }
    }
    /// The connection gave up before the first `chat.list`: the welcome
    /// keeps saying "Not connected" through each retry's `connecting`,
    /// rather than flipping to a blank column and back, until a list comes.
    @Published private(set) var gaveUpBeforeList = false
    /// The gateway's config file changed after it started (`hello.config_stale`,
    /// `config.stale`): Settings and the strip offer a restart.
    @Published private(set) var configStale = false
    /// A restart (stop, then start) is under way.
    @Published private(set) var restarting = false
    /// The version the deployment's update check found (`update.available`).
    @Published private(set) var updateVersion: String?
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
    /// Per directory, the gateway's refusal of its last `files.list`
    /// (`files.outside_root` for a link that leaves the root, say), shown
    /// in the directory's row instead of a listing; cleared when it is asked for again.
    @Published private(set) var fileListErrors: [FilesKey: String] = [:]

    // MARK: v0.2 — sessions, context, files

    /// Per chat, the latest `context.usage`: the percent for the card and
    /// the strip, and the model's name for the strip.
    @Published private(set) var contextUsage: [Int: ContextUsage] = [:]
    /// The model named by the most recent `context.usage` in any chat (its
    /// display name when the deployment gives one): the deployment's model
    /// does not change when a session is renewed.
    @Published private(set) var latestModel: String?
    /// Per chat, the id of a `session.renew` the gateway has not answered:
    /// the card shows it busy and the composer waits.
    @Published var renewing: [Int: String] = [:]
    /// Per chat, the id of a `session.log` the gateway has not answered
    /// (v0.4): the card says "Logging…" and sends wait, as for a renewal.
    @Published var logging: [Int: String] = [:]
    /// The session whose New is asking "Log Session N first?" (W2).
    @Published var askingToLog: Int?
    /// The deployment's services from the latest `services.status`; `nil`
    /// until the first one on this connection ("Checking…").
    @Published var services: [Service]?
    /// Restarts sent and not yet answered by a `services.status`: service
    /// id → request id.
    @Published var restartingServices: [String: String] = [:]
    /// Per restarting service, how it was when Restart was pressed: only a
    /// status that moves it (to `checking`, or another state or detail)
    /// answers that restart.
    var restartBaselines: [String: Service] = [:]
    /// Per service, the id of its last `service.restart`, kept after a
    /// status ends the spinner: an `error` for it comes after that status.
    var lastRestartIds: [String: String] = [:]
    /// Per service, the gateway's reason its last restart failed (an
    /// `error` with its id), shown under the row until the next try.
    @Published var restartErrors: [String: String] = [:]
    /// The `services.restart_all` sent and not yet answered (v0.8 decision
    /// 4): its request id. The menu's Restart all services spins meanwhile.
    @Published var restartingAll: String?
    /// The id of the last `services.restart_all`, kept after the status that
    /// answers it ends the spinner: the gateway sends that status first and
    /// then, when the restart failed, the `error` carrying this id.
    var lastRestartAllId: String?
    /// The gateway's reason the last Restart all services failed (an
    /// `error` with its id), shown under it in the menu until the next try.
    @Published var restartAllError: String?
    /// The gateway or services action asking first (v0.8 decisions 3, 4).
    @Published var confirming: GatewayConfirmation?
    /// After a `chat.list`, gives up waiting for the first `services.status`
    /// (a gateway that sends none): the Gateway row alone, not "Checking…".
    var servicesFallback: Task<Void, Never>?
    /// How long `servicesFallback` waits.
    var servicesFallbackDelay: Duration = .seconds(5)
    /// Chats whose nudge (S2) the person put off with "Not now".
    @Published var nudgeDismissed: Set<Int> = []
    /// The Files pane's switch (F1 Folder, F2 Bookmarks).
    @Published var filesTab: FilesTab = .folder
    /// The quick-open palette (F4) is showing.
    @Published var quickOpenShown = false
    /// The document view (F3) replaces the conversation and the viewer.
    @Published var documentMode = false
    /// The file the document view shows (absolute path).
    @Published var documentFile: String?
    /// The document view's text search: the query, the hits so far, and
    /// the `files.search` requests (one per root) still out.
    @Published var fileSearch: FileSearch?
    /// The tab to go back to when the document view closes.
    var filesTabBeforeDocument: FilesTab?

    enum FilesTab: String, Sendable { case folder, bookmarks }

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
        /// Sent while the chat's `chat.open` was unanswered, on the same
        /// connection: the gateway answers in order, so that open's
        /// history cannot hold this send, and a replay keeps it in flight.
        var afterOpen: Bool = false
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
    /// Per `chat.new` request id, the first message to send once the
    /// gateway answers with the new chat (the start screen's Send).
    private var pendingStarts: [String: PendingStart] = [:]

    struct PendingStart: Equatable {
        var text: String
        var attachments: [String]
        var folder: URL
    }

    // MARK: - start screen state (no chat selected)

    /// What is typed on the start screen.
    @Published var startDraft: String = ""
    /// Files attached on the start screen, sent with the first message.
    @Published private(set) var startAttachments: [String] = []
    /// The permission mode the start screen's chip picked for the next
    /// session; applied with `session.mode` once the gateway makes it.
    @Published var startMode: PermissionMode?
    /// Per chat, when the running turn started (its `turn.started` stamp):
    /// the working line's elapsed time.
    @Published private(set) var turnStartedAt: [Int: Date] = [:]
    /// The folder the next chat starts in; `nil` means the default
    /// (`defaultStartFolder`). Set by the folder chip.
    @Published var chosenStartFolder: URL?
    /// Why the last start was refused (the gateway's message), shown under the composer.
    @Published private(set) var startError: String?
    /// Per chat, the turn the last delta belonged to, for coalescing.
    private var currentTurn: [Int: Int] = [:]
    /// Per chat and tool use, a permission outcome that arrived before the
    /// tool's row did (a card answered ahead of `tool.started`): drawn on
    /// the row when it starts.
    private var pendingOutcomes: [Int: [String: PermissionDecision]] = [:]

    /// A permission outcome with the note that went with it.
    struct PermissionDecision: Equatable, Sendable {
        var outcome: PermissionOutcome
        var note: String?
    }
    /// Per chat, the one send in flight (a second is refused `chat.busy`).
    private(set) var pendingSends: [Int: PendingSend] = [:]
    /// The artifact to put back in a chat's viewer when it is listed: the
    /// one showing when the app last quit (v0.6, `restoreViewerAtLaunch`).
    private var launchViewer: [Int: String] = [:]
    /// The launch's viewer rule has been applied (once per run).
    private var launchViewerDecided = false
    /// The session whose remembered viewer waits for its conversation
    /// (v0.8 decision 1): the welcome stands alone, and the artifact comes
    /// back when the person goes into the conversation.
    private(set) var heldViewer: Int?
    /// Per chat, the id of the artifact that was on screen when a replay
    /// from the beginning reset the list; put back when it is re-listed.
    private var restoreCurrent: [Int: String] = [:]
    /// The `files.list` requests in flight, by request id: the directory
    /// each asked for, so an expand asks once and the reply (or the error)
    /// lands on the directory as requested, whatever path the gateway
    /// echoes (a symlinked directory comes back under its resolved path).
    private(set) var pendingFileLists: [String: FilesKey] = [:]
    private var nextItemId = 0
    /// Ordering for status lines: per chat and chat-less, the strip shows
    /// whichever `status.set` (or error) came last.
    private var statusStamps: [Int: Int] = [:]
    private var gatewayStatusStamp = 0
    private var statusClock = 0
    /// Per chat, the relist of its folder waiting out `relistDelay` (v0.6).
    private var relistTasks: [Int: Task<Void, Never>] = [:]
    /// How long a write waits for the next before the folder is listed
    /// again: a turn of twenty edits lists it once.
    var relistDelay: Duration = .milliseconds(400)
    /// The connection loop's pause between attempts; `startGateway` cancels it.
    private var reconnectWait: Task<Void, Never>?
    /// Another window attached to this gateway and it closed this one
    /// (`error code=session.replaced`): the loop stops retrying, or the two
    /// windows would take the gateway from each other forever, until Start.
    private(set) var replacedElsewhere = false
    static let replacedCode = "session.replaced"
    static let replacedText = "Another Portico window is using this gateway. Agent › Start brings it back here."
    /// The loop's socket, while `run` is going; `stopGateway` closes it.
    private var client: GatewayClient?
    /// Whether `run` is going (the window is open).
    private var loopRunning = false

    /// The supervisor the app uses: set by `run`, and by the app at launch
    /// so Start works from the settings window before the main window's
    /// loop (or after it closed).
    weak var supervisor: GatewaySupervisor?

    /// The auto-open settings the reducer consults (spec §5.3), and the
    /// gateway address override a stop without a socket looks at.
    let settings: Settings

    /// What the app says it is in `hello`; the app sets it at launch, and
    /// `run` again, so a stop without the loop's socket can attach too.
    var appVersion: String = "0.0.0-dev"

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
        // A send still in flight went out before the opens below: their
        // replays may hold it (or the old connection lost it).
        for chat in Array(pendingSends.keys) { pendingSends[chat]?.afterOpen = false }
        hello = incoming
        var frames: [ClientMessage] = openedChats.sorted().map { chat in
            .chatOpen(ChatOpen(chat: chat, since: lastSeq[chat], id: Self.requestId()))
        }
        // A listing in flight when the socket went away was never answered
        // (or its answer was lost with the socket): ask for each directory
        // again, under a new id, so its row does not say "Listing…" until
        // a refresh.
        let unanswered = Set(pendingFileLists.values)
        pendingFileLists = [:]
        for key in unanswered.sorted(by: { ($0.chat, $0.root, $0.path) < ($1.chat, $1.root, $1.path) }) {
            frames.append(filesListRequest(for: key))
        }
        return frames
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
            // Each gateway says afresh: a restarted one has read the config.
            configStale = hello.configStale ?? false
            // Services are checked afresh too: "Checking…" until it says.
            // A gateway older than v0.4 never will: the Gateway row alone.
            services = Self.gatewaySendsServices(hello.gatewayVersion) ? nil : []
            restartingServices = [:]
            restartBaselines = [:]
            lastRestartIds = [:]
            restartErrors = [:]
            restartingAll = nil
            lastRestartAllId = nil
            restartAllError = nil
            servicesFallback?.cancel()
            servicesFallback = nil
            // A log or renewal sent on the old connection was never
            // answered (or its answer was lost with it); the `chat.list`
            // that follows says how each session is now.
            logging = [:]
            renewing = [:]
            for frame in handleHello(hello) {
                if case .chatOpen(let open) = frame {
                    pendingOpenSince[open.chat] = open.since
                    live.remove(open.chat)
                }
                send(frame)
            }

        case .chatList(let list):
            chats = list.chats
            chatsListed = true
            gaveUpBeforeList = false
            if let selected, !list.chats.contains(where: { $0.chat == selected }) {
                self.selected = nil
            }
            for chat in Array(openedChats) where !list.chats.contains(where: { $0.chat == chat }) {
                forget(chat: chat)
            }
            openLiveSessionIfNeeded()
            awaitServicesStatus()

        case .chatState(let state):
            if let index = chats.firstIndex(where: { $0.chat == state.chat }) {
                chats[index].state = state.state
                if let mode = state.mode { chats[index].mode = mode }
                if let unlogged = state.unlogged { chats[index].unlogged = unlogged }
            }
            if let id = state.id, pendingNewChats.remove(id) != nil {
                // The new session runs in what the start screen's chip
                // showed: the pick, else the deployment's mode. Should the
                // gateway have started it in another, say so now.
                let wanted = startModeShown
                startMode = nil
                if let mode = state.mode, wanted != mode {
                    send(.sessionMode(SessionMode(chat: state.chat, mode: wanted, id: Self.requestId())))
                }
                open(chat: state.chat)
                if let start = pendingStarts.removeValue(forKey: id) {
                    dispatch(chat: state.chat, text: start.text, attachments: start.attachments, fromComposer: true)
                }
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
            // A direct answer (`id`, no seq) to the Files pane's request,
            // filed under the directory that was asked for: the gateway
            // echoes the path it resolved, which for a symlinked directory
            // is the target's, and the tree's rows are the names as listed.
            // A reply to a request no longer waited for (a refresh dropped
            // it) is stale and goes nowhere.
            if let id = list.id, let key = pendingFileLists.removeValue(forKey: id) {
                fileTree[key] = list.entries
                fileListErrors[key] = nil
            } else if list.id == nil, let chat = list.chat {
                fileTree[FilesKey(chat: chat, root: list.root, path: list.path)] = list.entries
            }

        case .statusSet(let status):
            if let chat = status.chat {
                setStatus(status.text, for: chat)
            } else {
                gatewayStatus = status.text
                gatewayStatusStamp = nextStatusStamp()
            }
            noteSeq(of: message)

        case .contextUsage(let usage):
            contextUsage[usage.chat] = usage
            if let name = usage.displayModel { latestModel = name }
            noteSeq(of: message)

        case .sessionRenewed(let renewed):
            applyRenewed(renewed)

        case .sessionLogged(let logged):
            applyLogged(logged)

        case .servicesStatus(let status):
            servicesFallback?.cancel()
            servicesFallback = nil
            applyServicesStatus(status)

        case .filesResults(let results):
            applySearchResults(results)

        case .configStale:
            configStale = true

        case .updateAvailable(let update):
            updateVersion = update.version

        case .error(let error):
            lastError = error
            if error.code == Self.replacedCode { replacedElsewhere = true }
            // A refused renew: the card is no longer busy; the status line
            // (below) carries the gateway's reason like any other error.
            if let id = error.id, let chat = renewing.first(where: { $0.value == id })?.key {
                renewing[chat] = nil
            }
            // A refused log or restart: likewise no longer pending.
            if let id = error.id, let chat = logging.first(where: { $0.value == id })?.key {
                logging[chat] = nil
            }
            // A refused or failed row restart: the row says why (v0.8), even
            // when a status already ended its spinner.
            if let id = error.id, let service = lastRestartIds.first(where: { $0.value == id })?.key {
                restartingServices[service] = nil
                restartBaselines[service] = nil
                lastRestartIds[service] = nil
                restartErrors[service] = error.message
            }
            // A failed Restart all services (v0.8 decision 4): the menu says
            // why. The gateway's status comes first and ends the spinner, so
            // the error is matched against the last request, not the pending one.
            if let id = error.id, id == lastRestartAllId {
                restartingAll = nil
                lastRestartAllId = nil
                restartAllError = error.message
            }
            if let id = error.id, fileSearch?.pending[id] != nil {
                fileSearch?.pending[id] = nil
            }
            // A refused start: the chat was never made, so the words and
            // files go back on the start screen with the gateway's reason.
            if let id = error.id, let start = pendingStarts.removeValue(forKey: id) {
                pendingNewChats.remove(id)
                startDraft = startDraft.isEmpty ? start.text : start.text + "\n" + startDraft
                startAttachments = start.attachments + startAttachments.filter { !start.attachments.contains($0) }
                startError = error.message
            }
            if let chat = error.chat {
                setStatus(error.message, for: chat)
                if let id = error.id, let pending = pendingSends[chat], pending.id == id {
                    restore(pending, to: chat)
                }
            }
            // A refused listing: the directory is no longer pending (so it
            // can be asked for again) and its row shows the refusal.
            if let id = error.id, let key = pendingFileLists.removeValue(forKey: id) {
                fileListErrors[key] = error.message
            }

        case .turnStarted, .userText, .textDelta, .toolStarted, .toolFinished, .turnFinished, .cardAsk, .cardAnswered, .cardCancel,
            .chatCompacted, .chatNotice:
            guard let chat = message.envelope.chat else { return }
            // A sequenced event we already hold (a re-sent card, a ring
            // overlap) is not applied twice; the card case de-duplicates by
            // id as well, for frames that arrive without a seq.
            if let seq = message.envelope.seq, let seen = lastSeq[chat], seq <= seen, !isCard(message) {
                return
            }
            applyEvent(message, to: chat)
            noteSeq(of: message)
            // A turn that ended in an error before the agent said or did
            // anything (its engine could not start) is not a reply (v0.7).
            if case .turnFinished(let finished) = message,
                finished.outcome != .error || turnHadAgentOutput(chat: chat, turn: finished.turn)
            {
                noteLastReply(chat: chat, at: finished.ts)
            }
            if FolderRelist.triggers(message, tool: { toolName(chat: chat, toolUseId: $0) }) {
                scheduleRelist(chat: chat)
            }
        }
    }

    /// A live turn finished: the session's last reply is now (the welcome's
    /// line), without waiting for the next `chat.list`. Only live frames:
    /// a replay's `ts` is the time of the replay.
    private func noteLastReply(chat: Int, at ts: String) {
        guard let index = chats.firstIndex(where: { $0.chat == chat }) else { return }
        chats[index].lastReply = ts
    }

    /// Whether the transcript holds anything from the agent (text, a tool,
    /// a card) between turn `turn`'s echo and its finish marker.
    func turnHadAgentOutput(chat: Int, turn: Int) -> Bool {
        let items = transcripts[chat] ?? []
        var index = items.endIndex
        if case .turnMarker(let marker)? = items.last, marker.turn == turn { index -= 1 }
        while index > items.startIndex {
            index -= 1
            switch items[index] {
            case .assistantText, .card: return true
            case .tool(let row): if row.turn == turn { return true }
            case .userText(let user): if user.turn == turn { return false }
            case .turnMarker: return false
            case .compacted, .notice: continue
            }
        }
        return false
    }

    /// The tool a row started with, by its use id.
    func toolName(chat: Int, toolUseId: String) -> String? {
        guard let index = Self.toolIndex(toolUseId, in: transcripts[chat] ?? []),
            case .tool(let row) = transcripts[chat]?[index]
        else { return nil }
        return row.tool
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
        let kept = pendingSends[chat].flatMap { $0.afterOpen ? $0 : nil }
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
            turnStartedAt[chat] = nil
            pendingOutcomes[chat] = nil
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
        // Except a send made while this open was out (the welcome's first
        // message at launch): the gateway answered the open first, so the
        // replay's `user.text`s are older turns; the send's own echo, or
        // its refusal, is still to come.
        if let kept { pendingSends[chat] = kept }
    }

    /// The per-event reducer shared by live frames and a history replay.
    private func applyEvent(_ event: ServerMessage, to chat: Int) {
        var items = transcripts[chat] ?? []
        defer { transcripts[chat] = items }

        switch event {
        case .turnStarted(let started):
            currentTurn[chat] = started.turn
            turnStartedAt[chat] = SessionTime.parse(started.ts) ?? Date()

        case .userText(let user):
            // The gateway's echo is the bubble, live or replayed; the send
            // that started this turn has been accepted and owes nothing more.
            currentTurn[chat] = user.turn
            items.append(.userText(user))
            pendingSends[chat] = nil
            // The gateway records a session's title from its first message but
            // only says so in the next chat.list; take it from the echo now.
            if let index = chats.firstIndex(where: { $0.chat == chat }), chats[index].title == nil {
                chats[index].title = SessionPresentation.title(from: user.text)
            }

        case .textDelta(let delta):
            if case .assistantText(let id, let text)? = items.last, currentTurn[chat] == delta.turn {
                items[items.count - 1] = .assistantText(id: id, text: text + delta.text)
            } else {
                currentTurn[chat] = delta.turn
                items.append(.assistantText(id: Self.itemId(&nextItemId), text: delta.text))
            }

        case .toolStarted(let started):
            currentTurn[chat] = started.turn
            var row = ToolRow(
                toolUseId: started.toolUseId, turn: started.turn, tool: started.tool,
                summary: started.summary, input: started.input, at: started.ts)
            if let decision = pendingOutcomes[chat]?.removeValue(forKey: row.toolUseId) {
                row.permission = decision.outcome
                row.note = decision.note
            }
            if let index = items.lastIndex(where: { if case .tool(let r) = $0 { return r.toolUseId == row.toolUseId } else { return false } }) {
                // A re-sent start keeps what was already drawn on the row.
                if case .tool(let old) = items[index] {
                    row.permission = row.permission ?? old.permission
                    row.note = row.note ?? old.note
                    row.unanswered = old.unanswered
                    row.at = old.at ?? row.at
                }
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
                row.at = finished.ts
                if let permission = finished.permission {
                    row.permission = permission
                    row.note = finished.note ?? row.note
                }
                items[index] = .tool(row)
            } else {
                // The start fell off the ring; show the finish rather than lose it.
                items.append(.tool(ToolRow(
                    toolUseId: finished.toolUseId, turn: finished.turn, tool: "tool", summary: finished.summary,
                    input: [:], finished: true, ok: finished.ok, result: finished.summary,
                    permission: finished.permission, note: finished.note, at: finished.ts)))
            }

        case .turnFinished(let finished):
            items.append(.turnMarker(TurnMarker(turn: finished.turn, outcome: finished.outcome)))
            if currentTurn[chat] == finished.turn { currentTurn[chat] = nil }
            turnStartedAt[chat] = nil

        case .cardAsk(let card):
            var open = openCards[chat] ?? []
            if open.contains(where: { $0.id == card.id }) { break }
            // The gateway sends a card only while it holds it open, and
            // re-sends every open card on chat.open. A card this app marked
            // answered that comes back can only mean the answer never
            // reached the gateway (a send is fire-and-forget, and the
            // gateway forgets a card the moment it accepts an answer): the
            // card is open again, pinned again, for the person to answer
            // once more. A cancel is the gateway's own word and stands.
            if let why = closedCards[chat]?[card.id], why != Self.answeredMarker { break }
            closedCards[chat]?[card.id] = nil
            open.append(card)
            openCards[chat] = open
            // V1: a permission card is one unit with its tool row — pinned
            // above the composer while open, its outcome drawn on the row
            // after. It leaves no copy of its own in the transcript. Other
            // cards keep their inline record.
            if card.kind != .permission {
                let inline = TranscriptItem.card(card)
                if !items.contains(where: { $0.id == inline.id }) {
                    items.append(inline)
                }
            }

        case .cardAnswered(let answered):
            // The gateway accepted an answer (ours, or one given before a
            // relaunch and now replayed): the card is closed either way.
            let asked = openCards[chat]?.first { $0.id == answered.id }
            closeCard(chat: chat, id: answered.id, why: Self.answeredMarker)
            if let outcome = answered.outcome, let toolUseId = answered.toolUseId ?? asked?.toolUseId {
                record(PermissionDecision(outcome: outcome, note: answered.note), on: toolUseId, in: &items, chat: chat)
            }

        case .cardCancel(let cancel):
            let asked = openCards[chat]?.first { $0.id == cancel.id }
            let reason = cancel.reason ?? "cancelled"
            closeCard(chat: chat, id: cancel.id, why: reason)
            if asked?.kind == .permission, let toolUseId = asked?.toolUseId,
                let index = Self.toolIndex(toolUseId, in: items), case .tool(var row) = items[index], row.permission == nil
            {
                row.unanswered = reason
                items[index] = .tool(row)
            }

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
            } else if launchViewer[chat] == artifact.id {
                // The artifact that was showing when the app quit (v0.6).
                current[chat] = artifact
                viewerVisible[chat] = true
            } else if restoreCurrent[chat] == artifact.id {
                current[chat] = artifact
            }
            if restoreCurrent[chat] == artifact.id { restoreCurrent[chat] = nil }
            if launchViewer[chat] == artifact.id { launchViewer[chat] = nil }

        case .chatCompacted(let compacted):
            items.append(.compacted(id: Self.itemId(&nextItemId), trigger: compacted.trigger))

        case .chatNotice(let notice):
            items.append(.notice(id: Self.itemId(&nextItemId), text: notice.text))

        case .hello, .chatList, .chatState, .chatHistory, .chatLive, .filesList, .statusSet, .error,
            .contextUsage, .sessionRenewed, .filesResults, .configStale, .updateAvailable, .sessionLogged, .servicesStatus:
            break
        }
    }

    static func toolIndex(_ toolUseId: String, in items: [TranscriptItem]) -> Int? {
        items.lastIndex { if case .tool(let row) = $0 { row.toolUseId == toolUseId } else { false } }
    }

    /// Draw a permission outcome on its tool row, or hold it for the row
    /// when the row has not started yet.
    private func record(_ decision: PermissionDecision, on toolUseId: String, in items: inout [TranscriptItem], chat: Int) {
        if let index = Self.toolIndex(toolUseId, in: items), case .tool(var row) = items[index] {
            row.permission = decision.outcome
            row.note = decision.note ?? (decision.outcome == .declined ? row.note : nil)
            row.unanswered = nil
            items[index] = .tool(row)
        } else {
            pendingOutcomes[chat, default: [:]][toolUseId] = decision
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
        guard let card = pinnedCards(for: answer.chat).first(where: { $0.id == answer.id }) else { return }
        send(.cardAnswer(answer))
        closeCard(chat: answer.chat, id: answer.id, why: Self.answeredMarker)
        // The row shows the answer at once; the gateway's `card.answered`
        // (and the tool's finish) confirm it.
        if card.kind == .permission, let toolUseId = card.toolUseId, let decision = Self.decision(for: answer) {
            var items = transcripts[answer.chat] ?? []
            record(decision, on: toolUseId, in: &items, chat: answer.chat)
            transcripts[answer.chat] = items
        }
    }

    /// What a permission answer comes to on the tool row.
    static func decision(for answer: CardAnswer) -> PermissionDecision? {
        guard case .string(let word)? = answer.answer["decision"] else { return nil }
        if word == "deny" { return PermissionDecision(outcome: .declined, note: answer.note) }
        guard word == "allow" else { return nil }
        return PermissionDecision(outcome: answer.scope == .chat || answer.scope == .always ? .session : .once)
    }

    /// The open permission card that asks about this tool use, if any:
    /// its row reads "waiting for your OK" while it is open.
    func permissionCard(chat: Int, toolUseId: String) -> CardAsk? {
        openCards[chat]?.first { $0.kind == .permission && $0.toolUseId == toolUseId }
    }

    // MARK: - permission mode (V2)

    /// The session's permission mode as the gateway last said; `nil` from
    /// a gateway that does not speak modes (the chip is not shown).
    func mode(of chat: Int) -> PermissionMode? {
        summary(of: chat)?.mode
    }

    /// What the start screen's chip shows, and what the new session runs
    /// in: the pick, else the mode the deployment starts sessions in
    /// (`hello.permission_mode`), else the protocol's default. Never a mode
    /// some other session happened to report.
    var startModeShown: PermissionMode {
        startMode ?? hello?.permissionMode ?? .auto
    }

    /// Change the session's mode: `session.mode`, answered with a
    /// `chat.state` carrying the mode, which is what the chip then shows.
    func setMode(_ mode: PermissionMode, for chat: Int) {
        guard mode != self.mode(of: chat) else { return }
        send(.sessionMode(SessionMode(chat: chat, mode: mode, id: Self.requestId())))
    }

    // MARK: - working line (V2)

    /// What the working line says the agent is doing: the running tool
    /// (`Write Q3-synthesis.md`, its path relative to the chat's folder),
    /// else `Thinking`.
    func activity(for chat: Int) -> String {
        let folder = summary(of: chat)?.folder
        for item in (transcripts[chat] ?? []).reversed() {
            if case .tool(let row) = item, !row.finished {
                let what = ToolRowView.display(row.summary, in: folder)
                return what.isEmpty ? row.tool : "\(row.tool) \(what)"
            }
            if case .turnMarker = item { break }
            if case .userText = item { break }
        }
        return "Thinking"
    }

    /// The working line shows while a turn runs and nothing waits on the person.
    func showsWorkingLine(chat: Int) -> Bool {
        state(of: chat) == .working
    }

    /// `0:48`, `12:05`, `1:02:09`: how long the turn has run.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - viewer

    /// Put an artifact in the viewer, make sure the column is showing, and
    /// tell the gateway (`artifact.opened`, telemetry only). Used by the
    /// auto-open rule and by a pick from the history list.
    func show(_ artifact: Artifact, in chat: Int) {
        current[chat] = artifact
        viewerVisible[chat] = true
        send(.artifactOpened(ArtifactOpened(chat: chat, artifactId: artifact.id, id: Self.requestId())))
    }

    /// At launch, the viewer of the session the window opens on comes back
    /// only if it was showing an artifact when the app quit, on that
    /// artifact (`ViewerRestore`); otherwise it starts closed, rather than
    /// open on nothing. Once per run, before the chat's events arrive.
    ///
    /// The welcome is shown on its own (v0.8 decision 1): the viewer stays
    /// closed while it shows, and the restore is held until the session's
    /// conversation is (View Session N, a send from the welcome, or picking
    /// the session), when `selected` becomes the chat.
    func restoreViewerAtLaunch(chat: Int) {
        guard !launchViewerDecided else { return }
        launchViewerDecided = true
        viewerVisible[chat] = false
        guard ViewerRestore.artifact(saved: settings.viewerAtQuit, chat: chat) != nil else { return }
        if selected == chat {
            applyViewerRestore(chat: chat)
        } else {
            heldViewer = chat
        }
    }

    /// Put the remembered artifact back in `chat`'s viewer: at once when it
    /// is already listed (the welcome loaded the session's events), else
    /// when it is (`launchViewer`).
    private func applyViewerRestore(chat: Int) {
        heldViewer = nil
        guard let id = ViewerRestore.artifact(saved: settings.viewerAtQuit, chat: chat) else { return }
        if id.hasPrefix(Self.localArtifactPrefix) {
            // A file opened from the Files pane: the gateway never lists
            // it, so it is opened again here, if it is still there.
            let path = String(id.dropFirst(Self.localArtifactPrefix.count))
            if FileManager.default.fileExists(atPath: path) { openArtifact(file: path, in: chat) }
        } else if let listed = artifacts[chat]?.first(where: { $0.id == id }) {
            current[chat] = listed
            viewerVisible[chat] = true
        } else {
            launchViewer[chat] = id
        }
    }

    /// What the viewer shows now, worth reopening at the next launch: an
    /// artifact in the shown chat's open viewer; `nil` when it is closed
    /// or empty, or the document view has the window.
    var viewerToRemember: SavedViewer? {
        guard !documentMode, let chat = shownChat, isViewerShown(for: chat), let artifact = current[chat] else { return nil }
        return SavedViewer(chat: chat, artifact: artifact.id)
    }

    /// Called as the app quits: remember what the viewer shows (or that it
    /// shows nothing) for the next launch; quitting from the welcome keeps
    /// what was remembered (v0.8 decision 1).
    func rememberViewerForNextLaunch() {
        settings.viewerAtQuit = ViewerRestore.toRemember(
            showing: viewerToRemember, saved: settings.viewerAtQuit, held: heldViewer != nil)
    }

    /// The chat's artifacts, newest first, for the history list.
    func history(for chat: Int) -> [Artifact] {
        (artifacts[chat] ?? []).reversed()
    }

    /// The viewer column is there when the person opened it, or when an
    /// artifact is set to show and the person has not collapsed it. Stored
    /// artifacts alone (an earlier session's, a replay's, ones that did not
    /// auto-open) leave it closed rather than open on nothing (v0.6).
    func isViewerShown(for chat: Int) -> Bool {
        viewerVisible[chat] ?? (current[chat] != nil)
    }

    /// Open or collapse the viewer column for `chat` by hand. Collapsing
    /// it ends focus.
    func setViewer(visible: Bool, for chat: Int) {
        viewerVisible[chat] = visible
        if !visible, viewerFocus?.chat == chat { endFocus() }
    }

    /// Focus is on for the chat shown.
    func isFocused(chat: Int) -> Bool { viewerFocus?.chat == chat }

    /// The Focus button (⌘⇧↩): hide the sidebar and give the viewer most of
    /// the window; again, put the sidebar back as it was. The remembered
    /// column widths are never touched, so they come back exactly.
    func toggleFocus(chat: Int) {
        if viewerFocus != nil {
            endFocus()
        } else {
            viewerFocus = ViewerFocus(chat: chat, sidebarWasVisible: sidebarVisible)
            sidebarVisible = false
            viewerVisible[chat] = true
        }
    }

    func endFocus() {
        guard let focus = viewerFocus else { return }
        viewerFocus = nil
        sidebarVisible = focus.sidebarWasVisible
    }

    /// The artifacts menu's heading: `Made in this session` (or chat).
    var madeHereLabel: String {
        isSinglePresentation ? "Made in this session" : "Made in this chat"
    }

    // MARK: - sidebar actions

    /// Ask the gateway for a chat in `folder`; the reply selects it.
    /// Go to the start screen: no chat selected.
    func showStart() {
        selected = nil
    }

    /// The folder the start screen offers: the person's choice, else the
    /// folder the last chat started in (when it still exists), else the
    /// deployment's `default_folder`, else its first root. `nil` when there
    /// is nothing to offer.
    var startFolder: URL? {
        if let chosen = chosenStartFolder { return chosen }
        if let last = settings.lastFolder, Self.isDirectory(last) { return URL(fileURLWithPath: last) }
        if let folder = hello?.defaultFolder, Self.isDirectory(folder) { return URL(fileURLWithPath: folder) }
        if let root = hello?.roots.first, Self.isDirectory(root.path) { return URL(fileURLWithPath: root.path) }
        return nil
    }

    /// Folders the chip's menu lists: the last one used and the deployment's roots, de-duplicated.
    var startFolderChoices: [URL] {
        var paths: [String] = []
        if let last = settings.lastFolder, Self.isDirectory(last) { paths.append(last) }
        for root in hello?.roots ?? [] where Self.isDirectory(root.path) && !paths.contains(root.path) {
            paths.append(root.path)
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// A start is out and the gateway has not answered yet.
    var isStarting: Bool { !pendingStarts.isEmpty }

    /// Start a chat in the start folder and send `text` (with the start
    /// screen's attachments when `fromComposer`) as its first message, in
    /// one motion: `chat.new`, then on the reply `chat.open` and
    /// `message.send`. Nothing happens without a folder or with blank text.
    func startChat(text: String, fromComposer: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let folder = startFolder, !isStarting else { return }
        let id = Self.requestId()
        let attachments = fromComposer ? startAttachments : []
        pendingNewChats.insert(id)
        pendingStarts[id] = PendingStart(text: trimmed, attachments: attachments, folder: folder)
        startError = nil
        settings.lastFolder = folder.path
        chosenStartFolder = nil
        if fromComposer {
            startDraft = ""
            startAttachments = []
        }
        send(.chatNew(ChatNew(folder: folder.path, id: id)))
    }

    /// The welcome's Send while it continues the live session (Y1): show
    /// that session's conversation with the message in it, the welcome's
    /// files attached. `/new` and `/log` work as in the conversation. A
    /// message the session cannot take yet (a turn is running, or a send
    /// is in flight) waits in its composer instead of being lost. While the
    /// session is being logged or ended nothing goes: the welcome keeps it.
    func continueSession(chat: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSessionCommandPending(chat: chat) else { return }
        open(chat: chat)
        attach(startAttachments, to: chat)
        startAttachments = []
        startDraft = ""
        if isBusy(chat: chat) || isSending(chat: chat) {
            let typed = draft(for: chat)
            setDraft(typed.isEmpty ? trimmed : typed + "\n" + trimmed, for: chat)
        } else {
            sendMessage(chat: chat, text: trimmed)
        }
    }

    /// A suggestion on the welcome while it continues the live session:
    /// sent there, and its conversation shown.
    func continueSession(chat: Int, action text: String) {
        guard !isSessionCommandPending(chat: chat) else { return }
        open(chat: chat)
        sendAction(chat: chat, text: text)
    }

    /// Settings › Folder: the folder new sessions start in, from now on.
    func chooseStartFolder(_ folder: URL) {
        objectWillChange.send()
        settings.lastFolder = folder.path
        chosenStartFolder = nil
    }

    /// Queue files for the first message on the start screen.
    func attachToStart(_ paths: [String]) {
        for path in paths where !startAttachments.contains(path) {
            startAttachments.append(path)
        }
    }

    func detachFromStart(_ path: String) {
        startAttachments.removeAll { $0 == path }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

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
    ///
    /// A chat whose `chat.open` is still unanswered (the launch's load of
    /// the live session) is only shown: a second open would carry `since`
    /// from a live frame that came first, its history would be read as a
    /// catch-up, and the beginning of the conversation would be lost.
    func open(chat: Int) {
        selected = chat
        guard !isLoading(chat: chat) else { return }
        load(chat: chat)
    }

    /// A `chat.open` for the chat is out and its `chat.live` has not come.
    func isLoading(chat: Int) -> Bool {
        pendingOpenSince.keys.contains(chat)
    }

    /// Ask for a chat's events without showing it (`open` shows it too):
    /// the welcome loads the live session it continues this way (v0.6).
    func load(chat: Int) {
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
    ///
    /// In single presentation, `/new` alone is not sent: it does what the
    /// card's New does (S1's "Same as typing /new"), asking to log first
    /// when that would lose something (W2); `/log` alone logs the session
    /// without ending it, when the deployment can, and otherwise says why
    /// it cannot in a notice. `about` is the document
    /// view's open file, attached to the message along with the chips.
    func sendMessage(chat: Int, text: String, about: String? = nil) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == Self.renewCommand, canRenew(chat: chat) {
            guard !isSessionCommandPending(chat: chat) else { return }
            drafts[chat] = nil
            requestNew(chat: chat)
            return
        }
        if command == Self.logCommand, canLogSession(chat: chat) {
            guard !isSessionCommandPending(chat: chat) else { return }
            drafts[chat] = nil
            logSession(chat: chat)
            return
        }
        // `/log` where the session cannot be logged is not sent to the
        // agent as text: it gets the card's reason, as a notice.
        if command == Self.logCommand, let reason = logSessionOffReason(chat: chat) {
            drafts[chat] = nil
            appendNotice(reason, to: chat)
            return
        }
        var attachments = draftAttachments[chat] ?? []
        if let about, !attachments.contains(about) { attachments.append(about) }
        dispatch(chat: chat, text: text, attachments: attachments, fromComposer: true)
    }

    /// A notice the app itself puts in the transcript (not from the
    /// gateway, so a history replay from the beginning drops it).
    func appendNotice(_ text: String, to chat: Int) {
        var items = transcripts[chat] ?? []
        items.append(.notice(id: Self.itemId(&nextItemId), text: text))
        transcripts[chat] = items
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
        pendingSends[chat] = PendingSend(
            id: id, text: trimmed, attachments: attachments, fromComposer: fromComposer, afterOpen: isLoading(chat: chat))
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
        viewerVisible[chat] = nil
        restoreCurrent[chat] = nil
        launchViewer[chat] = nil
        if heldViewer == chat { heldViewer = nil }
        relistTasks[chat]?.cancel()
        relistTasks[chat] = nil
        status[chat] = nil
        statusStamps[chat] = nil
        closedCards[chat] = nil
        pendingOutcomes[chat] = nil
        live.remove(chat)
        pendingOpenSince[chat] = nil
        currentTurn[chat] = nil
        fileTree = fileTree.filter { $0.key.chat != chat }
        fileListErrors = fileListErrors.filter { $0.key.chat != chat }
        pendingFileLists = pendingFileLists.filter { $0.value.chat != chat }
        contextUsage[chat] = nil
        turnStartedAt[chat] = nil
        renewing[chat] = nil
        logging[chat] = nil
        if askingToLog == chat { askingToLog = nil }
        nudgeDismissed.remove(chat)
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

    /// Upsert one chat's record, keeping the list in chat order.
    func upsertSummary(_ summary: ChatSummary) {
        if let index = chats.firstIndex(where: { $0.chat == summary.chat }) {
            chats[index] = summary
        } else {
            chats.append(summary)
            chats.sort { $0.chat < $1.chat }
        }
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

    /// The roots to browse and list: `fileRoots` without the chat's own
    /// folder when a deployment root is that same folder, so it is not
    /// shown twice. Paths still resolve through `fileRoots`.
    func browsableRoots(for chat: Int) -> [Root] {
        let roots = fileRoots(for: chat)
        guard let own = roots.first(where: { $0.name == Self.chatRoot }) else { return roots }
        let ownPath = URL(fileURLWithPath: own.path).standardizedFileURL.path
        let shared = roots.contains { $0.name != Self.chatRoot && URL(fileURLWithPath: $0.path).standardizedFileURL.path == ownPath }
        return shared ? roots.filter { $0.name != Self.chatRoot } : roots
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

    /// The gateway's refusal of the directory's last listing, if it was
    /// refused; `nil` while it is listed, pending, or not asked for yet.
    func fileListError(chat: Int, root: String, path: String) -> String? {
        fileListErrors[FilesKey(chat: chat, root: root, path: path)]
    }

    /// Ask the gateway for a directory's entries, once: a directory already
    /// listed, or with a request in flight, is not asked again (a refresh
    /// clears both). A refused directory may be asked for again.
    func listFiles(chat: Int, root: String, path: String) {
        let key = FilesKey(chat: chat, root: root, path: path)
        guard fileTree[key] == nil, !pendingFileLists.values.contains(key) else { return }
        fileListErrors[key] = nil
        send(filesListRequest(for: key))
    }

    /// A `files.list` for the directory, remembered as pending under its id.
    private func filesListRequest(for key: FilesKey) -> ClientMessage {
        let id = Self.requestId()
        pendingFileLists[id] = key
        return .filesList(FilesListRequest(root: key.root, path: key.path, chat: key.chat, id: id))
    }

    /// Drop the chat's tree so every expanded directory is listed afresh.
    func refreshFiles(chat: Int) {
        fileTree = fileTree.filter { $0.key.chat != chat }
        fileListErrors = fileListErrors.filter { $0.key.chat != chat }
        pendingFileLists = pendingFileLists.filter { $0.value.chat != chat }
    }

    /// A write finished or a turn ended in `chat` (`FolderRelist`): list
    /// its folder again shortly, once for a burst of writes.
    func scheduleRelist(chat: Int) {
        guard offers("files") else { return }
        relistTasks[chat]?.cancel()
        let delay = relistDelay
        relistTasks[chat] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.relistTasks[chat] = nil
            self?.relistSessionFolder(chat: chat)
        }
    }

    /// List again the directories of the session's folder the Files pane
    /// has already listed, so a file the agent made appears without the
    /// refresh button. The old entries stay drawn until the new ones come
    /// (no "Listing…" flash), and nothing outside the folder is asked for.
    /// A chat whose files are not on screen just forgets those listings;
    /// they are asked for when it is shown.
    ///
    /// A directory whose listing is still out is asked for again: that
    /// listing may have been read before the write (each request has its
    /// own id, and the later answer lands last). A deployment root that
    /// holds the session's folder lists again the part inside the folder.
    func relistSessionFolder(chat: Int) {
        let scopes = sessionFolderScopes(chat: chat)
        let keys = fileTree.keys.filter { key in
            guard key.chat == chat, let inside = scopes[key.root] else { return false }
            return inside.isEmpty || key.path == inside || key.path.hasPrefix(inside + "/")
        }
        guard filesChat == chat else {
            for key in keys { fileTree[key] = nil }
            return
        }
        for key in keys.sorted(by: { ($0.root, $0.path) < ($1.root, $1.path) }) {
            send(filesListRequest(for: key))
        }
    }

    /// Per root that holds the session's folder, where the folder is in it:
    /// `""` for a root that is the folder (`chat`, or a deployment root at
    /// the same path), else the folder's path under the root.
    func sessionFolderScopes(chat: Int) -> [String: String] {
        guard let folder = summary(of: chat)?.folder else { return [:] }
        let own = URL(fileURLWithPath: folder).standardizedFileURL.path
        var scopes: [String: String] = [:]
        for root in fileRoots(for: chat) {
            let base = URL(fileURLWithPath: root.path).standardizedFileURL.path
            if base == own {
                scopes[root.name] = ""
            } else {
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if own.hasPrefix(prefix) { scopes[root.name] = String(own.dropFirst(prefix.count)) }
            }
        }
        return scopes
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
        viewerVisible[chat] = true
    }
}

/// When the Files tree lists the session's folder again on its own (v0.6):
/// a write-like tool finished, or a turn ended (a command may have made
/// files too). Live frames only; a replay changes nothing on disk.
enum FolderRelist {
    /// The engine's tools that write files.
    static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Whether `message` may have changed what the folder holds; `tool`
    /// names the tool a use started with.
    static func triggers(_ message: ServerMessage, tool: (String) -> String?) -> Bool {
        switch message {
        case .turnFinished: true
        case .toolFinished(let finished): tool(finished.toolUseId).map(writeTools.contains) ?? false
        default: false
        }
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
        case let ext where textExtensions.contains(ext): .text
        default: .other
        }
    }

    /// Plain text and code, `text` like `.txt` (`artifacts.TEXT_EXTENSIONS`;
    /// keep the two lists the same). The viewer draws them monospaced, and
    /// `csv`/`tsv` as a table when they parse.
    static let textExtensions: Set<String> = [
        "txt", "log", "csv", "tsv",
        "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "plist",
        "py", "js", "mjs", "cjs", "jsx", "ts", "tsx", "swift", "rb", "go", "rs",
        "java", "kt", "c", "h", "cpp", "hpp", "m", "cs", "php", "pl", "lua", "r",
        "sh", "bash", "zsh", "fish", "css", "scss", "sql", "diff", "patch",
    ]
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
        self.appVersion = appVersion
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
            if replacedElsewhere {
                connection = .failed(Self.replacedText)
                while replacedElsewhere && !Task.isCancelled { await pause(.seconds(3600)) }
                backoff = .seconds(1)
                continue
            }
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
    /// it on again. Without a socket of its own (the window is closed, so
    /// the loop is not running; or it is between attempts) the gateway may
    /// still be up: it is found the way the loop finds it and told through
    /// a socket opened for just that.
    @discardableResult
    func stopGateway(timeout: Duration = .seconds(10)) async -> Bool {
        autoStartGateway = false
        guard connection == .connected else {
            return await stopDetachedGateway(timeout: timeout)
        }
        send(.gatewayStop(GatewayStop()))
        let closed = await waitForDisconnect(timeout)
        if closed { supervisor?.noteStopped() }
        return closed
    }

    /// Stop a gateway this app is not attached to. Closing the main window
    /// ends the connection loop, so a quit with "stop everything" after
    /// that has no socket to speak through — and `send` would drop the
    /// frame on the floor while the gateway ran on. Find the gateway (the
    /// settings override, else the ledger; automatic start is already
    /// off, so nothing is started to be stopped), attach, say
    /// `gateway.stop`, and wait for it to close the socket, which is its
    /// answer. Nothing found: nothing to stop.
    private func stopDetachedGateway(timeout: Duration) async -> Bool {
        guard let supervisor, let endpoint = await endpoint(supervisor: supervisor, settings: settings) else {
            self.supervisor?.noteStopped()
            return true
        }
        let client = GatewayClient()
        defer { Task { await client.disconnect() } }
        do {
            _ = try await client.connect(url: endpoint.url, token: endpoint.token, appVersion: appVersion)
            try await client.send(.gatewayStop(GatewayStop()))
        } catch {
            return false
        }
        let stream = await client.messages
        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if closed { supervisor.noteStopped() }
        return closed
    }

    /// Start (or attach to) a gateway: automatic start goes back on and
    /// the connection loop is woken; without a loop (no window open) the
    /// supervisor is started directly and the next loop attaches to it.
    func startGateway() {
        autoStartGateway = true
        replacedElsewhere = false
        if loopRunning {
            reconnectWait?.cancel()
        } else if let supervisor {
            Task { _ = try? await supervisor.start() }
        }
    }

    /// "Restart the gateway to apply": stop it (`gateway.stop`, as Stop
    /// does) and start it again; the new gateway's `hello` clears the
    /// stale mark.
    func restartGateway(timeout: Duration = .seconds(10)) async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        await stopGateway(timeout: timeout)
        startGateway()
    }

    /// The update the strip offers: a version was found and the deployment
    /// can run the update (`hello.can_update`).
    var offeredUpdate: String? {
        guard hello?.canUpdate == true else { return nil }
        return updateVersion
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
