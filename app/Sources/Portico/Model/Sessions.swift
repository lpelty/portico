import Foundation

// MARK: - Single-session presentation (v0.2, S1/S2/S5)

/// The session model the app draws when `hello.presentation` is `single`:
/// one live session (the chat with no `ended`), the ended ones as
/// "Earlier", renewing with the button or `/new`, the context meter, the
/// compaction count and the nudge. A chat is a session (design §2.2), so
/// this is a reading of `chats`, not a second store.
extension AppModel {
    /// What the composer treats as "renew the session" in single presentation.
    static let renewCommand = "/new"
    /// What the composer treats as "log the session without ending it" (v0.4).
    static let logCommand = "/log"

    /// The nudge (S2) shows at this context percent…
    static let nudgePercent: Double = 80
    /// …or after this many compactions.
    static let nudgeCompactions = 2

    /// The gateway presents one live session at a time.
    var isSinglePresentation: Bool { hello?.isSingle == true }

    /// Whether the gateway offers a capability (`sessions`, `files.search`,
    /// `context`); a v0.1 gateway offers none of the v0.2 ones.
    func offers(_ capability: String) -> Bool {
        hello?.capabilities.contains(capability) == true
    }

    /// First launch (V4): no session has started yet in single
    /// presentation (or nothing is known yet), so there is nothing for a
    /// sidebar to list; it appears with the first message of Session 1.
    var awaitingFirstSession: Bool {
        chats.isEmpty && (hello == nil || isSinglePresentation)
    }

    /// The sidebar is drawn: the person has not hidden it and there is a
    /// session for it to show.
    var sidebarShown: Bool { sidebarVisible && !awaitingFirstSession }

    /// The toolbar's title with no session selected: `Session 1` before the
    /// first, `New session` after, `New chat` in multiple presentation.
    var startTitle: String {
        guard isSinglePresentation || hello == nil else { return "New chat" }
        return chats.isEmpty ? "Session 1" : "New session"
    }

    /// The quiet line under the start screen's composer: where the agent
    /// works and how to change it.
    var workingFolderLine: String {
        guard let folder = startFolder else { return "No folder yet · choose one in Settings" }
        return "Working in \(folder.lastPathComponent) · chosen at setup, change it in Settings"
    }

    /// The live session: the newest chat that has not ended.
    var liveSession: ChatSummary? {
        chats.filter { $0.ended == nil }.max { $0.chat < $1.chat }
    }

    /// Ended sessions, newest first.
    var earlierSessions: [ChatSummary] {
        chats.filter { $0.ended != nil }.sorted { $0.chat > $1.chat }
    }

