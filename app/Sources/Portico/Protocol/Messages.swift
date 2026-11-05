import Foundation

// The Portico protocol, version 1, as Swift types.
//
// The gateway's Pydantic models are the source of truth; these types mirror
// them field for field and are tested against every file under
// `protocol/examples/` (ProtocolExamplesTests). Swift names are camelCase,
// with `CodingKeys` mapping to the protocol's snake_case where they differ.
//
// Direction vocabulary: `ClientMessage` is app -> gateway, `ServerMessage` is
// gateway -> app. `hello` and `files.list` exist in both directions with
// different fields, so each direction has its own enum.

let protocolVersion = 1

// MARK: - Envelope and timestamps

/// The routing fields every message may carry: `chat`, `id` (request or card
/// correlation) and `seq` (the gateway's per-chat sequence number).
struct Envelope: Equatable, Sendable {
    var chat: Int?
    var id: String?
    var seq: Int?
}

/// ISO-8601 UTC timestamps in the protocol's wire form, e.g. `2026-10-27T12:00:00Z`.
enum ProtocolClock {
    /// `Date.ISO8601FormatStyle` is `Sendable`, unlike `ISO8601DateFormatter`;
    /// its default is whole seconds in UTC with a `Z` suffix.
    static func now() -> String {
        Date().formatted(Date.ISO8601FormatStyle())
    }
}

// MARK: - JSON values

/// Any JSON value; used where the protocol carries free-form objects
/// (a tool's `input`, a card's `answer`).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Words

enum ChatStateWord: String, Codable, Sendable {
    case idle
    case working
    case waitingOnYou = "waiting on you"
    case stopped
}

enum Scope: String, Codable, Sendable {
    case once, chat, always
}

/// How the engine decides on tool use: ask each time, allow edits, or let
/// the engine's classifier decide.
enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case `default`
    case acceptEdits
    case auto
}

/// What happened to one tool use's permission, drawn on its tool row.
enum PermissionOutcome: String, Codable, Sendable {
    case once, session, auto, declined, blocked
}

enum Media: String, Codable, Sendable {
    case markdown, image, html, pdf, text, url, other
}

enum Outcome: String, Codable, Sendable {
    case done, stopped, error
}

enum CardKind: String, Codable, Sendable {
    case permission, question, form
}

enum ArtifactKind: String, Codable, Sendable {
    case file, url
}

enum ArtifactSource: String, Codable, Sendable {
    case tool, text, producer
}

enum FormFieldKind: String, Codable, Sendable {
    case text, choice, toggle
}

// MARK: - Building blocks

struct Brand: Codable, Equatable, Sendable {
    var name: String
    var agentName: String
    var accent: String? = nil
    var icon: String? = nil
    /// v0.7: an image the toolbar shows in place of the mark and the name.
    var headerImage: String? = nil
    /// v0.20.1: the deployment's version for the About panel, and the
    /// panel's text under it (`{app_version}` and `{built}` filled in).
    var version: String? = nil
    var about: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, accent, icon, version, about
        case agentName = "agent_name"
        case headerImage = "header_image"
    }
}

struct Action: Codable, Equatable, Sendable {
    var label: String
    var text: String
}

struct Root: Codable, Equatable, Sendable {
    var name: String
    var path: String
    /// v0.19 (`files.extra.v1`): a folder the person added, and one that is not a directory (any more).
    var extra: Bool? = nil
    var missing: Bool? = nil

    var isExtra: Bool { extra == true }
    var isMissing: Bool { missing == true }
}

struct ChatSummary: Codable, Equatable, Sendable {
    var chat: Int
    var folder: String
    var alias: String?
    var state: ChatStateWord
    var created: String
    // v0.2 session facts. Optional so a v0.1 gateway's records (which
    // carry none of them) decode, and absent ones stay absent on the wire.
    /// The first line of the first user message (≤60), until something better names it.
    var title: String? = nil
    /// When the session ended (`session.renew`); `nil` while it is live.
    var ended: String? = nil
    /// Whether the log step finished cleanly; `nil` when no log step ran.
    var logged: Bool? = nil
    /// The session this one followed.
    var parent: Int? = nil
    /// How many times the engine summarized this session to make room.
    var compactions: Int? = nil
    /// The context window's fullness after the last turn, 0–100.
    var contextPercent: Double? = nil
    /// The session's permission mode (v0.3); absent from older gateways.
    var mode: PermissionMode? = nil
    /// When the log step last finished cleanly in this session (v0.4:
    /// `session.log` or a renewal's log).
    var loggedAt: String? = nil
    /// The session has work no log holds yet (v0.4): a turn finished after
    /// the last log, or none ran and a turn finished. Computed by the
    /// gateway; absent means false.
    var unlogged: Bool? = nil
    /// When a turn last finished (v0.6): the welcome's "last reply 12 min
    /// ago". Absent before the first turn, and from an older gateway.
    var lastReply: String? = nil
    /// What makes this chat a thread (v0.16, `threads.v1`); absent on Main,
    /// on every other chat, and from an older gateway.
    var thread: ThreadInfo? = nil

    enum CodingKeys: String, CodingKey {
        case chat, folder, alias, state, created, title, ended, logged, parent, compactions, mode, unlogged, thread
        case contextPercent = "context_percent"
        case loggedAt = "logged_at"
        case lastReply = "last_reply"
    }

    /// `unlogged`, absent read as false.
    var hasUnloggedWork: Bool { unlogged ?? false }
}

/// What makes a chat a thread (v0.16): opened from Main (`parent`) for
/// `brief`. `label` is "Thread 1" or "Thread 2"; `slot` (1 or 2) is its
/// number and its key (⌃1, ⌃2), used again once it closes; `files` are
/// the paths it started with; `openedAt` when it started.
struct ThreadInfo: Codable, Equatable, Sendable {
    var label: String
    var slot: Int
    var parent: Int
    var brief: String
    var files: [String] = []
    var openedAt: String

    enum CodingKeys: String, CodingKey {
        case label, slot, parent, brief, files
        case openedAt = "opened_at"
    }
}

/// What a service check last said (v0.4).
enum ServiceState: String, Codable, Sendable {
    case up, down, stuck, checking

    /// v0.17: `stuck` is running but not working. A state this app does
    /// not know reads as down rather than failing the whole status.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServiceState(rawValue: raw) ?? .down
    }
}

/// One of the deployment's services as the gateway last checked it
/// (`services.status`, v0.4). Portico draws it; it never knows what it is.
struct Service: Codable, Equatable, Sendable, Identifiable {
    /// v0.17: the capability this app lists so the gateway may send it
    /// `stuck`; to any other app the gateway sends down.
    static let stuckCapability = "services.stuck.v1"

    var id: String
    var name: String
    var state: ServiceState
    /// One line: the up detail, or why it is down.
    var detail: String? = nil
    /// When the service entered its state (ISO 8601).
    var since: String? = nil
    /// The deployment has a restart command for it; absent means false.
    var canRestart: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, state, detail, since
        case canRestart = "can_restart"
    }
}

/// One `files.search` result: `path` is relative to the searched root.
struct Hit: Codable, Equatable, Sendable {
    var path: String
    var snippet: String? = nil
}

struct Permission: Codable, Equatable, Sendable {
    var tool: String
    var summary: String
    var input: [String: JSONValue]
}

struct Option: Codable, Equatable, Sendable {
    var label: String
    var description: String
    /// The option's preview (v0.16), Markdown, when the agent sent one.
    var preview: String? = nil
}

struct Question: Codable, Equatable, Sendable {
    var question: String
    var header: String
    var options: [Option]
    var multiSelect: Bool

    enum CodingKeys: String, CodingKey {
        case question, header, options
        case multiSelect = "multi_select"
    }
}

struct FormField: Codable, Equatable, Sendable {
    var key: String
    var label: String
    var kind: FormFieldKind
    var options: [String]?
}

struct Artifact: Codable, Equatable, Sendable {
    var id: String
    var kind: ArtifactKind
    var location: String
    var media: Media
    var title: String
    var source: ArtifactSource
    var open: Bool
    /// The space this artifact is the file of (v0.12, `spaces.v1`); absent otherwise.
    var space: String? = nil
}

struct Entry: Codable, Equatable, Sendable {
    var name: String
    var dir: Bool
    var size: Int?
}

// MARK: - App -> gateway payloads

struct HelloClient: Codable, Equatable, Sendable {
    static let messageType = "hello"
    var appVersion: String
    var `protocol`: Int = protocolVersion
    /// What this app can draw beyond protocol 1's base (v0.10: `agents.v1`,
    /// the agent tray and workflow box). Additive and optional: absent, the
    /// gateway assumes nothing. A gateway older than v0.10 refuses the field
    /// (`protocol.invalid`), so `GatewayClient.connect` says hello again
    /// without it.
    var capabilities: [String]? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case `protocol`, capabilities, id, ts
        case appVersion = "app_version"
    }

    /// Everything this app names in `capabilities` (v0.11: `queue.v1`,
    /// messages typed while the agent works).
    static let appCapabilities = [
        AgentActivity.capability, ChatQueue.capability, ViewerSettings.capability, SpacesList.capability,
        MarkStore.capability, Models.capability, ThreadProposal.capability, ViewerAct.showCapability,
        Service.stuckCapability, AppOpen.capability, UserText.attachmentsCapability,
        FilesRootsSet.capability, FilesEdited.capability,
    ]
}

