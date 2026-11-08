import Foundation

// v0.25 §4 (PORT-3, ZE3): a turn that ended on an expired sign-in pauses; a
// card docks above the composer until the person signs in again (the turn
// then carries on by itself), or chooses Don't wait.

/// The card's words and choices (ZE3); pure, so they are tested without a window.
enum SigninPresentation {
    /// `turn.finished.reason` for a turn that ended on an expired sign-in.
    static let expiredReason = "signin.expired"
    static let openTitle = "Open sign-in page"
    static let dontWaitTitle = "Don't wait"
    static let troubleTitle = "Trouble signing in?"
    static let hideTitle = "Hide"
    static let continuingText = "Signed in. Continuing…"
    static let continuedNote = "Continued after sign-in"
    static let pastePrompt = "Paste the code from the browser"
    static let pausedLabel = "Paused: sign-in ran out"
    static let endedLabel = "Sign-in ran out"
    /// How long "Signed in. Continuing…" shows (ruling 16).
    static let continuingSeconds: Double = 1.5

    /// Open sign-in page shows only when the deployment has a command for it.
    static func showsOpen(_ wait: SigninWait) -> Bool { wait.canOpen }

    /// Trouble signing in? shows only once the command printed a link (ruling 13).
    static func offersTrouble(_ wait: SigninWait) -> Bool { foldIntro(wait) != nil }

    /// The fold's first line, or nil when there is no link to show.
    static func foldIntro(_ wait: SigninWait) -> String? {
        guard let url = wait.url, !url.isEmpty else { return nil }
        if let code = wait.code, !code.isEmpty { return "If the page didn't open, use this link and enter the code:" }
        if wait.wantsCode == true { return "If the page didn't open, use this link and paste the code it gives you:" }
        return "If the page didn't open, use this link:"
    }

    /// "Waiting for sign-in… since 9:14 PM".
    static func waitingLine(_ wait: SigninWait, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let started = SessionTime.parse(wait.started) else { return "Waiting for sign-in…" }
        return "Waiting for sign-in… since \(MessageTime.short(started, now: now, calendar: calendar, locale: locale))"
    }
}