    /// Earlier sessions whose title (or alias, or number) contains `query`.
    func earlierSessions(matching query: String) -> [ChatSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return earlierSessions }
        return earlierSessions.filter { summary in
            [summary.title, summary.alias, String(summary.chat)].compactMap { $0 }
                .contains { $0.lowercased().contains(needle) }
        }
    }

    func summary(of chat: Int) -> ChatSummary? {
        chats.first { $0.chat == chat }
    }

    /// An ended session, opened from "Earlier": read-only.
    func isEnded(chat: Int) -> Bool {
        summary(of: chat)?.ended != nil
    }

    /// Single presentation, after a `chat.list`, with nothing selected.
    /// At launch (no conversation shown yet in this run) the welcome
    /// continues the live session (Y1): its events are asked for without
    /// showing it, so View and the first send find it loaded, and the
    /// viewer is put back only if it was showing something at quit. Once a
    /// conversation has been shown, losing the selection (the gateway
    /// restarted and no longer lists it) goes to the live session, never
    /// back to the welcome: only a launch shows the welcome.
    func openLiveSessionIfNeeded() {
        guard isSinglePresentation, selected == nil, !isStarting, let live = liveSession else { return }
        if conversationShown {
            open(chat: live.chat)
        } else if !openedChats.contains(live.chat) {
            restoreViewerAtLaunch(chat: live.chat)
            load(chat: live.chat)
        }
    }

    /// What the main column shows now (`MainScreen.decide`).
    var mainScreen: MainScreen {
        MainScreen.decide(
            selected: selected, listed: chatsListed, gaveUp: gaveUpConnecting,
            single: isSinglePresentation, live: liveSession?.chat)
    }

    /// The live session the welcome continues (Y1), when it does.
    var continuingSession: Int? {
        if case .continuing(let chat) = mainScreen { return chat }
        return nil
    }

    /// The chat the window is about: the one shown, else the one the
    /// welcome continues. The viewer, the toolbar's title and viewer
    /// button, and the status strip follow it.
    var shownChat: Int? { selected ?? continuingSession }

    /// The connection loop has stopped trying for now (a failure, or the
    /// person stopped the gateway): the welcome shows, saying so, rather
    /// than an empty column waiting for a list that is not coming.
    var gaveUpConnecting: Bool {
        switch connection {
        case .failed: true
        case .disconnected: !autoStartGateway
        case .connecting, .connected: false
        }
    }

    // MARK: the way back (v0.6, Y2)

    /// The bar pinned over the conversation (Y2): shown over an ended
    /// session in single presentation, where the composer would be.
    func showsEarlierBar(chat: Int) -> Bool {
        isSinglePresentation && isEnded(chat: chat)
    }

    /// The bar's "Back to Session M": the live session, when there is one.
    func backTarget(from chat: Int) -> Int? {
        guard showsEarlierBar(chat: chat), let live = liveSession?.chat, live != chat else { return nil }
        return live
    }

    /// The THIS SESSION card is a button to the live session whenever
    /// something else has the main column: an earlier session, or the
    /// welcome. On the live session's own conversation it is just a card.
    func cardOpensLiveSession(live: Int) -> Bool {
        selected != live || documentMode
    }

    /// The card's click: the live session's conversation, out of the
    /// document view if that had the window.
    func openLiveSession(_ live: Int) {
        if documentMode { toggleDocumentView() }
        open(chat: live)
    }

    // MARK: renewing

    /// Renewing is offered in single presentation, by a gateway that
    /// speaks sessions, for a session that has not ended.
    func canRenew(chat: Int) -> Bool {
        isSinglePresentation && offers("sessions") && !isEnded(chat: chat)
    }

    func isRenewing(chat: Int) -> Bool { renewing[chat] != nil }

    func isLogging(chat: Int) -> Bool { logging[chat] != nil }

    /// A renewal or a log is out: the card's buttons wait, and so do sends.
    func isSessionCommandPending(chat: Int) -> Bool {
        isRenewing(chat: chat) || isLogging(chat: chat)
    }

    /// The deployment has a log step (`hello.can_log`).
    var canLog: Bool { hello?.canLog == true }

    /// The gateway can log a live session without ending it: it has a
    /// log step and speaks `session.log` (v0.4 lists `log` in `commands`;
    /// a v0.3 gateway, which only logs on renewal, does not).
    var canLogWithoutEnding: Bool {
        canLog && hello?.commands.contains("log") == true
    }

    /// The card's Log session and `/log` are offered for this session.
    func canLogSession(chat: Int) -> Bool {
        canRenew(chat: chat) && canLogWithoutEnding
    }

    /// Why Log session and `/log` are off for this live session, in the
    /// words the card's hint and the `/log` notice use (v0.5, X2); `nil`
    /// when they work, or when there is no live session to log at all.
    /// A deployment without a log step says so; a v0.3 gateway that has
    /// one but logs only on renewal says that instead.
    func logSessionOffReason(chat: Int) -> String? {
        guard canRenew(chat: chat), !canLogWithoutEnding else { return nil }
        return canLog ? Self.logsOnlyOnRenewal : Self.noLogStep
    }

    static let noLogStep = "No log step is set up for this agent, so Log session is off."
    static let logsOnlyOnRenewal = "This gateway logs only when starting new."

    /// The nudge's "Log and start new": `session.renew`, with `log` when
    /// the deployment has a log step. One at a time per session.
    func renew(chat: Int) {
        renew(chat: chat, log: canLog)
    }

    /// `session.renew` with `log` as given (a deployment without a log
    /// step never logs). One renewal or log at a time per session.
    func renew(chat: Int, log: Bool) {
        guard canRenew(chat: chat), !isSessionCommandPending(chat: chat) else { return }
        let id = Self.requestId()
        renewing[chat] = id
        send(.sessionRenew(SessionRenew(chat: chat, log: log && canLog, id: id)))
    }

    /// The card's New and `/new` (W2): ask "Log Session N first?" only
    /// when skipping the log would lose something — the deployment logs
    /// and the gateway says the session has unlogged work. Otherwise the
    /// next session starts at once, without a pointless log. A v0.3
    /// gateway (no `session.log`, no `unlogged`) logs on renewal as before.
    func requestNew(chat: Int) {
        guard canRenew(chat: chat), !isSessionCommandPending(chat: chat) else { return }
        if canLogWithoutEnding {
            if summary(of: chat)?.hasUnloggedWork == true {
                askingToLog = chat
            } else {
                renew(chat: chat, log: false)
            }
        } else {
            renew(chat: chat, log: canLog)
        }
    }

    /// The W2 dialog's answer: `nil` is Cancel, else whether to log first.
    func answerAskToLog(log: Bool?) {
        guard let chat = askingToLog else { return }
        askingToLog = nil
        if let log { renew(chat: chat, log: log) }
    }

    /// Log session / `/log`: `session.log`, the deployment's log step run
    /// in the live session without ending it. One at a time per session.
    func logSession(chat: Int) {
        guard canLogSession(chat: chat), !isSessionCommandPending(chat: chat) else { return }
        let id = Self.requestId()
        logging[chat] = id
        send(.sessionLog(SessionLog(chat: chat, id: id)))
    }

    /// `session.logged`: the record as the gateway now has it, the log no
    /// longer pending.
    func applyLogged(_ logged: SessionLogged) {
        upsertSummary(logged.chat)
        logging[logged.chat.chat] = nil
        if let id = logged.id {
            logging = logging.filter { $0.value != id }
        }
    }

    /// `session.renewed`: both records as the gateway now has them, the
    /// renew no longer pending, and the conversation on the next session
    /// when it was showing the one that ended (or nothing).
    func applyRenewed(_ renewed: SessionRenewed) {
        upsertSummary(renewed.ended)
        upsertSummary(renewed.next)
        renewing[renewed.ended.chat] = nil
        if let id = renewed.id {
            renewing = renewing.filter { $0.value != id }
        }
        if selected == nil || selected == renewed.ended.chat {
            open(chat: renewed.next.chat)
        }
    }

    // MARK: context and compaction

    /// The context window's fullness: the latest `context.usage`, else
    /// the record's last value; `nil` when neither is known.
    func contextPercent(for chat: Int) -> Double? {
        contextUsage[chat]?.percent ?? summary(of: chat)?.contextPercent
    }

    /// The model's name from the latest `context.usage`, for the strip:
    /// the deployment's display name (`model_name`) when it gives one,
    /// else the model id.
    func modelName(for chat: Int) -> String? {
        if let name = contextUsage[chat]?.displayModel { return name }
        return latestModel
    }

    /// Compactions: the record's count, or the lines in the transcript
    /// when more have happened since the record was listed.
    func compactions(for chat: Int) -> Int {
        let drawn = (transcripts[chat] ?? []).filter { if case .compacted = $0 { true } else { false } }.count
        return max(summary(of: chat)?.compactions ?? 0, drawn)
    }

    /// The nudge (S2): a long session (≥80 % or summarized twice), not
    /// put off with "Not now", not already renewing, and live.
    func shouldNudge(chat: Int) -> Bool {
        guard canRenew(chat: chat), !nudgeDismissed.contains(chat), !isRenewing(chat: chat) else { return false }
        return (contextPercent(for: chat) ?? 0) >= Self.nudgePercent || compactions(for: chat) >= Self.nudgeCompactions
    }

    /// "Not now": the nudge stays away for this session.
    func dismissNudge(chat: Int) {
        nudgeDismissed.insert(chat)
    }
}

