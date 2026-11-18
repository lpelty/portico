import Foundation

/// Team knowledge in the strip (v0.27, Bill's ZJ3): what each notice says
/// at each width, from one `team.state` snapshot. Pure words; the view
/// draws them and `AppModel` acts on a click.
///
/// A notice with a button stays as long as its cause does. The quiet line
/// for the last arrival shows beside them, never instead of them, and
/// leaves when the next message is sent.
struct TeamNotice: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        /// Someone shared files the person does not have: the only notice with Get.
        case get
        case getting
        case twoVersions
        case unreachable
        /// The last arrival the agent can now use: quiet, no button.
        case latest
    }

    enum Tone: Sendable {
        case accent, wait, quiet
    }

    var kind: Kind
    var tone: Tone
    /// An SF Symbol name.
    var icon: String
    /// The longest form: first names and counts, never a file name.
    var full: String
    /// The words with less room.
    var short: String
    /// The button's word, when the notice has one.
    var button: String? = nil
    /// The quiet line's link ("See what's new").
    var link: String? = nil
    /// The hover: a title, and a second line naming the files and what a click does.
    var helpTitle: String
    var helpDetail: String? = nil

    var id: String { kind.rawValue }

    var help: String {
        [helpTitle, helpDetail].compactMap { $0 }.joined(separator: "\n")
    }

    /// The words at a fit; `nil` is the icon alone.
    func words(at fit: TeamStripPresentation.Fit) -> String? {
        switch fit {
        case .full: full
        case .quietIcon: kind == .latest ? nil : full
        case .short: kind == .latest ? nil : short
        case .icons: nil
        }
    }
}

struct TeamStripPresentation: Equatable, Sendable {
    /// How much the team notices say. The rest of the strip shortens first;
    /// then the quiet line folds to its icon, then the words shorten, then
    /// every notice is its icon. A notice never disappears.
    enum Fit: Int, CaseIterable, Comparable, Sendable {
        case full, quietIcon, short, icons

        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
    }

    /// Left to right: the quiet line, then the notices that need the person.
    var notices: [TeamNotice] = []

    static let none = TeamStripPresentation()

    enum Measure {
        static let iconSize: CGFloat = 11
        static let pillPadding: CGFloat = 8
        static let iconGap: CGFloat = 6
        static let buttonGap: CGFloat = 8
        static let buttonPadding: CGFloat = 7
        static let linkGap: CGFloat = 8
    }

    /// The width one notice needs at a fit.
    static func width(_ notice: TeamNotice, at fit: Fit, metrics: StatusStripPresentation.Metrics) -> CGFloat {
        let icon = metrics.symbol(.init(name: notice.icon, size: Measure.iconSize))
        let padded = notice.tone == .quiet ? 0 : 2 * Measure.pillPadding
        guard let words = notice.words(at: fit) else { return icon + padded }
        var width = icon + Measure.iconGap + metrics.text(words) + padded
        if let button = notice.button {
            width += Measure.buttonGap + metrics.text(button) + 2 * Measure.buttonPadding
        }
        if let link = notice.link {
            width += Measure.linkGap + metrics.text(link)
        }
        return width
    }

    /// Every notice's width at a fit, for the strip's own sum.
    func widths(at fit: Fit, metrics: StatusStripPresentation.Metrics) -> [CGFloat] {
        notices.map { Self.width($0, at: fit, metrics: metrics) }
    }

    // MARK: words

    /// "Priya", "Priya and Sam", "3 people".
    static func people(_ people: [TeamPerson]) -> String {
        var names: [String] = []
        for person in people where !names.contains(person.short) { names.append(person.short) }
        switch names.count {
        case 0: return "the team"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) people"
        }
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// The deployment's name for it inside a sentence: "team knowledge".
    static func inSentence(_ label: String) -> String {
        guard let first = label.first else { return label }
        // An all-capitals first word is a name ("ACME notes"); leave it.
        let word = label.prefix { !$0.isWhitespace }
        if word.count > 1, word == word.uppercased() { return label }
        return first.lowercased() + label.dropFirst()
    }

    static func names(_ paths: [String]) -> String {
        paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
    }