struct ChatNew: Codable, Equatable, Sendable {
    static let messageType = "chat.new"
    var folder: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct ChatOpen: Codable, Equatable, Sendable {
    static let messageType = "chat.open"
    var chat: Int
    var since: Int? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct ChatStop: Codable, Equatable, Sendable {
    static let messageType = "chat.stop"
    var chat: Int
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct ChatAlias: Codable, Equatable, Sendable {
    static let messageType = "chat.alias"
    var chat: Int
    var alias: String? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct ChatRemove: Codable, Equatable, Sendable {
    static let messageType = "chat.remove"
    var chat: Int
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct MessageSend: Codable, Equatable, Sendable {
    static let messageType = "message.send"
    var chat: Int
    var text: String
    var attachments: [String] = []
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct TurnStop: Codable, Equatable, Sendable {
    static let messageType = "turn.stop"
    var chat: Int
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct CardAnswer: Codable, Equatable, Sendable {
    static let messageType = "card.answer"
    var chat: Int
    /// The card id being answered.
    var id: String
    var answer: [String: JSONValue]
    var scope: Scope? = nil
    var note: String? = nil
    var ts: String = ProtocolClock.now()
}

/// How a question card was declined (v0.16): every question skipped, the
/// card's ×, or a reply sent from the composer while it was up. Sent as
/// `card.answer`'s `{"declined": <word>}`.
enum QuestionDecline: String, Codable, Sendable, CaseIterable {
    case skipped, dismissed, replied
}

extension CardAnswer {
    /// A question card's decline: `{"declined": "skipped" | "dismissed" | "replied"}`.
    static func declining(chat: Int, id: String, _ decline: QuestionDecline) -> CardAnswer {
        CardAnswer(chat: chat, id: id, answer: ["declined": .string(decline.rawValue)])
    }

    /// The decline this answer carries, if it is one.
    var declined: QuestionDecline? {
        answer["declined"]?.stringValue.flatMap(QuestionDecline.init(rawValue:))
    }
}

/// v0.19 (`files.extra.v1`): the folders this app adds to the Files pane;
/// each send replaces the last list. Answered with `files.roots`.
struct FilesRootsSet: Codable, Equatable, Sendable {
    static let messageType = "files.roots.set"
    static let capability = "files.extra.v1"
    var paths: [String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// v0.20 (`files.edited.v1`): the person saved `path` in the viewer's editor;
/// the gateway tells the agent with the next message. No reply.
struct FilesEdited: Codable, Equatable, Sendable {
    static let messageType = "files.edited"
    static let capability = "files.edited.v1"
    var chat: Int
    var path: String
    var ts: String = ProtocolClock.now()
}

struct FilesListRequest: Codable, Equatable, Sendable {
    static let messageType = "files.list"
    var root: String
    var path: String = ""
    var chat: Int? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// End the session `chat` and start the next one in the same folder;
/// with `log`, the gateway first runs the deployment's log step in it.
/// Answered with `session.renewed`.
struct SessionRenew: Codable, Equatable, Sendable {
    static let messageType = "session.renew"
    var chat: Int
    var log: Bool = true
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Run the deployment's log step in the live session `chat` without
/// ending it (v0.4). Answered with `session.logged`.
struct SessionLog: Codable, Equatable, Sendable {
    static let messageType = "session.log"
    var chat: Int
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Run a service's restart command (v0.4); answered by the next
/// `services.status`.
struct ServiceRestart: Codable, Equatable, Sendable {
    static let messageType = "service.restart"
    var service: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Run the deployment's one restart command for all its services (v0.8
/// decision 4), offered when `hello.capabilities` has
/// `services.restart_all`. Answered by a fresh `services.status`, or an
/// `error` with this `id` (`services.restart_failed`).
struct ServicesRestartAll: Codable, Equatable, Sendable {
    static let messageType = "services.restart_all"
    static let capability = "services.restart_all"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Forget the ended sessions, keeping the live one (v0.11; single
/// presentation, when `hello.capabilities` has `sessions.clear`). Only
/// Portico's list is cleared: the transcripts on disk stay. Answered with
/// `chat.list`.
struct SessionsClear: Codable, Equatable, Sendable {
    static let messageType = "sessions.clear"
    static let capability = "sessions.clear"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Take a queued message back before it goes to the agent (v0.11, item
/// 74): `id` as `chat.queued` named it. Answered with `chat.queue`, or
/// `error code=chat.not_queued` when it has already gone.
struct ChatUnqueue: Codable, Equatable, Sendable {
    static let messageType = "chat.unqueue"
    var chat: Int
    var id: String
    var ts: String = ProtocolClock.now()
}

/// Change the session's permission mode; answered with `chat.state`
/// carrying `mode`.
struct SessionMode: Codable, Equatable, Sendable {
    static let messageType = "session.mode"
    var chat: Int
    var mode: PermissionMode
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Switch the model for this session and the ones after it (v0.15,
/// `models.v1`): a `models` choice's `value`; `"default"` or absent is the
/// deployment's default. Answered with `models` carrying the `id` and the
/// new `current`, or with `error` (`chat.busy`, `model.unknown`).
struct ModelSet: Codable, Equatable, Sendable {
    static let messageType = "model.set"
    var chat: Int
    var value: String?
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Start the thread a proposal on Main (`chat`) describes (v0.16,
/// `threads.v1`); `close` names an open thread to close first at the limit
/// (Close and start). Answered with `chat.state idle` for the new thread
/// (with the `id`), `chat.list`, then `thread.proposal` `started`; or an
/// `error` with the `id`. Starting never changes which chat is Main.
struct ThreadStart: Codable, Equatable, Sendable {
    static let messageType = "thread.start"
    var chat: Int
    var proposal: String
    var close: Int? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// "Not now" on a proposal on Main (`chat`) (v0.16): it becomes
/// `dismissed`, answered with `thread.proposal` carrying the `id`.
struct ThreadDismiss: Codable, Equatable, Sendable {
    static let messageType = "thread.dismiss"
    var chat: Int
    var proposal: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Close the thread `chat` (v0.16): its log step (unless `log` is false,
/// the app's "Close without logging"), then it ends into History.
/// Answered with `chat.state stopped` (with the `id`), then `chat.list`.
struct ThreadClose: Codable, Equatable, Sendable {
    static let messageType = "thread.close"
    var chat: Int
    var log: Bool = true
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Search names and text under a root; answered with `files.results`.
struct FilesSearch: Codable, Equatable, Sendable {
    static let messageType = "files.search"
    var root: String
    var query: String
    var chat: Int? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

struct ArtifactOpened: Codable, Equatable, Sendable {
    static let messageType = "artifact.opened"
    var chat: Int
    var artifactId: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, id, ts
        case artifactId = "artifact_id"
    }
}

/// Stop the gateway: interrupt every running turn, run the deployment's
/// stop command, exit. Distinct from quitting the app, which only detaches.
struct GatewayStop: Codable, Equatable, Sendable {
    static let messageType = "gateway.stop"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

// MARK: - Viewer vision and spaces (v0.12)

/// What the person's switches say about the agent and the viewer, sent
/// after `hello` and whenever either changes (not chat-scoped). The
/// gateway sends `viewer.act` only to the app that sent this last.
struct ViewerSettings: Codable, Equatable, Sendable {
    static let messageType = "viewer.settings"
    /// Named in the app's `hello.capabilities`.
    static let capability = "viewer.v1"
    var canSee: Bool
    var checkHTML: Bool
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case canSee = "can_see"
        case checkHTML = "check_html"
        case ts
    }
}

/// The app's answer to a `viewer.act`: text, and for a look an image.
struct ViewerResult: Codable, Equatable, Sendable {
    static let messageType = "viewer.result"

    struct Image: Codable, Equatable, Sendable {
        /// Base64 PNG.
        var data: String
        var mediaType: String = "image/png"

        enum CodingKeys: String, CodingKey {
            case data
            case mediaType = "media_type"
        }
    }

    var id: String
    var ok: Bool
    var text: String
    var image: Image? = nil
    var error: String? = nil
    var ts: String = ProtocolClock.now()

    /// The synthesized encoding leaves a nil `image` / `error` out, as the gateway's examples do.
    enum CodingKeys: String, CodingKey { case id, ok, text, image, error, ts }
}

/// Ask the gateway to run a space's refresh command; answered by a new
/// `spaces.list` or an `error`.
struct SpaceRefresh: Codable, Equatable, Sendable {
    static let messageType = "space.refresh"
    var id: String
    var ts: String = ProtocolClock.now()
}

struct SpaceRename: Codable, Equatable, Sendable {
    static let messageType = "space.rename"
    var id: String
    var title: String
    var ts: String = ProtocolClock.now()
}

struct SpaceRemove: Codable, Equatable, Sendable {
    static let messageType = "space.remove"
    var id: String
    var ts: String = ProtocolClock.now()
}

// MARK: - Gateway -> app payloads

struct HelloServer: Codable, Equatable, Sendable {
    static let messageType = "hello"
    var `protocol`: Int
    var gatewayVersion: String
    var epoch: String
    var brand: Brand
    var actions: [Action]
    var roots: [Root]
    var commands: [String]
    var capabilities: [String]
    /// `single` (one live session at a time) or `multiple` (v0.1's chat
    /// list); absent from a v0.1 gateway, which means `multiple`.
    var presentation: String? = nil
    /// Whether the deployment has a log step for `session.renew`.
    var canLog: Bool? = nil
    /// The config file changed after the gateway started (v0.3).
    var configStale: Bool? = nil
    /// The deployment has an update command (v0.3).
    var canUpdate: Bool? = nil
    /// Where a new session works when the person has not chosen (v0.3).
    var defaultFolder: String? = nil
    /// The mode a new session starts in (config `permission_mode`, v0.3):
    /// what the start screen's chip shows until the person picks one.
    var permissionMode: PermissionMode? = nil
    /// The Files pane leaves out the session's own folder (v0.11, config
    /// `[files] hide_session_folder`); it still resolves.
    var hideSessionFolder: Bool? = nil
    /// The deployment fixes "Works in" (v0.19, config `[sessions] lock_folder`).
    var lockFolder: Bool? = nil
    /// Host suffix to site name for link chips (v0.19, config `[links] sites`).
    var linkSites: [String: String]? = nil
    /// The deployment's defaults for the viewer switches (v0.12, config
    /// `[viewer]`); absent from an older gateway.
    var viewerDefaults: ViewerDefaults? = nil
    /// How many threads may be open beside Main (v0.16, config `[threads]
    /// max`), sent with `threads.v1`; absent from an older gateway (2).
    var threadsMax: Int? = nil
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case `protocol`, epoch, brand, actions, roots, commands, capabilities, presentation, chat, id, seq, ts
        case viewerDefaults = "viewer_defaults"
        case threadsMax = "threads_max"
        case gatewayVersion = "gateway_version"
        case canLog = "can_log"
        case configStale = "config_stale"
        case canUpdate = "can_update"
        case defaultFolder = "default_folder"
        case permissionMode = "permission_mode"
        case hideSessionFolder = "hide_session_folder"
        case lockFolder = "lock_folder"
        case linkSites = "link_sites"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }

    /// One live session at a time (S1), rather than the chat list.
    var isSingle: Bool { presentation == "single" }
}

// MARK: - Viewer vision and spaces, gateway -> app (v0.12)

/// `hello.viewer_defaults`: what the switches start as until the person
/// changes them, and the hosts the agent may act on beyond local pages.
struct ViewerDefaults: Codable, Equatable, Sendable {
    var agentCanSee: Bool
    var agentChecksHTML: Bool
    var actHosts: [String]
    /// How a Properties block first opens, `"folded"` or `"open"` (v0.17,
    /// config `[viewer] properties`); absent from an older gateway.
    var properties: String? = nil

    enum CodingKeys: String, CodingKey {
        case agentCanSee = "agent_can_see"
        case agentChecksHTML = "agent_checks_html"
        case actHosts = "act_hosts"
        case properties
    }

    init(agentCanSee: Bool = true, agentChecksHTML: Bool = true, actHosts: [String] = [], properties: String? = nil) {
        self.agentCanSee = agentCanSee
        self.agentChecksHTML = agentChecksHTML
        self.actHosts = actHosts
        self.properties = properties
    }

    /// Each field on its own: a partial object takes the defaults (both
    /// switches on, no outside hosts) for what it leaves out, rather than
    /// failing the hello it rides in.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentCanSee = try c.decodeIfPresent(Bool.self, forKey: .agentCanSee) ?? true
        agentChecksHTML = try c.decodeIfPresent(Bool.self, forKey: .agentChecksHTML) ?? true
        actHosts = try c.decodeIfPresent([String].self, forKey: .actHosts) ?? []
        properties = try c.decodeIfPresent(String.self, forKey: .properties)
    }
}

/// The agent asks the app to act in the viewer on screen; answered by one
/// `viewer.result` with the same `id`.
struct ViewerAct: Codable, Equatable, Sendable {
    static let messageType = "viewer.act"

    /// Named in the app's `hello.capabilities` (v0.17): this app answers
    /// `show` once the page the agent showed has loaded.
    static let showCapability = "viewer.show.v1"

    enum Action: String, Codable, Sendable {
        case look, click, type, scroll, back, mark
        case clearMarks = "clear_marks"
        /// v0.17: answer once the file or page `{artifact, location}` the
        /// agent showed is in front and has loaded.
        case show
    }

    var id: String
    var chat: Int
    var action: Action
    /// look `{}`, click `{target}`, type `{target, text, submit}`,
    /// scroll `{direction}` or `{target}`, back `{}`, show `{artifact, location}`.
    var args: [String: JSONValue] = [:]
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }

    init(id: String, chat: Int, action: Action, args: [String: JSONValue] = [:], seq: Int? = nil, ts: String = ProtocolClock.now()) {
        self.id = id
        self.chat = chat
        self.action = action
        self.args = args
        self.seq = seq
        self.ts = ts
    }

    enum CodingKeys: String, CodingKey { case id, chat, action, args, seq, ts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chat = try c.decode(Int.self, forKey: .chat)
        action = try c.decode(Action.self, forKey: .action)
        args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ProtocolClock.now()
    }
}

/// One space: a file the agent keeps current, listed in the switcher.
struct SpaceInfo: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var icon: String
    /// The person's order in the folder's front matter; `nil` sorts after.
    var order: Int?
    var location: String
    var media: String
    /// The file's modification time, UTC ISO 8601.
    var updated: String

    /// `updated` as a date; `nil` if the gateway sent something else.
    var updatedDate: Date? {
        if let date = try? Date(updated, strategy: .iso8601) { return date }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: updated)
    }
}

/// The whole list of spaces, after `hello` and on every change.
struct SpacesList: Codable, Equatable, Sendable {
    static let messageType = "spaces.list"
    /// Named in the gateway's `hello.capabilities` when a folder is configured.
    static let capability = "spaces.v1"
    /// Named when the gateway has a refresh command.
    static let refreshCapability = "spaces.refresh"
    var spaces: [SpaceInfo]
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: seq) }
}

struct ChatList: Codable, Equatable, Sendable {
    static let messageType = "chat.list"
    var chats: [ChatSummary]
    /// The number the next new session will have (v0.11), so the welcome
    /// names it. Absent from an older gateway.
    var nextChat: Int? = nil
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chats, chat, id, seq, ts
        case nextChat = "next_chat"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct ChatState: Codable, Equatable, Sendable {
    static let messageType = "chat.state"
    var chat: Int
    var state: ChatStateWord
    var mode: PermissionMode? = nil
    /// The session's `unlogged` as of this state (v0.4, on every
    /// `chat.state`): a turn that just finished makes it true without a
    /// `chat.list`. Absent from an older gateway: the record keeps its own.
    var unlogged: Bool? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct ChatHistory: Codable, Equatable, Sendable {
    static let messageType = "chat.history"
    var chat: Int
    /// Chat-scoped events replayed in order, each with its `seq`.
    var events: [ServerMessage]
    var truncated: Bool
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }

    enum CodingKeys: String, CodingKey {
        case chat, events, truncated, id, seq, ts
    }

    init(chat: Int, events: [ServerMessage], truncated: Bool, id: String? = nil, seq: Int? = nil, ts: String = ProtocolClock.now()) {
        self.chat = chat
        self.events = events
        self.truncated = truncated
        self.id = id
        self.seq = seq
        self.ts = ts
    }

    /// An event this app cannot read (a type from a newer gateway) is
    /// dropped from the replay, as the live socket skips such a frame,
    /// rather than failing the whole history.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decode(Int.self, forKey: .chat)
        events = try c.decode([Ignorable<ServerMessage>].self, forKey: .events).compactMap(\.value)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        ts = try c.decode(String.self, forKey: .ts)
    }
}

/// A value that decodes to `nil` instead of failing: for list members a
/// newer peer may send in a shape this version does not know.
struct Ignorable<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct ChatLive: Codable, Equatable, Sendable {
    static let messageType = "chat.live"
    var chat: Int
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct TurnStarted: Codable, Equatable, Sendable {
    static let messageType = "turn.started"
    var chat: Int
    var turn: Int
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// What the person sent to start a turn, as the engine received it. Sent
/// live right after `turn.started` (with `seq`) and in a `chat.history`
/// transcript replay (without).
struct UserText: Codable, Equatable, Sendable {
    static let messageType = "user.text"
    var chat: Int
    var turn: Int
    var text: String
    /// v0.18: a message an MCP app sent (`app.message`) carries the app's
    /// server title; the transcript shows "via <title>" under the bubble.
    var via: String? = nil
    /// v0.19 (`messages.attachments.v1`, spec §8.4): the attached files'
    /// paths, and `text` is only what the person typed. `nil` from an older
    /// gateway, whose `text` still ends with the "Attached files:" block.
    var attachments: [String]? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    /// Named in the app's `hello.capabilities`: send `attachments` apart from the text.
    static let attachmentsCapability = "messages.attachments.v1"

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct TextDelta: Codable, Equatable, Sendable {
    static let messageType = "text.delta"
    var chat: Int
    var turn: Int
    var text: String
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct ToolStarted: Codable, Equatable, Sendable {
    static let messageType = "tool.started"
    var chat: Int
    var turn: Int
    var toolUseId: String
    var tool: String
    var summary: String
    var input: [String: JSONValue]
    /// The subagent this step belongs to (v0.10 decision 4): the row goes
    /// in that agent's step list, not the conversation.
    var agentId: String? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, turn, tool, summary, input, id, seq, ts
        case toolUseId = "tool_use_id"
        case agentId = "agent_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct ToolFinished: Codable, Equatable, Sendable {
    static let messageType = "tool.finished"
    var chat: Int
    var turn: Int
    var toolUseId: String
    var ok: Bool
    var summary: String
    /// What happened to this use's permission, when anything did (v0.3).
    var permission: PermissionOutcome? = nil
    /// The person's note on a decline.
    var note: String? = nil
    /// The subagent this step belongs to (v0.10 decision 4).
    var agentId: String? = nil
    /// An answered question's choices (v0.16), by question text; absent on
    /// any other row and on a declined question.
    var answers: [String: QuestionAnswer]? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, turn, ok, summary, permission, note, answers, id, seq, ts
        case toolUseId = "tool_use_id"
        case agentId = "agent_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// One question's answer on the wire (v0.16): a label, or a label list
/// for a `multi_select` question.
enum QuestionAnswer: Codable, Equatable, Sendable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let label = try? c.decode(String.self) {
            self = .one(label)
        } else {
            self = .many(try c.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .one(let label): try c.encode(label)
        case .many(let labels): try c.encode(labels)
        }
    }

    /// The chosen labels, in order.
    var labels: [String] {
        switch self {
        case .one(let label): [label]
        case .many(let labels): labels
        }
    }
}

struct TurnFinished: Codable, Equatable, Sendable {
    static let messageType = "turn.finished"
    var chat: Int
    var turn: Int
    var outcome: Outcome
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct CardAsk: Codable, Equatable, Sendable {
    static let messageType = "card.ask"
    var chat: Int
    /// The card id; the answer and any cancel carry it back.
    var id: String
    var kind: CardKind
    var title: String
    var permission: Permission?
    var questions: [Question]?
    var form: [FormField]?
    /// The tool use a permission card asks about, so the app can draw the
    /// card's outcome on that tool row (v0.3).
    var toolUseId: String? = nil
    /// A permission card: what "Allow for this session" would cover, in
    /// the gateway's words (v0.3). Shown under the buttons.
    var scopeNote: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, id, kind, title, permission, questions, form, seq, ts
        case toolUseId = "tool_use_id"
        case scopeNote = "scope_note"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The gateway accepted a `card.answer`: the card is closed. In the ring,
/// so a replay that carries the `card.ask` carries its closing too.
/// A permission card's closing carries its tool use and outcome (v0.3).
struct CardAnswered: Codable, Equatable, Sendable {
    static let messageType = "card.answered"
    var chat: Int
    var id: String
    var toolUseId: String? = nil
    var outcome: PermissionOutcome? = nil
    var note: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, id, outcome, note, seq, ts
        case toolUseId = "tool_use_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct CardCancel: Codable, Equatable, Sendable {
    static let messageType = "card.cancel"
    var chat: Int
    var id: String
    var reason: String?
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct ArtifactCreated: Codable, Equatable, Sendable {
    static let messageType = "artifact.created"
    var chat: Int
    var artifact: Artifact
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// v0.19: every root this connection has: the deployment's, then the added
/// folders in order (`extra`, and `missing` when not a directory).
struct FilesRoots: Codable, Equatable, Sendable {
    static let messageType = "files.roots"
    var roots: [Root]
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct FilesList: Codable, Equatable, Sendable {
    static let messageType = "files.list"
    var root: String
    var path: String
    var entries: [Entry]
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// How full the session's context window is, after each turn.
struct ContextUsage: Codable, Equatable, Sendable {
    static let messageType = "context.usage"
    var chat: Int
    var percent: Double
    var model: String? = nil
    /// The deployment's display name for `model`, when its env names one (v0.3).
    var modelName: String? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, percent, model, id, seq, ts
        case modelName = "model_name"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The engine summarized earlier conversation to make room. In the ring
/// and in a history replay, so the transcript draws its line either way.
struct ChatCompacted: Codable, Equatable, Sendable {
    static let messageType = "chat.compacted"
    var chat: Int
    /// `auto` or `manual`.
    var trigger: String
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The session `ended` was closed and `next` is the live one now.
struct SessionRenewed: Codable, Equatable, Sendable {
    static let messageType = "session.renewed"
    var ended: ChatSummary
    var next: ChatSummary
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// `session.log` finished: the session's record as the gateway now has it
/// (`logged_at` moved, `unlogged` cleared). `chat` is the record, not a
/// number, so the envelope carries no chat.
struct SessionLogged: Codable, Equatable, Sendable {
    static let messageType = "session.logged"
    var chat: ChatSummary
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: seq) }
}

/// Every service the deployment lists, down ones first (v0.4). Sent after
/// `hello` and `chat.list`, and on every change.
struct ServicesStatus: Codable, Equatable, Sendable {
    static let messageType = "services.status"
    var services: [Service]
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// One of the agent's slash commands or skills (v0.11 item 66): `name`
/// without the `/`, a one-line `description`, and where the engine says it
/// comes from (`user`, `project`, a plug-in), when it says.
struct AgentCommand: Codable, Equatable, Hashable, Sendable {
    var name: String
    var description: String = ""
    var source: String? = nil

    init(name: String, description: String = "", source: String? = nil) {
        self.name = name
        self.description = description
        self.source = source
    }

    /// `description` may be left out (the gateway's default is empty).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// The agent's commands and skills in `folder`, for the composer's slash
/// list (v0.11 item 66). With `chat` after that chat's engine starts;
/// without it on connect, from the list the gateway kept for the folder.
struct ChatCommands: Codable, Equatable, Sendable {
    static let messageType = "chat.commands"
    var folder: String
    var commands: [AgentCommand]
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// One model the session can switch to (v0.15): the engine's own `/model`
/// list, as the gateway passes it on. `resolvedModel` (11-02, optional) is
/// the model id the entry runs, so Default can be named by its model.
struct ModelChoice: Codable, Equatable, Sendable, Identifiable {
    var value: String
    var displayName: String
    var description: String
    var resolvedModel: String? = nil

    var id: String { value }

    enum CodingKeys: String, CodingKey {
        case value, description
        case displayName = "display_name"
        case resolvedModel = "resolved_model"
    }
}

/// The models a session can switch to and the one it runs on (v0.15,
/// `models.v1`). `current` absent: the deployment's default. Not stamped:
/// each one replaces what the app had for the chat.
struct Models: Codable, Equatable, Sendable {
    static let messageType = "models"
    static let capability = "models.v1"
    /// The `value` of the choice that means the deployment's default.
    static let defaultValue = "default"
    var chat: Int
    var current: String? = nil
    var choices: [ModelChoice]
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The answer to `files.search`.
struct FilesResults: Codable, Equatable, Sendable {
    static let messageType = "files.results"
    var root: String
    var query: String
    var hits: [Hit]? = nil
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

struct StatusSet: Codable, Equatable, Sendable {
    static let messageType = "status.set"
    var text: String
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A quiet line in the conversation from the gateway, e.g. an unknown command.
struct ChatNotice: Codable, Equatable, Sendable {
    static let messageType = "chat.notice"
    var chat: Int
    var text: String
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A message the gateway holds for the agent until its next step (v0.11).
struct QueuedMessage: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var attachments: [String] = []
}

/// The answer to a `message.send` made during a turn (v0.11): held, not
/// refused; `id` is the request's, the queued message's from now on.
struct ChatQueued: Codable, Equatable, Sendable {
    static let messageType = "chat.queued"
    var chat: Int
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// What a chat holds for the agent, oldest first, after every change and
/// on every `chat.open` (v0.11). Replaces whatever the app had.
struct ChatQueue: Codable, Equatable, Sendable {
    static let messageType = "chat.queue"
    /// Both sides list it in `hello` for a send during a turn to be queued.
    static let capability = "queue.v1"
    var chat: Int
    var items: [QueuedMessage] = []
    /// What a `turn.stop` took out of the queue, oldest first, for the
    /// composer (v0.11, Larry 10-30); absent otherwise.
    var returned: [QueuedMessage]? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// Where a thread proposal stands (v0.16): `pending` until the person
/// starts or dismisses it, or Main's session ends (then `dismissed`).
enum ProposalState: String, Codable, Sendable {
    case pending, started, dismissed
}

/// A thread Main's agent proposed (`open_thread`, v0.16), and where it
/// stands. `chat` is Main's; `toolUseId` the tool row the card is drawn in
/// place of; `thread` the chat it started, once `started`. A state frame
/// like `chat.queue`: unstamped, sent on each change and on `chat.open`.
struct ThreadProposal: Codable, Equatable, Sendable {
    static let messageType = "thread.proposal"
    /// Both sides list it in `hello` for threads to show.
    static let capability = "threads.v1"
    var chat: Int
    var proposal: String
    var toolUseId: String? = nil
    var brief: String
    var files: [String] = []
    var state: ProposalState
    var thread: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, proposal, brief, files, state, thread, id, seq, ts
        case toolUseId = "tool_use_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The config file changed after the gateway started; restart to apply it.
struct ConfigStale: Codable, Equatable, Sendable {
    static let messageType = "config.stale"
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The deployment's update check found a newer version.
struct UpdateAvailable: Codable, Equatable, Sendable {
    static let messageType = "update.available"
    var version: String
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

// MARK: - Agents and workflows (v0.10)

/// How a subagent ended (`agent.finished`, v0.10 decision 4).
enum AgentOutcome: String, Codable, Sendable {
    case done, failed, stopped
}

/// Where a workflow phase stands (`workflow.phase`, v0.10 decision 4):
/// `pending` until its first agent starts, `running`, then `done` or
/// `failed` (one of its agents failed). The earlier draft's `waiting` is
/// read as `pending`.
enum PhaseState: String, Codable, Sendable {
    case pending, running, done, failed

    init(from decoder: Decoder) throws {
        let word = try decoder.singleValueContainer().decode(String.self)
        if word == "waiting" {
            self = .pending
        } else if let state = PhaseState(rawValue: word) {
            self = state
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown phase state \(word)"))
        }
    }

    /// Done or failed: the phase will not move again.
    var isSettled: Bool { self == .done || self == .failed }
}

/// The phase an agent of a workflow belongs to, as the gateway names it:
/// its index in `workflow.started`'s `phases`, or its name. Either form
/// decodes and encodes back as it came.
enum PhaseRef: Codable, Equatable, Sendable {
    case index(Int)
    case name(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .index(i)
        } else {
            self = .name(try c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .index(let i): try c.encode(i)
        case .name(let n): try c.encode(n)
        }
    }
}

/// The agent started a subagent (or a background task) with the tool use
/// `tool_use_id` (v0.10 decision 4). `id` is the agent's id; its steps
/// (`agent.progress`, tool rows with `agent_id`) and its end carry it.
struct AgentStarted: Codable, Equatable, Sendable {
    static let messageType = "agent.started"
    var chat: Int
    var turn: Int
    var id: String
    var toolUseId: String
    var description: String
    /// The engine's word for the task: `subagent`, `shell`, `monitor`, ….
    var kind: String
    /// The workflow it runs in, when it runs in one.
    var workflowId: String? = nil
    /// Its phase in that workflow (the gateway sends a 0-based index).
    var phase: PhaseRef? = nil
    /// It runs on after its turn finishes: a background subagent, and
    /// every agent of a workflow. Its frames may come during later turns.
    var background: Bool? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, turn, id, description, kind, phase, background, seq, ts
        case toolUseId = "tool_use_id"
        case workflowId = "workflow_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A subagent moved: its current step (the last tool, in words), how many
/// steps it has taken and how long it has run, in seconds.
struct AgentProgress: Codable, Equatable, Sendable {
    static let messageType = "agent.progress"
    var chat: Int
    var id: String
    var step: String? = nil
    var steps: Int
    var elapsed: Double
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A subagent ended: done, failed or stopped, with the engine's summary.
struct AgentFinished: Codable, Equatable, Sendable {
    static let messageType = "agent.finished"
    var chat: Int
    var id: String
    var outcome: AgentOutcome
    var summary: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A workflow started (v0.10 decision 2): its name and its phases, in
/// order; `phases` may be empty when the source names none. Sent first
/// with `phases: []` and again, with the same `id`, when the phases become
/// known or change: the app replaces what it had.
struct WorkflowStarted: Codable, Equatable, Sendable {
    static let messageType = "workflow.started"
    var chat: Int
    /// The turn that started it.
    var turn: Int? = nil
    var id: String
    var name: String
    var phases: [String]
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// One phase of a workflow changed state.
struct WorkflowPhase: Codable, Equatable, Sendable {
    static let messageType = "workflow.phase"
    var chat: Int
    var id: String
    var index: Int
    var state: PhaseState
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// A workflow ended: done, failed or stopped. Its agents have ended
/// before it; it runs in the background, so this may come after its turn.
struct WorkflowFinished: Codable, Equatable, Sendable {
    static let messageType = "workflow.finished"
    var chat: Int
    var id: String
    var outcome: AgentOutcome
    var summary: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

/// The protocol's `error` message. Named `ErrorMessage` so it does not shadow
/// `Swift.Error`.
struct ErrorMessage: Codable, Equatable, Sendable {
    static let messageType = "error"
    var code: String
    var message: String
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
}

// MARK: - MCP Apps (v0.18, `apps.v1`)

/// Show the app card for the agent's call `toolUseId` (gateway -> app).
/// `html` is absent in a `chat.history` replay: the card comes back frozen.
/// `csp`, `permissions` and `prefersBorder` are the resource's `_meta.ui`
/// members as the server gave them. Carries `id` when it answers `app.reload`.
struct AppOpen: Codable, Equatable, Sendable {
    static let messageType = "app.open"
    /// What the app names in hello's `capabilities` to be sent `app.*` frames.
    static let capability = "apps.v1"
    var chat: Int
    var toolUseId: String
    var server: String
    var serverTitle: String
    var tool: String
    var resourceUri: String
    var html: String? = nil
    var csp: [String: JSONValue]? = nil
    var permissions: [String: JSONValue]? = nil
    var prefersBorder: Bool? = nil
    var input: [String: JSONValue] = [:]
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, server, tool, html, csp, permissions, input, id, ts
        case toolUseId = "tool_use_id"
        case serverTitle = "server_title"
        case resourceUri = "resource_uri"
        case prefersBorder = "prefers_border"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: nil) }
}

/// The call's result for the page (`structuredContent` absent when the
/// server sent none or it was over the gateway's cap).
struct AppResult: Codable, Equatable, Sendable {
    static let messageType = "app.result"
    var chat: Int
    var toolUseId: String
    var content: [JSONValue] = []
    var structuredContent: [String: JSONValue]? = nil
    var isError: Bool = false
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, content, id, ts
        case toolUseId = "tool_use_id"
        case structuredContent = "structured_content"
        case isError = "is_error"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: nil) }
}

/// The call ended (stopped, or an error) with no result.
struct AppCancelled: Codable, Equatable, Sendable {
    static let messageType = "app.cancelled"
    var chat: Int
    var toolUseId: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, id, ts
        case toolUseId = "tool_use_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: nil) }
}

/// The answer to `app.call_tool` (its `id`). `ok` false carries `error`.
struct AppCallResult: Codable, Equatable, Sendable {
    static let messageType = "app.call_result"
    var toolUseId: String
    var ok: Bool
    var content: [JSONValue] = []
    var structuredContent: [String: JSONValue]? = nil
    var isError: Bool = false
    var error: String? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case ok, content, error, id, ts
        case toolUseId = "tool_use_id"
        case structuredContent = "structured_content"
        case isError = "is_error"
    }

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// The page's `tools/call` (app -> gateway): a bare `tool` is the card's own server's.
struct AppCallTool: Codable, Equatable, Sendable {
    static let messageType = "app.call_tool"
    var chat: Int
    var toolUseId: String
    var tool: String
    var arguments: [String: JSONValue] = [:]
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, tool, arguments, id, ts
        case toolUseId = "tool_use_id"
    }
}

/// The page's `ui/message`: sent as the person's message, labelled via the app.
struct AppMessage: Codable, Equatable, Sendable {
    static let messageType = "app.message"
    var chat: Int
    var toolUseId: String
    var text: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, text, id, ts
        case toolUseId = "tool_use_id"
    }
}

/// The page's `ui/update-model-context`: the latest is put before the person's next message.
struct AppContext: Codable, Equatable, Sendable {
    static let messageType = "app.context"
    var chat: Int
    var toolUseId: String
    var text: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, text, id, ts
        case toolUseId = "tool_use_id"
    }
}

/// Read the card's page again; answered `app.open` (with `html`) then `app.result`.
struct AppReload: Codable, Equatable, Sendable {
    static let messageType = "app.reload"
    var chat: Int
    var toolUseId: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, id, ts
        case toolUseId = "tool_use_id"
    }
}

// MARK: - MCP servers in Settings (v0.18 §3.1, `mcp.v1`)

/// The capability a gateway names in hello when Settings may send `mcp.*`.
enum McpCapability {
    static let name = "mcp.v1"
}

/// One tool of a server; `policy` is the effective one (the person's choice, else the default).
struct McpToolRow: Codable, Equatable, Sendable, Identifiable {
    enum Policy: String, Codable, Equatable, Sendable, CaseIterable {
        case allow, ask
    }

    var name: String
    var description: String = ""
    var readOnly: Bool = false
    var policy: Policy

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, policy
        case readOnly = "read_only"
    }
}

/// One server as Settings shows it. `detail` is the gateway's status line;
/// group titles and brand words are the app's.
struct McpServerRow: Codable, Equatable, Sendable, Identifiable {
    enum Group: String, Codable, Equatable, Sendable {
        case user, local, shipped, core, account
    }

    enum Transport: String, Codable, Equatable, Sendable {
        case stdio, http, sse, sdk, other
    }

    enum Status: String, Codable, Equatable, Sendable {
        case connected
        case needsAuth = "needs_auth"
        case failed, pending, off
        case signingIn = "signing_in"
        case unknown
    }

    var name: String
    var title: String
    var group: Group
    var transport: Transport
    var status: Status
    var detail: String
    var toolCount: Int? = nil
    var tools: [McpToolRow] = []
    var account: String? = nil
    var canToggle: Bool
    var canRemove: Bool
    var canSignOut: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, title, group, transport, status, detail, tools, account
        case toolCount = "tool_count"
        case canToggle = "can_toggle"
        case canRemove = "can_remove"
        case canSignOut = "can_sign_out"
    }
}

/// The answer to every `mcp.*` request (with its `id`), and after a sign-in
/// finishes (no `id`). Not sequenced.
struct McpServers: Codable, Equatable, Sendable {
    static let messageType = "mcp.servers"
    var servers: [McpServerRow] = []
    var live: Bool = false
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// The servers as they stand.
struct McpList: Codable, Equatable, Sendable {
    static let messageType = "mcp.list"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Turn a server off (`enabled` false) or on again, for Settings' folder.
struct McpToggle: Codable, Equatable, Sendable {
    static let messageType = "mcp.toggle"
    var name: String
    var enabled: Bool
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Reconnect a server in every live engine on Settings' folder.
struct McpReconnect: Codable, Equatable, Sendable {
    static let messageType = "mcp.reconnect"
    var name: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Remove a user or local server; the app asks first.
struct McpRemove: Codable, Equatable, Sendable {
    static let messageType = "mcp.remove"
    var name: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Add a server by a web address (`url`) or a program on this Mac (`command`).
struct McpAdd: Codable, Equatable, Sendable {
    static let messageType = "mcp.add"

    enum Transport: String, Codable, Equatable, Sendable { case http, stdio }
    /// `user`: All your projects; `local`: this deployment only.
    enum Where: String, Codable, Equatable, Sendable { case user, local }

    var name: String
    var transport: Transport
    var url: String? = nil
    var command: String? = nil
    var `where`: Where
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Sign in to a server: answered at once, a fresh `mcp.servers` (no id) when done.
struct McpSignIn: Codable, Equatable, Sendable {
    static let messageType = "mcp.sign_in"
    var name: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Sign out of a server.
struct McpSignOut: Codable, Equatable, Sendable {
    static let messageType = "mcp.sign_out"
    var name: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Whether one tool runs without asking (`allow`) or asks first (`ask`);
/// `nil` is back to the default.
struct McpToolPolicy: Codable, Equatable, Sendable {
    static let messageType = "mcp.tool_policy"
    var server: String
    var tool: String
    var policy: McpToolRow.Policy? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

// MARK: - Plugins in Settings (v0.18 §3, `plugins.v1`)
//
// `plugin` is the plugin's id as Claude Code prints it (`name@marketplace`);
// `id` stays the request's own (R-c10). The list and every change are
// answered with `plugins.state` carrying the id; details and options have
// their own replies; a refusal or failure is an `error` with the id.

/// The capability a gateway names in hello when Settings may send `plugins.*`.
enum PluginsCapability {
    static let name = "plugins.v1"
}

/// One installed plugin. `description` and `marketplace` come from its
/// marketplace entry; `update_to` is the marketplace's version when it differs.
struct PluginRow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var scope: String
    var enabled: Bool
    var description: String = ""
    var marketplace: String
    var updateTo: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, version, scope, enabled, description, marketplace
        case updateTo = "update_to"
    }
}

/// One plugin a marketplace offers (Browse).
struct AvailablePlugin: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var description: String = ""
    var marketplace: String
    var version: String? = nil
    var installed: Bool = false
}

/// One marketplace. `source_label` is absent for the official one; `checked`
/// is "today", "yesterday", a date like "Oct 24", or "" when unknown.
struct PluginMarketplace: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var sourceLabel: String? = nil
    var pluginCount: Int = 0
    var checked: String = ""

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, checked
        case sourceLabel = "source_label"
        case pluginCount = "plugin_count"
    }
}

/// One option of a plugin. A sensitive option's `value` never arrives; `set` says whether it has one.
struct PluginOption: Codable, Equatable, Sendable, Identifiable {
    var key: String
    var title: String
    var description: String = ""
    var sensitive: Bool = false
    var set: Bool = false
    var value: String? = nil

    var id: String { key }
}

/// The answer to `plugins.list` and to every change. `available` only for a
/// `plugins.list` with `available: true`. Not sequenced.
struct PluginsStateMessage: Codable, Equatable, Sendable {
    static let messageType = "plugins.state"
    var installed: [PluginRow] = []
    var available: [AvailablePlugin]? = nil
    var marketplaces: [PluginMarketplace] = []
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// A plugin's `claude plugin details` text.
struct PluginsDetails: Codable, Equatable, Sendable {
    static let messageType = "plugins.details"
    var plugin: String
    var text: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// A plugin's options (empty: nothing to configure).
struct PluginsOptions: Codable, Equatable, Sendable {
    static let messageType = "plugins.options"
    var plugin: String
    var options: [PluginOption] = []
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// The installed plugins and the marketplaces; `available` adds Browse's list.
struct PluginsList: Codable, Equatable, Sendable {
    static let messageType = "plugins.list"
    var available: Bool = false
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Turn a plugin on or off.
struct PluginsSetEnabled: Codable, Equatable, Sendable {
    static let messageType = "plugins.set_enabled"
    var plugin: String
    var enabled: Bool
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Install a plugin; one that installs by running a command is refused.
struct PluginsInstall: Codable, Equatable, Sendable {
    static let messageType = "plugins.install"
    var plugin: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Uninstall a plugin; the app asks first.
struct PluginsUninstall: Codable, Equatable, Sendable {
    static let messageType = "plugins.uninstall"
    var plugin: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Update a plugin (Update to …, Check for update).
struct PluginsUpdate: Codable, Equatable, Sendable {
    static let messageType = "plugins.update"
    var plugin: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Add a marketplace: a GitHub `owner/repo`, a git address or a folder.
struct PluginsMarketplaceAdd: Codable, Equatable, Sendable {
    static let messageType = "plugins.marketplace_add"
    var source: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Check a marketplace for updates.
struct PluginsMarketplaceUpdate: Codable, Equatable, Sendable {
    static let messageType = "plugins.marketplace_update"
    var name: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Ask for a plugin's details text (answered with `plugins.details`).
struct PluginsDetailsRequest: Codable, Equatable, Sendable {
    static let messageType = "plugins.details"
    var plugin: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Ask for a plugin's options (answered with `plugins.options`).
struct PluginsOptionsRequest: Codable, Equatable, Sendable {
    static let messageType = "plugins.options"
    var plugin: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Save option values: only the changed ones (answered with `plugins.options`).
struct PluginsConfigure: Codable, Equatable, Sendable {
    static let messageType = "plugins.configure"
    var plugin: String
    var values: [String: String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

// MARK: - The discriminated unions

private enum TypeKey: String, CodingKey {
    case type
}

private func unknownType(_ type: String, direction: String, _ decoder: Decoder) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "unknown \(direction) message type \(type)"))
}

/// Any app -> gateway message. Encodes as one JSON object with `type`, `ts`
/// and the payload's fields; decodes on the `type` key.
enum ClientMessage: Codable, Equatable, Sendable {
    case hello(HelloClient)
    case chatNew(ChatNew)
    case chatOpen(ChatOpen)
    case chatStop(ChatStop)
    case chatAlias(ChatAlias)
    case chatRemove(ChatRemove)
    case messageSend(MessageSend)
    case turnStop(TurnStop)
    case cardAnswer(CardAnswer)
    case filesList(FilesListRequest)
    case filesRootsSet(FilesRootsSet)
    case filesEdited(FilesEdited)
    case artifactOpened(ArtifactOpened)
    case gatewayStop(GatewayStop)
    case sessionRenew(SessionRenew)
    case filesSearch(FilesSearch)
    case sessionMode(SessionMode)
    case sessionLog(SessionLog)
    case serviceRestart(ServiceRestart)
    case servicesRestartAll(ServicesRestartAll)
    case sessionsClear(SessionsClear)
    case chatUnqueue(ChatUnqueue)
    case viewerSettings(ViewerSettings)
    case viewerResult(ViewerResult)
    case spaceRefresh(SpaceRefresh)
    case spaceRename(SpaceRename)
    case spaceRemove(SpaceRemove)
    case modelSet(ModelSet)
    case threadStart(ThreadStart)
    case threadDismiss(ThreadDismiss)
    case threadClose(ThreadClose)
    case appCallTool(AppCallTool)
    case appMessage(AppMessage)
    case appContext(AppContext)
    case appReload(AppReload)
    case mcpList(McpList)
    case mcpToggle(McpToggle)
    case mcpReconnect(McpReconnect)
    case mcpRemove(McpRemove)
    case mcpAdd(McpAdd)
    case mcpSignIn(McpSignIn)
    case mcpSignOut(McpSignOut)
    case mcpToolPolicy(McpToolPolicy)
    case pluginsList(PluginsList)
    case pluginsSetEnabled(PluginsSetEnabled)
    case pluginsInstall(PluginsInstall)
    case pluginsUninstall(PluginsUninstall)
    case pluginsUpdate(PluginsUpdate)
    case pluginsMarketplaceAdd(PluginsMarketplaceAdd)
    case pluginsMarketplaceUpdate(PluginsMarketplaceUpdate)
    case pluginsDetails(PluginsDetailsRequest)
    case pluginsOptions(PluginsOptionsRequest)
    case pluginsConfigure(PluginsConfigure)

    var type: String {
        switch self {
        case .hello: HelloClient.messageType
        case .chatNew: ChatNew.messageType
        case .chatOpen: ChatOpen.messageType
        case .chatStop: ChatStop.messageType
        case .chatAlias: ChatAlias.messageType
        case .chatRemove: ChatRemove.messageType
        case .messageSend: MessageSend.messageType
        case .turnStop: TurnStop.messageType
        case .cardAnswer: CardAnswer.messageType
        case .filesList: FilesListRequest.messageType
        case .filesRootsSet: FilesRootsSet.messageType
        case .filesEdited: FilesEdited.messageType
        case .artifactOpened: ArtifactOpened.messageType
        case .gatewayStop: GatewayStop.messageType
        case .sessionRenew: SessionRenew.messageType
        case .filesSearch: FilesSearch.messageType
        case .sessionMode: SessionMode.messageType
        case .sessionLog: SessionLog.messageType
        case .serviceRestart: ServiceRestart.messageType
        case .servicesRestartAll: ServicesRestartAll.messageType
        case .sessionsClear: SessionsClear.messageType
        case .chatUnqueue: ChatUnqueue.messageType
        case .viewerSettings: ViewerSettings.messageType
        case .viewerResult: ViewerResult.messageType
        case .spaceRefresh: SpaceRefresh.messageType
        case .spaceRename: SpaceRename.messageType
        case .spaceRemove: SpaceRemove.messageType
        case .modelSet: ModelSet.messageType
        case .threadStart: ThreadStart.messageType
        case .threadDismiss: ThreadDismiss.messageType
        case .threadClose: ThreadClose.messageType
        case .appCallTool: AppCallTool.messageType
        case .appMessage: AppMessage.messageType
        case .appContext: AppContext.messageType
        case .appReload: AppReload.messageType
        case .mcpList: McpList.messageType
        case .mcpToggle: McpToggle.messageType
        case .mcpReconnect: McpReconnect.messageType
        case .mcpRemove: McpRemove.messageType
        case .mcpAdd: McpAdd.messageType
        case .mcpSignIn: McpSignIn.messageType
        case .mcpSignOut: McpSignOut.messageType
        case .mcpToolPolicy: McpToolPolicy.messageType
        case .pluginsList: PluginsList.messageType
        case .pluginsSetEnabled: PluginsSetEnabled.messageType
        case .pluginsInstall: PluginsInstall.messageType
        case .pluginsUninstall: PluginsUninstall.messageType
        case .pluginsUpdate: PluginsUpdate.messageType
        case .pluginsMarketplaceAdd: PluginsMarketplaceAdd.messageType
        case .pluginsMarketplaceUpdate: PluginsMarketplaceUpdate.messageType
        case .pluginsDetails: PluginsDetailsRequest.messageType
        case .pluginsOptions: PluginsOptionsRequest.messageType
        case .pluginsConfigure: PluginsConfigure.messageType
        }
    }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case HelloClient.messageType: self = .hello(try HelloClient(from: decoder))
        case ChatNew.messageType: self = .chatNew(try ChatNew(from: decoder))
        case ChatOpen.messageType: self = .chatOpen(try ChatOpen(from: decoder))
        case ChatStop.messageType: self = .chatStop(try ChatStop(from: decoder))
        case ChatAlias.messageType: self = .chatAlias(try ChatAlias(from: decoder))
        case ChatRemove.messageType: self = .chatRemove(try ChatRemove(from: decoder))
        case MessageSend.messageType: self = .messageSend(try MessageSend(from: decoder))
        case TurnStop.messageType: self = .turnStop(try TurnStop(from: decoder))
        case CardAnswer.messageType: self = .cardAnswer(try CardAnswer(from: decoder))
        case FilesListRequest.messageType: self = .filesList(try FilesListRequest(from: decoder))
        case FilesRootsSet.messageType: self = .filesRootsSet(try FilesRootsSet(from: decoder))
        case FilesEdited.messageType: self = .filesEdited(try FilesEdited(from: decoder))
        case ArtifactOpened.messageType: self = .artifactOpened(try ArtifactOpened(from: decoder))
        case GatewayStop.messageType: self = .gatewayStop(try GatewayStop(from: decoder))
        case SessionRenew.messageType: self = .sessionRenew(try SessionRenew(from: decoder))
        case FilesSearch.messageType: self = .filesSearch(try FilesSearch(from: decoder))
        case SessionMode.messageType: self = .sessionMode(try SessionMode(from: decoder))
        case SessionLog.messageType: self = .sessionLog(try SessionLog(from: decoder))
        case ServiceRestart.messageType: self = .serviceRestart(try ServiceRestart(from: decoder))
        case ServicesRestartAll.messageType: self = .servicesRestartAll(try ServicesRestartAll(from: decoder))
        case SessionsClear.messageType: self = .sessionsClear(try SessionsClear(from: decoder))
        case ChatUnqueue.messageType: self = .chatUnqueue(try ChatUnqueue(from: decoder))
        case ViewerSettings.messageType: self = .viewerSettings(try ViewerSettings(from: decoder))
        case ViewerResult.messageType: self = .viewerResult(try ViewerResult(from: decoder))
        case SpaceRefresh.messageType: self = .spaceRefresh(try SpaceRefresh(from: decoder))
        case SpaceRename.messageType: self = .spaceRename(try SpaceRename(from: decoder))
        case SpaceRemove.messageType: self = .spaceRemove(try SpaceRemove(from: decoder))
        case ModelSet.messageType: self = .modelSet(try ModelSet(from: decoder))
        case ThreadStart.messageType: self = .threadStart(try ThreadStart(from: decoder))
        case ThreadDismiss.messageType: self = .threadDismiss(try ThreadDismiss(from: decoder))
        case ThreadClose.messageType: self = .threadClose(try ThreadClose(from: decoder))
        case AppCallTool.messageType: self = .appCallTool(try AppCallTool(from: decoder))
        case AppMessage.messageType: self = .appMessage(try AppMessage(from: decoder))
        case AppContext.messageType: self = .appContext(try AppContext(from: decoder))
        case AppReload.messageType: self = .appReload(try AppReload(from: decoder))
        case McpList.messageType: self = .mcpList(try McpList(from: decoder))
        case McpToggle.messageType: self = .mcpToggle(try McpToggle(from: decoder))
        case McpReconnect.messageType: self = .mcpReconnect(try McpReconnect(from: decoder))
        case McpRemove.messageType: self = .mcpRemove(try McpRemove(from: decoder))
        case McpAdd.messageType: self = .mcpAdd(try McpAdd(from: decoder))
        case McpSignIn.messageType: self = .mcpSignIn(try McpSignIn(from: decoder))
        case McpSignOut.messageType: self = .mcpSignOut(try McpSignOut(from: decoder))
        case McpToolPolicy.messageType: self = .mcpToolPolicy(try McpToolPolicy(from: decoder))
        case PluginsList.messageType: self = .pluginsList(try PluginsList(from: decoder))
        case PluginsSetEnabled.messageType: self = .pluginsSetEnabled(try PluginsSetEnabled(from: decoder))
        case PluginsInstall.messageType: self = .pluginsInstall(try PluginsInstall(from: decoder))
        case PluginsUninstall.messageType: self = .pluginsUninstall(try PluginsUninstall(from: decoder))
        case PluginsUpdate.messageType: self = .pluginsUpdate(try PluginsUpdate(from: decoder))
        case PluginsMarketplaceAdd.messageType: self = .pluginsMarketplaceAdd(try PluginsMarketplaceAdd(from: decoder))
        case PluginsMarketplaceUpdate.messageType: self = .pluginsMarketplaceUpdate(try PluginsMarketplaceUpdate(from: decoder))
        case PluginsDetailsRequest.messageType: self = .pluginsDetails(try PluginsDetailsRequest(from: decoder))
        case PluginsOptionsRequest.messageType: self = .pluginsOptions(try PluginsOptionsRequest(from: decoder))
        case PluginsConfigure.messageType: self = .pluginsConfigure(try PluginsConfigure(from: decoder))
        default: throw unknownType(type, direction: "client", decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .chatNew(let m): try m.encode(to: encoder)
        case .chatOpen(let m): try m.encode(to: encoder)
        case .chatStop(let m): try m.encode(to: encoder)
        case .chatAlias(let m): try m.encode(to: encoder)
        case .chatRemove(let m): try m.encode(to: encoder)
        case .messageSend(let m): try m.encode(to: encoder)
        case .turnStop(let m): try m.encode(to: encoder)
        case .cardAnswer(let m): try m.encode(to: encoder)
        case .filesList(let m): try m.encode(to: encoder)
        case .filesRootsSet(let m): try m.encode(to: encoder)
        case .filesEdited(let m): try m.encode(to: encoder)
        case .artifactOpened(let m): try m.encode(to: encoder)
        case .gatewayStop(let m): try m.encode(to: encoder)
        case .sessionRenew(let m): try m.encode(to: encoder)
        case .filesSearch(let m): try m.encode(to: encoder)
        case .sessionMode(let m): try m.encode(to: encoder)
        case .sessionLog(let m): try m.encode(to: encoder)
        case .serviceRestart(let m): try m.encode(to: encoder)
        case .servicesRestartAll(let m): try m.encode(to: encoder)
        case .sessionsClear(let m): try m.encode(to: encoder)
        case .chatUnqueue(let m): try m.encode(to: encoder)
        case .viewerSettings(let m): try m.encode(to: encoder)
        case .viewerResult(let m): try m.encode(to: encoder)
        case .spaceRefresh(let m): try m.encode(to: encoder)
        case .spaceRename(let m): try m.encode(to: encoder)
        case .spaceRemove(let m): try m.encode(to: encoder)
        case .modelSet(let m): try m.encode(to: encoder)
        case .threadStart(let m): try m.encode(to: encoder)
        case .threadDismiss(let m): try m.encode(to: encoder)
        case .threadClose(let m): try m.encode(to: encoder)
        case .appCallTool(let m): try m.encode(to: encoder)
        case .appMessage(let m): try m.encode(to: encoder)
        case .appContext(let m): try m.encode(to: encoder)
        case .appReload(let m): try m.encode(to: encoder)
        case .mcpList(let m): try m.encode(to: encoder)
        case .mcpToggle(let m): try m.encode(to: encoder)
        case .mcpReconnect(let m): try m.encode(to: encoder)
        case .mcpRemove(let m): try m.encode(to: encoder)
        case .mcpAdd(let m): try m.encode(to: encoder)
        case .mcpSignIn(let m): try m.encode(to: encoder)
        case .mcpSignOut(let m): try m.encode(to: encoder)
        case .mcpToolPolicy(let m): try m.encode(to: encoder)
        case .pluginsList(let m): try m.encode(to: encoder)
        case .pluginsSetEnabled(let m): try m.encode(to: encoder)
        case .pluginsInstall(let m): try m.encode(to: encoder)
        case .pluginsUninstall(let m): try m.encode(to: encoder)
        case .pluginsUpdate(let m): try m.encode(to: encoder)
        case .pluginsMarketplaceAdd(let m): try m.encode(to: encoder)
        case .pluginsMarketplaceUpdate(let m): try m.encode(to: encoder)
        case .pluginsDetails(let m): try m.encode(to: encoder)
        case .pluginsOptions(let m): try m.encode(to: encoder)
        case .pluginsConfigure(let m): try m.encode(to: encoder)
        }
    }
}

/// Any gateway -> app message, decoded on the `type` key. `envelope` exposes
/// the routing fields of whichever case this is.
enum ServerMessage: Codable, Equatable, Sendable {
    case hello(HelloServer)
    case chatList(ChatList)
    case chatState(ChatState)
    case chatHistory(ChatHistory)
    case chatLive(ChatLive)
    case turnStarted(TurnStarted)
    case userText(UserText)
    case textDelta(TextDelta)
    case toolStarted(ToolStarted)
    case toolFinished(ToolFinished)
    case turnFinished(TurnFinished)
    case cardAsk(CardAsk)
    case cardAnswered(CardAnswered)
    case cardCancel(CardCancel)
    case artifactCreated(ArtifactCreated)
    case filesList(FilesList)
    case filesRoots(FilesRoots)
    case statusSet(StatusSet)
    case error(ErrorMessage)
    case contextUsage(ContextUsage)
    case chatCompacted(ChatCompacted)
    case sessionRenewed(SessionRenewed)
    case filesResults(FilesResults)
    case chatNotice(ChatNotice)
    case configStale(ConfigStale)
    case updateAvailable(UpdateAvailable)
    case sessionLogged(SessionLogged)
    case servicesStatus(ServicesStatus)
    case agentStarted(AgentStarted)
    case agentProgress(AgentProgress)
    case agentFinished(AgentFinished)
    case workflowStarted(WorkflowStarted)
    case workflowPhase(WorkflowPhase)
    case workflowFinished(WorkflowFinished)
    case chatQueued(ChatQueued)
    case chatQueue(ChatQueue)
    case chatCommands(ChatCommands)
    case viewerAct(ViewerAct)
    case spacesList(SpacesList)
    case models(Models)
    case threadProposal(ThreadProposal)
    case appOpen(AppOpen)
    case appResult(AppResult)
    case appCancelled(AppCancelled)
    case appCallResult(AppCallResult)
    case mcpServers(McpServers)
    case pluginsState(PluginsStateMessage)
    case pluginsDetails(PluginsDetails)
    case pluginsOptions(PluginsOptions)

    var type: String {
        switch self {
        case .hello: HelloServer.messageType
        case .chatList: ChatList.messageType
        case .chatState: ChatState.messageType
        case .chatHistory: ChatHistory.messageType
        case .chatLive: ChatLive.messageType
        case .turnStarted: TurnStarted.messageType
        case .userText: UserText.messageType
        case .textDelta: TextDelta.messageType
        case .toolStarted: ToolStarted.messageType
        case .toolFinished: ToolFinished.messageType
        case .turnFinished: TurnFinished.messageType
        case .cardAsk: CardAsk.messageType
        case .cardAnswered: CardAnswered.messageType
        case .cardCancel: CardCancel.messageType
        case .artifactCreated: ArtifactCreated.messageType
        case .filesList: FilesList.messageType
        case .filesRoots: FilesRoots.messageType
        case .statusSet: StatusSet.messageType
        case .error: ErrorMessage.messageType
        case .contextUsage: ContextUsage.messageType
        case .chatCompacted: ChatCompacted.messageType
        case .sessionRenewed: SessionRenewed.messageType
        case .filesResults: FilesResults.messageType
        case .chatNotice: ChatNotice.messageType
        case .configStale: ConfigStale.messageType
        case .updateAvailable: UpdateAvailable.messageType
        case .sessionLogged: SessionLogged.messageType
        case .servicesStatus: ServicesStatus.messageType
        case .agentStarted: AgentStarted.messageType
        case .agentProgress: AgentProgress.messageType
        case .agentFinished: AgentFinished.messageType
        case .workflowStarted: WorkflowStarted.messageType
        case .workflowPhase: WorkflowPhase.messageType
        case .workflowFinished: WorkflowFinished.messageType
        case .chatQueued: ChatQueued.messageType
        case .chatQueue: ChatQueue.messageType
        case .chatCommands: ChatCommands.messageType
        case .viewerAct: ViewerAct.messageType
        case .spacesList: SpacesList.messageType
        case .models: Models.messageType
        case .threadProposal: ThreadProposal.messageType
        case .appOpen: AppOpen.messageType
        case .appResult: AppResult.messageType
        case .appCancelled: AppCancelled.messageType
        case .appCallResult: AppCallResult.messageType
        case .mcpServers: McpServers.messageType
        case .pluginsState: PluginsStateMessage.messageType
        case .pluginsDetails: PluginsDetails.messageType
        case .pluginsOptions: PluginsOptions.messageType
        }
    }

    var envelope: Envelope {
        switch self {
        case .hello(let m): m.envelope
        case .chatList(let m): m.envelope
        case .chatState(let m): m.envelope
        case .chatHistory(let m): m.envelope
        case .chatLive(let m): m.envelope
        case .turnStarted(let m): m.envelope
        case .userText(let m): m.envelope
        case .textDelta(let m): m.envelope
        case .toolStarted(let m): m.envelope
        case .toolFinished(let m): m.envelope
        case .turnFinished(let m): m.envelope
        case .cardAsk(let m): m.envelope
        case .cardAnswered(let m): m.envelope
        case .cardCancel(let m): m.envelope
        case .artifactCreated(let m): m.envelope
        case .filesList(let m): m.envelope
        case .filesRoots(let m): m.envelope
        case .statusSet(let m): m.envelope
        case .error(let m): m.envelope
        case .contextUsage(let m): m.envelope
        case .chatCompacted(let m): m.envelope
        case .sessionRenewed(let m): m.envelope
        case .filesResults(let m): m.envelope
        case .chatNotice(let m): m.envelope
        case .configStale(let m): m.envelope
        case .updateAvailable(let m): m.envelope
        case .sessionLogged(let m): m.envelope
        case .servicesStatus(let m): m.envelope
        case .agentStarted(let m): m.envelope
        case .agentProgress(let m): m.envelope
        case .agentFinished(let m): m.envelope
        case .workflowStarted(let m): m.envelope
        case .workflowPhase(let m): m.envelope
        case .workflowFinished(let m): m.envelope
        case .chatQueued(let m): m.envelope
        case .chatQueue(let m): m.envelope
        case .chatCommands(let m): m.envelope
        case .viewerAct(let m): m.envelope
        case .spacesList(let m): m.envelope
        case .models(let m): m.envelope
        case .threadProposal(let m): m.envelope
        case .appOpen(let m): m.envelope
        case .appResult(let m): m.envelope
        case .appCancelled(let m): m.envelope
        case .appCallResult(let m): m.envelope
        case .mcpServers(let m): m.envelope
        case .pluginsState(let m): m.envelope
        case .pluginsDetails(let m): m.envelope
        case .pluginsOptions(let m): m.envelope
        }
    }

    init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case HelloServer.messageType: self = .hello(try HelloServer(from: decoder))
        case ChatList.messageType: self = .chatList(try ChatList(from: decoder))
        case ChatState.messageType: self = .chatState(try ChatState(from: decoder))
        case ChatHistory.messageType: self = .chatHistory(try ChatHistory(from: decoder))
        case ChatLive.messageType: self = .chatLive(try ChatLive(from: decoder))
        case TurnStarted.messageType: self = .turnStarted(try TurnStarted(from: decoder))
        case UserText.messageType: self = .userText(try UserText(from: decoder))
        case TextDelta.messageType: self = .textDelta(try TextDelta(from: decoder))
        case ToolStarted.messageType: self = .toolStarted(try ToolStarted(from: decoder))
        case ToolFinished.messageType: self = .toolFinished(try ToolFinished(from: decoder))
        case TurnFinished.messageType: self = .turnFinished(try TurnFinished(from: decoder))
        case CardAsk.messageType: self = .cardAsk(try CardAsk(from: decoder))
        case CardAnswered.messageType: self = .cardAnswered(try CardAnswered(from: decoder))
        case CardCancel.messageType: self = .cardCancel(try CardCancel(from: decoder))
        case ArtifactCreated.messageType: self = .artifactCreated(try ArtifactCreated(from: decoder))
        case FilesList.messageType: self = .filesList(try FilesList(from: decoder))
        case FilesRoots.messageType: self = .filesRoots(try FilesRoots(from: decoder))
        case StatusSet.messageType: self = .statusSet(try StatusSet(from: decoder))
        case ErrorMessage.messageType: self = .error(try ErrorMessage(from: decoder))
        case ContextUsage.messageType: self = .contextUsage(try ContextUsage(from: decoder))
        case ChatCompacted.messageType: self = .chatCompacted(try ChatCompacted(from: decoder))
        case SessionRenewed.messageType: self = .sessionRenewed(try SessionRenewed(from: decoder))
        case FilesResults.messageType: self = .filesResults(try FilesResults(from: decoder))
        case ChatNotice.messageType: self = .chatNotice(try ChatNotice(from: decoder))
        case ConfigStale.messageType: self = .configStale(try ConfigStale(from: decoder))
        case UpdateAvailable.messageType: self = .updateAvailable(try UpdateAvailable(from: decoder))
        case SessionLogged.messageType: self = .sessionLogged(try SessionLogged(from: decoder))
        case ServicesStatus.messageType: self = .servicesStatus(try ServicesStatus(from: decoder))
        case AgentStarted.messageType: self = .agentStarted(try AgentStarted(from: decoder))
        case AgentProgress.messageType: self = .agentProgress(try AgentProgress(from: decoder))
        case AgentFinished.messageType: self = .agentFinished(try AgentFinished(from: decoder))
        case WorkflowStarted.messageType: self = .workflowStarted(try WorkflowStarted(from: decoder))
        case WorkflowPhase.messageType: self = .workflowPhase(try WorkflowPhase(from: decoder))
        case WorkflowFinished.messageType: self = .workflowFinished(try WorkflowFinished(from: decoder))
        case ChatQueued.messageType: self = .chatQueued(try ChatQueued(from: decoder))
        case ChatQueue.messageType: self = .chatQueue(try ChatQueue(from: decoder))
        case ChatCommands.messageType: self = .chatCommands(try ChatCommands(from: decoder))
        case ViewerAct.messageType: self = .viewerAct(try ViewerAct(from: decoder))
        case SpacesList.messageType: self = .spacesList(try SpacesList(from: decoder))
        case Models.messageType: self = .models(try Models(from: decoder))
        case ThreadProposal.messageType: self = .threadProposal(try ThreadProposal(from: decoder))
        case AppOpen.messageType: self = .appOpen(try AppOpen(from: decoder))
        case AppResult.messageType: self = .appResult(try AppResult(from: decoder))
        case AppCancelled.messageType: self = .appCancelled(try AppCancelled(from: decoder))
        case AppCallResult.messageType: self = .appCallResult(try AppCallResult(from: decoder))
        case McpServers.messageType: self = .mcpServers(try McpServers(from: decoder))
        case PluginsStateMessage.messageType: self = .pluginsState(try PluginsStateMessage(from: decoder))
        case PluginsDetails.messageType: self = .pluginsDetails(try PluginsDetails(from: decoder))
        case PluginsOptions.messageType: self = .pluginsOptions(try PluginsOptions(from: decoder))
        default: throw unknownType(type, direction: "server", decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .chatList(let m): try m.encode(to: encoder)
        case .chatState(let m): try m.encode(to: encoder)
        case .chatHistory(let m): try m.encode(to: encoder)
        case .chatLive(let m): try m.encode(to: encoder)
        case .turnStarted(let m): try m.encode(to: encoder)
        case .userText(let m): try m.encode(to: encoder)
        case .textDelta(let m): try m.encode(to: encoder)
        case .toolStarted(let m): try m.encode(to: encoder)
        case .toolFinished(let m): try m.encode(to: encoder)
        case .turnFinished(let m): try m.encode(to: encoder)
        case .cardAsk(let m): try m.encode(to: encoder)
        case .cardAnswered(let m): try m.encode(to: encoder)
        case .cardCancel(let m): try m.encode(to: encoder)
        case .artifactCreated(let m): try m.encode(to: encoder)
        case .filesList(let m): try m.encode(to: encoder)
        case .filesRoots(let m): try m.encode(to: encoder)
        case .statusSet(let m): try m.encode(to: encoder)
        case .error(let m): try m.encode(to: encoder)
        case .contextUsage(let m): try m.encode(to: encoder)
        case .chatCompacted(let m): try m.encode(to: encoder)
        case .sessionRenewed(let m): try m.encode(to: encoder)
        case .filesResults(let m): try m.encode(to: encoder)
        case .chatNotice(let m): try m.encode(to: encoder)
        case .configStale(let m): try m.encode(to: encoder)
        case .updateAvailable(let m): try m.encode(to: encoder)
        case .sessionLogged(let m): try m.encode(to: encoder)
        case .servicesStatus(let m): try m.encode(to: encoder)
        case .agentStarted(let m): try m.encode(to: encoder)
        case .agentProgress(let m): try m.encode(to: encoder)
        case .agentFinished(let m): try m.encode(to: encoder)
        case .workflowStarted(let m): try m.encode(to: encoder)
        case .workflowPhase(let m): try m.encode(to: encoder)
        case .workflowFinished(let m): try m.encode(to: encoder)
        case .chatQueued(let m): try m.encode(to: encoder)
        case .chatQueue(let m): try m.encode(to: encoder)
        case .chatCommands(let m): try m.encode(to: encoder)
        case .viewerAct(let m): try m.encode(to: encoder)
        case .spacesList(let m): try m.encode(to: encoder)
        case .models(let m): try m.encode(to: encoder)
        case .threadProposal(let m): try m.encode(to: encoder)
        case .appOpen(let m): try m.encode(to: encoder)
        case .appResult(let m): try m.encode(to: encoder)
        case .appCancelled(let m): try m.encode(to: encoder)
        case .appCallResult(let m): try m.encode(to: encoder)
        case .mcpServers(let m): try m.encode(to: encoder)
        case .pluginsState(let m): try m.encode(to: encoder)
        case .pluginsDetails(let m): try m.encode(to: encoder)
        case .pluginsOptions(let m): try m.encode(to: encoder)
        }
    }
}