extension ContextUsage {
    /// `model_name ?? model`, blanks skipped; `nil` when neither is set.
    var displayModel: String? {
        for candidate in [modelName, model] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }
}

// MARK: - Times as the S frames write them

/// `Started 11:42`, `2 h`, `Tue`: the session card's and the Earlier
/// list's times, from the protocol's ISO-8601 stamps.
enum SessionTime {
    static func parse(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: stamp) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: stamp)
    }

    /// `11:42`, `1:05`: the frames' clock, no am/pm.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }

    /// How long a session has been going: `now`, `12 m`, `2 h`, `3 d`.
    static func age(since start: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    /// How long ago, in words: `just now`, `12 min ago`, `3 h ago`, `2 d ago`.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }

    /// When a session ended, for the bar over it: `12 min ago` within the
    /// hour, `today at 9:14`, `yesterday`, the weekday this week (`on
    /// Tuesday`), else the date (`on Oct 3`).
    static func endedWhen(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 3600 { return ago(date, now: now) }
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock(date, calendar: calendar))" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = (2..<7).contains(days) ? "EEEE" : "MMM d"
        return "on " + formatter.string(from: date)
    }

    /// An Earlier row's time: the clock today, the weekday this week,
    /// else the month and day.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        formatter.dateFormat = (0..<7).contains(days) ? "EEE" : "MMM d"
        return formatter.string(from: date)
    }
}