    /// The strip's notices for a snapshot. `quietGone` is the arrival whose
    /// quiet line has left (a message was sent since); `time` words a UTC stamp.
    static func make(
        state: TeamState?, team: TeamHello?, quietGone: String?,
        time: (String) -> String? = TeamStripPresentation.clock
    ) -> TeamStripPresentation {
        guard let state, let team else { return .none }
        var notices: [TeamNotice] = []

        if let latest = state.latest, latest.id != quietGone {
            notices.append(quiet(latest, time: time))
        }
        if state.reach == .unreachable || state.reach == .refused {
            let title = "Can't reach \(inSentence(team.label))"
            var detail = state.reachReason
            if let at = state.lastOkAt.flatMap(time) {
                detail = [detail, "Last checked \(at)"].compactMap { $0 }.joined(separator: " · ")
            }
            notices.append(TeamNotice(
                kind: .unreachable, tone: .wait, icon: "icloud.slash", full: title, short: title,
                button: "Try again", helpTitle: title, helpDetail: detail))
        }
        let conflicts = state.files.filter { $0.conflict != nil }
        if !conflicts.isEmpty {
            let title = conflicts.count == 1 ? "1 file has two versions" : "\(conflicts.count) files have two versions"
            notices.append(TeamNotice(
                kind: .twoVersions, tone: .wait, icon: "doc.on.doc", full: title, short: title, button: "Review",
                helpTitle: title, helpDetail: "\(names(conflicts.map(\.path))) · click to review"))
        }
        if let getting = state.getting, !getting.isEmpty {
            let count = state.waiting.filter { getting.contains($0.id) }.reduce(0) { $0 + $1.files.count }
            let title = count > 0 ? "Getting \(files(count))…" : "Getting files…"
            notices.append(TeamNotice(
                kind: .getting, tone: .accent, icon: "arrow.triangle.2.circlepath", full: title, short: title,
                helpTitle: title))
        } else if !state.waiting.isEmpty {
            let count = state.waiting.reduce(0) { $0 + $1.files.count }
            let from = people(state.waiting.map(\.by))
            let title = "\(team.label) · \(count) new from \(from)"
            var detail = names(state.waiting.flatMap(\.files)) + " · click to get"
            let notes = state.waiting.compactMap(\.note).filter { !$0.isEmpty }
            if !notes.isEmpty { detail += "\n" + notes.map { "“\($0)”" }.joined(separator: "\n") }
            notices.append(TeamNotice(
                kind: .get, tone: .accent, icon: "person.2", full: title, short: "\(count) new from team",
                button: "Get", helpTitle: title, helpDetail: detail))
        }
        return TeamStripPresentation(notices: notices)
    }

    private static func quiet(_ latest: TeamLatest, time: (String) -> String?) -> TeamNotice {
        let count = latest.files.count
        let detail = names(latest.files)
        switch latest.kind {
        case .new:
            let from = people((latest.shares ?? []).map(\.by))
            let title = "\(count) new \(count == 1 ? "file" : "files") from \(from) \(count == 1 ? "is" : "are") ready"
            return TeamNotice(
                kind: .latest, tone: .quiet, icon: "checkmark", full: title, short: title, link: "See what's new",
                helpTitle: title, helpDetail: detail)
        case .changed:
            let by = latest.by ?? []
            let who = Set(by.map(\.short)).count
            var title = who == 1
                ? "\(by[0].short) changed \(files(count))"
                : "\(count) team \(count == 1 ? "change" : "changes")"
            if let at = time(latest.at) { title += " · \(at)" }
            return TeamNotice(
                kind: .latest, tone: .quiet, icon: "person.2", full: title,
                short: "\(count) team \(count == 1 ? "change" : "changes")", link: "See what changed",
                helpTitle: title, helpDetail: detail)
        }
    }

    /// "2:31 PM" for a UTC stamp, in this Mac's time; `nil` when it cannot be read.
    static func clock(_ stamp: String) -> String? {
        SessionTime.parse(stamp).map { MessageTime.short($0) }
    }

    /// The line the conversation gets, once per arrival.
    static func conversationLine(_ latest: TeamLatest, label: String, time: (String) -> String? = TeamStripPresentation.clock) -> String {
        let notice = quiet(latest, time: time)
        var line = "\(label) · \(notice.full)"
        if latest.kind == .new, let at = time(latest.at) { line += " · \(at)" }
        return line
    }
}

extension AppModel {
    /// `hello.team`: the deployment has team knowledge. `nil`, the app shows none of it.
    var team: TeamHello? { hello?.team }

    /// The strip's team notices; none without `hello.team`.
    var teamStrip: TeamStripPresentation {
        TeamStripPresentation.make(state: teamState, team: team, quietGone: teamQuietGone)
    }

