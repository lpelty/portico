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
            guard !state.waiting.isEmpty else { return }
            // The shares the person was shown; one that arrives after the click waits for its own.
            send(.teamGet(TeamGet(shares: state.waiting.map(\.id), id: teamRequestId())))
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
        guard let latest = state.latest, let team else { return }
        guard teamDefaults.string(forKey: Self.teamLatestShownKey) != latest.id else { return }
        teamDefaults.set(latest.id, forKey: Self.teamLatestShownKey)
        if let chat = shownChat {
            appendNotice(TeamStripPresentation.conversationLine(latest, label: team.label), to: chat)
        }
    }

    /// A request's outcome: what was not done is said in the conversation, in the deployment's words.
    func teamResultArrived(_ result: TeamResult) {
        guard !result.ok, let chat = shownChat, let team else { return }
        var reasons = (result.failed ?? []).map(\.reason)
        if reasons.isEmpty, let reason = result.reason { reasons = [reason] }
        var seen: [String] = []
        for reason in reasons where !seen.contains(reason) { seen.append(reason) }
        guard !seen.isEmpty else { return }
        appendNotice("\(team.label) · \(seen.joined(separator: " · "))", to: chat)
    }

    static let teamLatestShownKey = "team.latestShown"
}
