import Foundation

// Team knowledge (v0.27, `team.v1`): what a gateway whose deployment has it
// says to the app, and what the app asks. The deployment makes every
// identifier here (`rev`, a share's `id`, a conflict's `id`, an arrival's
// `id`); the app hands them back and never reads them.

/// `hello.team`: the deployment has team knowledge. Absent, the app shows none of it.
struct TeamHello: Codable, Equatable, Sendable {
    var label: String
    var folder: String
    var intervals: [Int]
}

/// `name` is the display name; `short` is what the strip uses. The app never shortens a name.
struct TeamPerson: Codable, Equatable, Sendable, Hashable {
    var name: String
    var short: String
}

/// One share: who, which files (names in `waiting`, paths in `latest`), and its note.
struct TeamShare: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var by: TeamPerson
    var files: [String]
    var note: String? = nil
}

/// The last arrival the agent can now use. One line in the conversation per `id`.
struct TeamLatest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case new, changed
    }

    var id: String
    var kind: Kind
    var at: String
    var summary: String
    var files: [String]
    var shares: [TeamShare]? = nil
    var by: [TeamPerson]? = nil
}

/// One file under an agreement on this Mac. Each fact stands alone; `mark` derives the one icon.
struct TeamFile: Codable, Equatable, Sendable, Identifiable {
    enum Direction: String, Codable, Equatable, Sendable {
        case `in`, out
    }

    struct Since: Codable, Equatable, Sendable {
        var since: String
    }

    /// Two versions: the row's `path` holds the team's, `mine.path` the person's saved one.
    struct Conflict: Codable, Equatable, Sendable {
        struct Mine: Codable, Equatable, Sendable {
            var path: String
            var at: String
        }

        var id: String
        var mine: Mine
    }

    /// The one mark a row shows, in the order the protocol gives.
    enum Mark: Equatable, Sendable {
        case twoVersions, paused, goingOut, unread
        case inStep(Direction)
    }

    var path: String
    var direction: Direction
    var rev: String
    var sharedBy: TeamPerson
    var sharedAt: String
    var changedBy: TeamPerson? = nil
    var changedAt: String? = nil
    var unread: Bool = false
    var pending: Since? = nil
    var paused: Since? = nil
    var sentAt: String? = nil
    var conflict: Conflict? = nil
    var summary: String? = nil

    var id: String { path }

    var mark: Mark {
        if conflict != nil { return .twoVersions }
        if paused != nil { return .paused }
        if pending != nil { return .goingOut }
        if unread { return .unread }
        return .inStep(direction)
    }

    enum CodingKeys: String, CodingKey {
        case path, direction, rev, unread, pending, paused, conflict, summary
        case sharedBy = "shared_by"
        case sharedAt = "shared_at"
        case changedBy = "changed_by"
        case changedAt = "changed_at"
        case sentAt = "sent_at"
    }
}

/// `team.state`: everything the app draws for team knowledge, in one snapshot. Each replaces the last.
struct TeamState: Codable, Equatable, Sendable {
    static let messageType = "team.state"
    /// In the app's `hello.capabilities` once it can draw this; `team.*` goes only to such an app.
    static let capability = "team.v1"

    enum Reach: String, Codable, Equatable, Sendable {
        case ok, unreachable, refused, never
    }

    var reach: Reach
    var reachReason: String? = nil
    var lastOkAt: String? = nil
    var nextCheckAt: String
    var intervalMinutes: Int
    var waiting: [TeamShare] = []
    var getting: [String]? = nil
    var latest: TeamLatest? = nil
    var files: [TeamFile] = []
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case reach, waiting, getting, latest, files, id, ts
        case reachReason = "reach_reason"
        case lastOkAt = "last_ok_at"
        case nextCheckAt = "next_check_at"
        case intervalMinutes = "interval_minutes"
    }

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }

    /// How many files have two versions: derived, never sent.
    var twoVersions: Int { files.filter { $0.conflict != nil }.count }
}

/// `team.result`: the outcome of a `team.*` request, by its `id`. `ok` only when all of it was done.
struct TeamResult: Codable, Equatable, Sendable {
    static let messageType = "team.result"

    /// What could not be done: a file (`path`) or a share (`share`), and one plain line.
    struct Failure: Codable, Equatable, Sendable {
        var path: String? = nil
        var share: String? = nil
        var reason: String
    }

    var ok: Bool
    var reason: String? = nil
    var failed: [Failure]? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    var envelope: Envelope { Envelope(chat: nil, id: id, seq: nil) }
}

/// `team.share.draft`: the check for personal material on a share being prepared.
/// Each replaces the last for its `id`. With `chat`, the card in that conversation.
struct TeamShareDraft: Codable, Equatable, Sendable {
    static let messageType = "team.share.draft"