    /// A team path as the viewer opens it: absolute as it is, else inside the deployment's first root.
    func teamAbsolutePath(_ path: String) -> String? {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        guard let root = hello?.roots.first else { return nil }
        return URL(fileURLWithPath: (root.path as NSString).expandingTildeInPath).appendingPathComponent(path).path
    }

    /// A new id for a `team.*` request; its `team.result` answers by it.
    func teamRequestId() -> String { "team-" + UUID().uuidString.lowercased() }

    /// A click on a strip notice (or its button).
    func teamAct(_ kind: TeamNotice.Kind) {
        guard let state = teamState else { return }
        switch kind {
        case .get:
            guard !state.waiting.isEmpty, teamGetPending == nil else { return }
            // The shares the person was shown; one that arrives after the click waits for its own.
            let id = teamRequestId()
            teamGetPending = id
            send(.teamGet(TeamGet(shares: state.waiting.map(\.id), id: id)))
        case .getting:
            break
        case .unreachable:
            send(.teamCheck(TeamCheck()))
        case .twoVersions:
            if let file = state.files.first(where: { $0.conflict != nil }) { teamOpen(file.path) }
        case .latest:
            if let latest = state.latest { teamOpen(latest.summary) }
        }
    }

    /// Open a team file in the shown chat's viewer.
    func teamOpen(_ path: String) {
        guard let absolute = teamAbsolutePath(path), let chat = shownChat else { return }
        showEditedFile(path: absolute, chat: chat)
        if let row = teamState?.files.first(where: { $0.path == path }), row.unread {
            send(.teamSeen(TeamSeen(path: row.path, rev: row.rev)))
        }
    }

    /// A new snapshot: the conversation gets one line per arrival, and a new arrival's quiet line shows again.
    func teamStateArrived(_ state: TeamState) {
        teamCatchUp()
    }

    /// Write what the conversation is owed: the latest arrival's line, once, and any line that was held.
    /// With no conversation shown nothing is marked as written; it is tried again when one is shown
    /// (a selection, the next snapshot).
    func teamCatchUp() {
        guard let chat = shownChat, let team else { return }
        if let latest = teamState?.latest, teamDefaults.string(forKey: Self.teamLatestShownKey) != latest.id {
            teamDefaults.set(latest.id, forKey: Self.teamLatestShownKey)
            appendNotice(TeamStripPresentation.conversationLine(latest, label: team.label), to: chat)
        }
        let held = teamHeldNotices
        teamHeldNotices = []
        for line in held { appendNotice(line, to: chat) }
    }

    /// A request's outcome: what was not done is said in the conversation, in the deployment's words.
    func teamResultArrived(_ result: TeamResult) {
        if result.id == teamGetPending { teamGetPending = nil }
        guard !result.ok, let team else { return }
        var reasons = (result.failed ?? []).map(\.reason)
        if reasons.isEmpty, let reason = result.reason { reasons = [reason] }
        var seen: [String] = []
        for reason in reasons where !seen.contains(reason) { seen.append(reason) }
        guard !seen.isEmpty else { return }
        // With no conversation shown the line waits for one, so a failure is never said nowhere.
        teamHeldNotices.append("\(team.label) · \(seen.joined(separator: " · "))")
        teamCatchUp()
    }

    static let teamLatestShownKey = "team.latestShown"
}

/// A team file's one mark on its row (v0.27, Bill's ZJ4): the icon, its
/// colour, the hover's two lines, and what a click on the mark does.
/// Out is up and to the right, in is down and to the left; colour is the
/// state: grey in step, accent moving or unread, amber needs the person.
struct TeamMarkPresentation: Equatable, Sendable {
    enum Tone: Sendable {
        case grey, accent, wait
    }

    enum Click: Equatable, Sendable {
        case nothing
        /// Opens "Goes to the team in 9 min" with Send now and Pause.
        case sendOrPause
        case resume
        case open
    }

    var icon: String
    var tone: Tone
    var title: String
    var detail: String
    var click: Click

    var help: String { "\(title)\n\(detail)" }

    /// What the words need from the clock; the tests give their own.
    struct Words: Sendable {
        /// "2:14 PM" today, "Yesterday 2:14 PM", "Nov 6, 2:14 PM".
        var time: @Sendable (String) -> String?
        /// "Nov 14".
        var day: @Sendable (String) -> String?
        var isToday: @Sendable (String) -> Bool
        /// Whole minutes until a stamp, rounded up; `nil` when it is past or unreadable.
        var minutesUntil: @Sendable (String) -> Int?

