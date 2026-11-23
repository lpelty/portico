import Foundation

/// A share the agent started in a conversation (v0.28, PORT-82; Bill's
/// ZJ7): one card in place of the agent's `share_with_team` row, changed in
/// place. The gateway keeps where it stands (`team.share.card`); while it
/// is a draft the card works as the share dialog does (`TeamShareSession`):
/// the check's findings each need a choice, and only Share sends anything.
struct TeamShareCardPresentation: Equatable {
    static let title = TeamShareSession.title
    static let draftWord = "Draft"
    static let sharedWord = "Shared"
    /// Under the draft's buttons (ZJ7): what Share starts.
    static let startsLine = "From now on, changes to these files go to the team by themselves."
    static let staysLine = "They stay in step from here."

    /// The note as the card shows it: in quotes, as words that will go with the files.
    static func quoted(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\u{201C}\(trimmed)\u{201D}"
    }

    /// "Shared today at 2:14 PM. They stay in step from here."; another day, "Shared Nov 18 at 2:14 PM. …".
    static func sharedLine(
        at stamp: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let stamp, let date = SessionTime.parse(stamp) else { return "Shared. \(staysLine)" }
        let clock = SessionTime.clock(date, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return "Shared today at \(clock). \(staysLine)" }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return "Shared \(day.string(from: date)) at \(clock). \(staysLine)"
    }
}

extension AppModel {
    /// The card drawn in place of a `share_with_team` tool row; a cancelled one is not drawn at all.
    func shareCard(forToolUse id: String) -> TeamShareCard? {
        teamShareCards.values.first { $0.toolUseId == id }
    }

    /// The tool row of a cancelled share: Cancel removes the card, so the row draws nothing.
    func isCancelledShare(toolUse id: String) -> Bool {
        shareCard(forToolUse: id)?.state == .cancelled
    }

    /// A chat's cards whose tool row is not known (the gateway could not tie the call to a row): drawn after the transcript.
    func unanchoredShareCards(in chat: Int) -> [TeamShareCard] {
        teamShareCards.values
            .filter { $0.chat == chat && $0.toolUseId == nil && $0.state != .cancelled }
            .sorted { $0.share < $1.share }
    }

    /// The gateway's word on a card. A draft gets its working state (the note the agent wrote, until the person edits it).
    func teamShareCardArrived(_ card: TeamShareCard) {
        teamShareCards[card.share] = card
        if card.state == .draft {
            if teamCardSessions[card.share] == nil {
                teamCardSessions[card.share] = TeamShareSession(id: card.share, paths: card.paths, note: card.note ?? "")
            }
        } else {
            teamCardSessions[card.share] = nil
        }
    }

    /// The check's word for a draft a conversation holds (`team.share.draft` with `chat`).
    func teamCardDraftArrived(_ draft: TeamShareDraft) {
        guard draft.chat != nil, let id = draft.id else { return }
        var session = teamCardSessions[id] ?? TeamShareSession(id: id, paths: draft.paths, note: draft.note ?? "")
        session.take(draft)
        teamCardSessions[id] = session
    }

    func teamCardChoose(_ share: String, _ finding: String, _ choice: TeamShareSession.Choice?) {
        teamCardSessions[share]?.choices[finding] = choice
    }

    func teamCardSetNote(_ share: String, _ note: String) {
        teamCardSessions[share]?.note = note
    }

    /// Share on the card: only now does anything reach the team.
    func teamCardSend(_ share: String) {
        guard var session = teamCardSessions[share], let message = session.send() else { return }
        session.sending = true
        session.refusal = nil
        session.sent = message
        teamCardSessions[share] = session
        send(.teamShareSend(message))
    }

    /// Cancel on the card: nothing is shared, and the gateway's answer removes the card. Not once Share was pressed.
    func teamCardCancel(_ share: String) {
        guard let session = teamCardSessions[share], !session.sending else { return }
        send(.teamShareCancel(TeamShareCancel(id: session.id)))
    }

    /// Whether `result` was for a card's Share. Done, the gateway's card frame says Shared; refused, the card says why.
    func teamCardResultArrived(_ result: TeamResult) -> Bool {
        guard let id = result.id, var session = teamCardSessions[id] else { return false }
        session.sending = false
        session.sent = nil
        session.refusal = result.ok ? nil : result.reason ?? result.failed?.first?.reason ?? "The files were not shared."
        teamCardSessions[id] = session
        return true
    }

    func teamCardErrorArrived(_ error: ErrorMessage) {
        guard let id = error.id, var session = teamCardSessions[id], session.sending else { return }
        session.sending = false
        session.refusal = error.message
        teamCardSessions[id] = session
    }

    /// A new connection: a card's Share whose result never came is asked again by the same id.
    func teamCardsReconnected() {
        for session in teamCardSessions.values where session.sending {
            if let sent = session.sent { send(.teamShareSend(sent)) }
        }
    }

    /// Show in Shared: the Files pane's Shared tab.
    func teamShowShared() {
        guard team != nil else { return }
        filesTab = .shared
        if !sidebarVisible { toggleSidebar() }
    }

    /// The card's files that are still shared rows, for Stop syncing. A
    /// card and a row may name one file differently (relative to the first
    /// root, or absolute): they are compared as the file they name.
    func teamCardFiles(_ card: TeamShareCard) -> [TeamFile] {
        let rows = teamState?.files ?? []
        return card.paths.compactMap { path in
            let file = Self.teamSameFile(teamAbsolutePath(path))
            return rows.first { $0.path == path || (file != nil && Self.teamSameFile(teamAbsolutePath($0.path)) == file) }
        }
    }

    private static func teamSameFile(_ absolute: String?) -> String? {
        absolute.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// Stop syncing the card's files, each as its own row's Stop syncing does.
    func teamCardStop(_ card: TeamShareCard) {
        for file in teamCardFiles(card) { teamStop(file) }
    }
}