/// What the session card, the Earlier rows and the S5 divider say for one
/// session; pure, so it is tested without a window.
struct SessionPresentation: Equatable {
    let summary: ChatSummary

    var number: String { "Session \(summary.chat)" }

    /// A session's title from its first message: the first non-blank line,
    /// trimmed to 60 characters (the gateway's `title_from`).
    static func title(from text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return shortened(trimmed) }
        }
        return nil
    }

    /// A line at most 60 characters long; a longer one is cut back to a word
    /// boundary (when one falls in its second half) and ends with "…".
    static func shortened(_ line: String, limit: Int = 60) -> String {
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-")) + "…"
    }

    /// The title, else the alias; `nil` when the session has neither yet.
    var title: String? {
        for candidate in [summary.title, summary.alias] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// `Started 11:42 · Q3 synthesis`.
    func startedLine(calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let start = SessionTime.parse(summary.created) {
            parts.append("Started \(SessionTime.clock(start, calendar: calendar))")
        }
        if let title { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    /// The S5 divider's first line for the session this one followed:
    /// `Session 13 · Interview codebook · logged 11:40`, or `· not logged`.
    func parentLine(calendar: Calendar = .current) -> String {
        var parts = [number]
        if let title { parts.append(title) }
        if summary.logged == true {
            if let ended = SessionTime.parse(summary.ended) {
                parts.append("logged \(SessionTime.clock(ended, calendar: calendar))")
            } else {
                parts.append("logged")
            }
        } else {
            parts.append("not logged")
        }
        return parts.joined(separator: " · ")
    }

    /// The welcome's quiet line while it continues this session (Y1):
    /// `Continuing Session 3 · started 9:14 · last reply 12 min ago`; the
    /// last reply only when the gateway says (v0.6 `last_reply`).
    func continuingLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts = ["Continuing \(number)"]
        if let start = SessionTime.parse(summary.created) {
            parts.append("started \(SessionTime.clock(start, calendar: calendar))")
        }
        if let reply = SessionTime.parse(summary.lastReply) {
            parts.append("last reply \(SessionTime.ago(reply, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    /// The bar over an earlier session (Y2): `Session 2 · ended yesterday · read-only`.
    func endedBarLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts = [number]
        if let ended = SessionTime.parse(summary.ended) {
            parts.append("ended \(SessionTime.endedWhen(ended, now: now, calendar: calendar))")
        } else {
            parts.append("ended")
        }
        parts.append("read-only")
        return parts.joined(separator: " · ")
    }

    /// The divider's second line: `Session 14 · started 11:42`.
    func startedSecondLine(calendar: Calendar = .current) -> String {
        guard let start = SessionTime.parse(summary.created) else { return number }
        return "\(number) · started \(SessionTime.clock(start, calendar: calendar))"
    }
}

// MARK: - What the main column shows (v0.6)

/// The main column's content, decided from state before anything is drawn
/// (Y1): the app never draws a welcome and then jumps away from it.
enum MainScreen: Equatable {
    /// Nothing yet: the gateway has not listed its sessions, so whether
    /// the welcome starts or continues one is not known.
    case waiting
    /// The welcome, which starts a session with the first message.
    case start
    /// The welcome, whose composer continues this live session (Y1).
    case continuing(Int)
    /// A conversation.
    case conversation(Int)

    /// A selected chat is shown. Without one: wait for the first
    /// `chat.list` unless the connection has given up (then the welcome
    /// says "Not connected"); in single presentation with a live session
    /// the welcome continues it; otherwise it starts one.
    static func decide(selected: Int?, listed: Bool, gaveUp: Bool, single: Bool, live: Int?) -> MainScreen {
        if let selected { return .conversation(selected) }
        if !listed && !gaveUp { return .waiting }
        if single, let live { return .continuing(live) }
        return .start
    }
}

// MARK: - The viewer across a quit (v0.6)

/// The artifact the viewer was showing when the app quit, and in which
/// session; stored in `Settings`.
struct SavedViewer: Equatable, Sendable {
    var chat: Int
    var artifact: String
}

enum ViewerRestore {
    /// The artifact to reopen in `chat`'s viewer at launch: the one that
    /// was showing in that session at quit; `nil` (the viewer stays
    /// closed, the chat full width) when the viewer was closed or empty,
    /// or was showing another session's.
    static func artifact(saved: SavedViewer?, chat: Int) -> String? {
        guard let saved, saved.chat == chat else { return nil }
        return saved.artifact
    }
}