        static let system = Words(
            time: { SessionTime.parse($0).map { MessageTime.short($0) } },
            day: { SessionTime.parse($0).map { SessionTime.day($0, withYear: false, calendar: .current, locale: .current) } },
            isToday: { SessionTime.parse($0).map { Calendar.current.isDateInToday($0) } ?? false },
            minutesUntil: { stamp in
                guard let date = SessionTime.parse(stamp) else { return nil }
                let seconds = date.timeIntervalSinceNow
                return seconds > 0 ? Int((seconds / 60).rounded(.up)) : nil
            })
    }

    /// "Goes to the team in 9 min"; "at the next check" once that time is past.
    static func goes(nextCheckAt: String, words: Words) -> String {
        guard let minutes = words.minutesUntil(nextCheckAt) else { return "Goes to the team at the next check" }
        return "Goes to the team in \(minutes) min"
    }

    /// The menu's "in 9 min" beside Send changes now.
    static func wait(nextCheckAt: String, words: Words) -> String? {
        words.minutesUntil(nextCheckAt).map { "in \($0) min" }
    }

    static func make(_ file: TeamFile, state: TeamState, words: Words = .system) -> TeamMarkPresentation {
        func time(_ stamp: String?) -> String { stamp.flatMap(words.time) ?? "" }
        func day(_ stamp: String?) -> String { stamp.flatMap(words.day) ?? "" }
        func todayTime(_ stamp: String) -> String {
            (words.isToday(stamp) ? "today " : "") + time(stamp)
        }
        // While the team cannot be reached nothing claims to be in step: it says when it was last checked.
        let stale = state.reach == .ok || state.reach == .never
            ? nil : state.lastOkAt.map { "last checked \(todayTime($0))" }
        func with(_ parts: [String?]) -> String { (parts + [stale]).compactMap { $0 }.joined(separator: " · ") }

        switch file.mark {
        case .twoVersions:
            return .init(
                icon: "doc.on.doc", tone: .wait, title: "Your version and the team's differ",
                detail: "Yours is saved on this Mac · open to choose", click: .open)
        case .paused:
            let waiting = file.pending.map { "Changes waiting since \(time($0.since))" } ?? "Nothing waiting"
            return .init(
                icon: "pause", tone: .wait, title: "Paused by you since \(time(file.paused?.since))",
                detail: "\(waiting) · click to resume", click: .resume)
        case .goingOut:
            return .init(
                icon: file.direction == .out ? "arrow.up.right" : "arrow.down.left", tone: .accent,
                title: goes(nextCheckAt: state.nextCheckAt, words: words),
                detail: "Changed \(time(file.pending?.since)) · click to send now or pause", click: .sendOrPause)
        case .unread:
            if let by = file.changedBy, let at = file.changedAt {
                let when = words.isToday(at) ? "Today \(time(at))" : time(at)
                return .init(
                    icon: "arrow.down.left", tone: .accent, title: "Changed by \(by.name)",
                    detail: "\(when) · first shared by \(file.sharedBy.short), \(day(file.sharedAt))", click: .nothing)
            }
            return .init(
                icon: "arrow.down.left", tone: .accent, title: "From \(file.sharedBy.name)",
                detail: "Shared \(day(file.sharedAt))", click: .nothing)
        case .inStep(.out):
            return .init(
                icon: "arrow.up.right", tone: .grey, title: "Shared with the team",
                detail: with(["Since \(day(file.sharedAt))", file.sentAt.map { "last sent \(todayTime($0))" }]),
                click: .nothing)
        case .inStep(.in):
            return .init(
                icon: "arrow.down.left", tone: .grey, title: "From \(file.sharedBy.name)",
                detail: with(["Shared \(day(file.sharedAt))", file.changedAt.map { "last change \(day($0))" }]),
                click: .nothing)
        }
    }
}

/// The row's menu for a team file (ZJ1): what each state offers. An item that does not apply is absent, never greyed.
struct TeamFileMenu: Equatable, Sendable {
    var sendNow = false
    var pause = false
    var resume = false
    var stop = true

    static func make(_ file: TeamFile) -> TeamFileMenu {
        if file.conflict != nil {
            // Two versions: the person chooses first. Stop is refused by the gateway and opens the file.
            return TeamFileMenu()
        }
        if file.paused != nil { return TeamFileMenu(resume: true) }
        return TeamFileMenu(sendNow: file.pending != nil, pause: true)
    }
}

extension AppModel {
    /// The team file at an absolute path, when it is under an agreement on this Mac.
    func teamFile(at absolutePath: String) -> TeamFile? {
        guard team != nil, let state = teamState else { return nil }
        return state.files.first { teamAbsolutePath($0.path) == absolutePath }
    }

