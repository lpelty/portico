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

    /// Single presentation at launch (and after the selection went away):
    /// open the live session directly, so the start screen shows only
    /// when there is no session yet.
    func openLiveSessionIfNeeded() {
        guard isSinglePresentation, selected == nil, !isStarting, let live = liveSession else { return }
        open(chat: live.chat)
    }

    // MARK: renewing

    /// Renewing is offered in single presentation, by a gateway that
    /// speaks sessions, for a session that has not ended.
    func canRenew(chat: Int) -> Bool {
        isSinglePresentation && offers("sessions") && !isEnded(chat: chat)
    }

    func isRenewing(chat: Int) -> Bool { renewing[chat] != nil }

    /// "Log and start new" / "Start new" / `/new`: `session.renew`, with
    /// `log` when the deployment has a log step. One at a time per session.
    func renew(chat: Int) {
        guard canRenew(chat: chat), !isRenewing(chat: chat) else { return }
        let id = Self.requestId()
        renewing[chat] = id
        send(.sessionRenew(SessionRenew(chat: chat, log: hello?.canLog ?? false, id: id)))
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

    /// The divider's second line: `Session 14 · started 11:42`.
    func startedSecondLine(calendar: Calendar = .current) -> String {
        guard let start = SessionTime.parse(summary.created) else { return number }
        return "\(number) · started \(SessionTime.clock(start, calendar: calendar))"
    }
}