    struct Finding: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var path: String
        var text: String
        var location: String
    }

    var rev: String
    var paths: [String]
    var note: String? = nil
    var checking: Bool
    /// The check could not finish: one plain line. The dialog then offers Share anyway.
    var checkError: String? = nil
    var findings: [Finding] = []
    var chat: Int? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()

    enum CodingKeys: String, CodingKey {
        case rev, paths, note, checking, findings, chat, id, ts
        case checkError = "check_error"
    }

    var envelope: Envelope { Envelope(chat: chat, id: id, seq: nil) }
}

// MARK: - app → gateway

/// Get and accept these shares, by the ids the person was shown.
struct TeamGet: Codable, Equatable, Sendable {
    static let messageType = "team.get"
    var shares: [String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Check now.
struct TeamCheck: Codable, Equatable, Sendable {
    static let messageType = "team.check"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Set how often the check runs: one of `hello.team.intervals`.
struct TeamIntervalSet: Codable, Equatable, Sendable {
    static let messageType = "team.interval.set"
    var minutes: Int
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// The person opened this version of the file.
struct TeamSeen: Codable, Equatable, Sendable {
    static let messageType = "team.seen"
    var path: String
    var rev: String
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Send these files' pending changes at once.
struct TeamSendNow: Codable, Equatable, Sendable {
    static let messageType = "team.send_now"
    var paths: [String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Pause or resume sending for these files.
struct TeamSendingSet: Codable, Equatable, Sendable {
    static let messageType = "team.sending.set"
    var paths: [String]
    var paused: Bool
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Stop syncing these files on this Mac.
struct TeamStop: Codable, Equatable, Sendable {
    static let messageType = "team.stop"
    var paths: [String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// Choose between two versions.
struct TeamResolve: Codable, Equatable, Sendable {
    static let messageType = "team.resolve"

    enum Use: String, Codable, Equatable, Sendable {
        case mine, team
    }

    var path: String
    var conflict: String
    var use: Use
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// The person chose Share on these files. `id` names the draft from here on.
struct TeamSharePrepare: Codable, Equatable, Sendable {
    static let messageType = "team.share.prepare"
    var paths: [String]
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// The person pressed Share on the draft `id` at `rev`.
struct TeamShareSend: Codable, Equatable, Sendable {
    static let messageType = "team.share.send"
    var rev: String
    var note: String? = nil
    var remove: [String] = []
    /// Share anyway: the person saw `checkError` and chose to share without the check.
    var unchecked: Bool? = nil
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

/// The draft `id` was closed.
struct TeamShareCancel: Codable, Equatable, Sendable {
    static let messageType = "team.share.cancel"
    var id: String? = nil
    var ts: String = ProtocolClock.now()
}

// MARK: - lenient decoding
//
// A gateway may leave out a field whose value is its default (`unread: false`,
// an empty list). The synthesized decoders would refuse the whole snapshot.

extension TeamFile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        direction = try c.decode(Direction.self, forKey: .direction)
        rev = try c.decode(String.self, forKey: .rev)
        sharedBy = try c.decode(TeamPerson.self, forKey: .sharedBy)
        sharedAt = try c.decode(String.self, forKey: .sharedAt)
        changedBy = try c.decodeIfPresent(TeamPerson.self, forKey: .changedBy)
        changedAt = try c.decodeIfPresent(String.self, forKey: .changedAt)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        pending = try c.decodeIfPresent(Since.self, forKey: .pending)
        paused = try c.decodeIfPresent(Since.self, forKey: .paused)
        sentAt = try c.decodeIfPresent(String.self, forKey: .sentAt)
        conflict = try c.decodeIfPresent(Conflict.self, forKey: .conflict)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

extension TeamState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reach = try c.decode(Reach.self, forKey: .reach)
        reachReason = try c.decodeIfPresent(String.self, forKey: .reachReason)
        lastOkAt = try c.decodeIfPresent(String.self, forKey: .lastOkAt)
        nextCheckAt = try c.decode(String.self, forKey: .nextCheckAt)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        waiting = try c.decodeIfPresent([TeamShare].self, forKey: .waiting) ?? []
        getting = try c.decodeIfPresent([String].self, forKey: .getting)
        latest = try c.decodeIfPresent(TeamLatest.self, forKey: .latest)
        files = try c.decodeIfPresent([TeamFile].self, forKey: .files) ?? []
        id = try c.decodeIfPresent(String.self, forKey: .id)
        ts = try c.decode(String.self, forKey: .ts)
    }
}

extension TeamShareDraft {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rev = try c.decode(String.self, forKey: .rev)
        paths = try c.decode([String].self, forKey: .paths)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        checking = try c.decode(Bool.self, forKey: .checking)
        checkError = try c.decodeIfPresent(String.self, forKey: .checkError)
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        chat = try c.decodeIfPresent(Int.self, forKey: .chat)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        ts = try c.decode(String.self, forKey: .ts)
    }
}