    func teamSendNow(_ file: TeamFile) {
        send(.teamSendNow(TeamSendNow(paths: [file.path], id: teamRequestId())))
    }

    func teamSetPaused(_ file: TeamFile, _ paused: Bool) {
        send(.teamSendingSet(TeamSendingSet(paths: [file.path], paused: paused, id: teamRequestId())))
    }

    /// Stop syncing. With two versions the person chooses first: the file opens on its banner instead.
    func teamStop(_ file: TeamFile) {
        if file.conflict != nil {
            teamOpen(file.path)
            if let chat = shownChat, let team { appendNotice("\(team.label) · Choose a version first", to: chat) }
            return
        }
        send(.teamStop(TeamStop(paths: [file.path], id: teamRequestId())))
    }

    func teamSetInterval(_ minutes: Int) {
        send(.teamIntervalSet(TeamIntervalSet(minutes: minutes, id: teamRequestId())))
    }

    /// The person opened a team file: its unread mark clears for the version they opened.
    func teamOpened(absolutePath: String) {
        guard let file = teamFile(at: absolutePath), file.unread else { return }
        send(.teamSeen(TeamSeen(path: file.path, rev: file.rev)))
    }
}

/// The bar over a team file in the viewer (v0.27): two versions with the
/// choice (Bill's ZJ6), or a change that arrived by itself (ZJ1).
struct TeamViewerBar: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `readingMine`: the viewer shows the person's saved version, not the team's.
        case twoVersions(readingMine: Bool)
        case changed
    }

    var kind: Kind
    var text: String
    /// The row the bar is about.
    var file: TeamFile

    static let useMine = "Use my version"
    static let useTeam = "Use the team's version"
    static let compare = "Compare"
    static let seeChanged = "See what changed"
    static let stop = "Stop syncing"

    /// The bar for the file the viewer shows (`path`, as the rows name it), if it needs one.
    static func make(path: String, state: TeamState?, words: TeamMarkPresentation.Words = .system) -> TeamViewerBar? {
        guard let state else { return nil }
        func time(_ stamp: String?) -> String { stamp.flatMap(words.time) ?? "" }
        func who(_ file: TeamFile) -> String {
            [file.changedBy?.short, file.changedAt.flatMap(words.time)].compactMap { $0 }.joined(separator: ", ")
        }
        for file in state.files {
            guard let conflict = file.conflict else { continue }
            let team = who(file).isEmpty ? "" : " (\(who(file)))"
            if file.path == path {
                return TeamViewerBar(
                    kind: .twoVersions(readingMine: false),
                    text: "This file has two versions. You are reading the team's version\(team). "
                        + "Your version (\(time(conflict.mine.at))) was not sent and is saved on this Mac.",
                    file: file)
            }
            if conflict.mine.path == path {
                return TeamViewerBar(
                    kind: .twoVersions(readingMine: true),
                    text: "This file has two versions. You are reading your version (\(time(conflict.mine.at))), "
                        + "which was not sent and is saved on this Mac. The team's version\(team) is in the file's place.",
                    file: file)
            }
        }
        guard let file = state.files.first(where: { $0.path == path }), file.summary != nil,
              let by = file.changedBy, let at = file.changedAt
        else { return nil }
        let when = (words.isToday(at) ? "today at " : "") + time(at)
        return TeamViewerBar(
            kind: .changed, text: "\(by.short) changed this file \(when). It updated here by itself.", file: file)
    }
}

extension AppModel {
    /// The team bar for what a chat's viewer shows.
    func teamViewerBar(chat: Int) -> TeamViewerBar? {
        guard team != nil, let location = current[chat]?.location else { return nil }
        return TeamViewerBar.make(path: teamPath(forAbsolute: location), state: teamState)
    }

    /// Choose between two versions; refused by the gateway if the team's version changed meanwhile.
    func teamResolve(_ file: TeamFile, use: TeamResolve.Use) {
        guard let conflict = file.conflict else { return }
        send(.teamResolve(TeamResolve(path: file.path, conflict: conflict.id, use: use, id: teamRequestId())))
        // Either way the file at its own path is what remains: show it.
        teamOpen(file.path)
    }

    /// Compare: the viewer goes to the other version; the bar says which one is being read.
    func teamCompare(_ bar: TeamViewerBar) {
        guard case .twoVersions(let readingMine) = bar.kind, let conflict = bar.file.conflict else { return }
        teamOpen(readingMine ? bar.file.path : conflict.mine.path)
    }
}
