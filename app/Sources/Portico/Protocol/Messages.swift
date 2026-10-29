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

    enum CodingKeys: String, CodingKey {
        case name, accent, icon
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

    enum CodingKeys: String, CodingKey {
        case chat, folder, alias, state, created, title, ended, logged, parent, compactions, mode, unlogged
        case contextPercent = "context_percent"
        case loggedAt = "logged_at"
        case lastReply = "last_reply"
    }

    /// `unlogged`, absent read as false.
    var hasUnloggedWork: Bool { unlogged ?? false }
}

/// What a service check last said (v0.4).
enum ServiceState: String, Codable, Sendable {
    case up, down, checking
}

/// One of the deployment's services as the gateway last checked it
/// (`services.status`, v0.4). Portico draws it; it never knows what it is.
struct Service: Codable, Equatable, Sendable, Identifiable {
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
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case `protocol`, id, ts
        case appVersion = "app_version"
    }
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

/// Change the session's permission mode; answered with `chat.state`
/// carrying `mode`.
struct SessionMode: Codable, Equatable, Sendable {
    static let messageType = "session.mode"
    var chat: Int
    var mode: PermissionMode
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
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case `protocol`, epoch, brand, actions, roots, commands, capabilities, presentation, chat, id, seq, ts
        case gatewayVersion = "gateway_version"
        case canLog = "can_log"
        case configStale = "config_stale"
        case canUpdate = "can_update"
        case defaultFolder = "default_folder"
        case permissionMode = "permission_mode"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }

    /// One live session at a time (S1), rather than the chat list.
    var isSingle: Bool { presentation == "single" }
}

struct ChatList: Codable, Equatable, Sendable {
    static let messageType = "chat.list"
    var chats: [ChatSummary]
    var chat: Int? = nil
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

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
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

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
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, turn, tool, summary, input, id, seq, ts
        case toolUseId = "tool_use_id"
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
    var id: String? = nil
    var seq: Int? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case chat, turn, ok, summary, permission, note, id, seq, ts
        case toolUseId = "tool_use_id"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: seq) }
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
    case artifactOpened(ArtifactOpened)
    case gatewayStop(GatewayStop)
    case sessionRenew(SessionRenew)
    case filesSearch(FilesSearch)
    case sessionMode(SessionMode)
    case sessionLog(SessionLog)
    case serviceRestart(ServiceRestart)
    case servicesRestartAll(ServicesRestartAll)

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
        case .artifactOpened: ArtifactOpened.messageType
        case .gatewayStop: GatewayStop.messageType
        case .sessionRenew: SessionRenew.messageType
        case .filesSearch: FilesSearch.messageType
        case .sessionMode: SessionMode.messageType
        case .sessionLog: SessionLog.messageType
        case .serviceRestart: ServiceRestart.messageType
        case .servicesRestartAll: ServicesRestartAll.messageType
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
        case ArtifactOpened.messageType: self = .artifactOpened(try ArtifactOpened(from: decoder))
        case GatewayStop.messageType: self = .gatewayStop(try GatewayStop(from: decoder))
        case SessionRenew.messageType: self = .sessionRenew(try SessionRenew(from: decoder))
        case FilesSearch.messageType: self = .filesSearch(try FilesSearch(from: decoder))
        case SessionMode.messageType: self = .sessionMode(try SessionMode(from: decoder))
        case SessionLog.messageType: self = .sessionLog(try SessionLog(from: decoder))
        case ServiceRestart.messageType: self = .serviceRestart(try ServiceRestart(from: decoder))
        case ServicesRestartAll.messageType: self = .servicesRestartAll(try ServicesRestartAll(from: decoder))
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
        case .artifactOpened(let m): try m.encode(to: encoder)
        case .gatewayStop(let m): try m.encode(to: encoder)
        case .sessionRenew(let m): try m.encode(to: encoder)
        case .filesSearch(let m): try m.encode(to: encoder)
        case .sessionMode(let m): try m.encode(to: encoder)
        case .sessionLog(let m): try m.encode(to: encoder)
        case .serviceRestart(let m): try m.encode(to: encoder)
        case .servicesRestartAll(let m): try m.encode(to: encoder)
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
        }
    }
}
