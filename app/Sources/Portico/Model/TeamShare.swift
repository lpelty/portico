import Foundation

/// The share dialog's state (v0.27, Bill's ZJ2): the files, the note the
/// person is writing, the check's latest draft and what the person chose
/// for each thing it found. Nothing reaches the team before Share, and a
/// finding is taken out of the person's file only then.
struct TeamShareSession: Equatable, Sendable {
    enum Choice: Equatable, Sendable {
        case takeOut, keep
    }

    /// The draft's id: the gateway's draft and result answer by it.
    var id: String
    var paths: [String]
    var note: String = ""
    /// The check's latest word; `nil` until the gateway's first draft.
    var draft: TeamShareDraft? = nil
    var choices: [String: Choice] = [:]
    /// Share was pressed and its result has not come.
    var sending = false
    /// Why the last Share was not done, in the deployment's words.
    var refusal: String? = nil
    /// The Share that is out, to ask again by the same id if the connection is lost before its result.
    var sent: TeamShareSend? = nil

    static let title = "Share with team"
    static let noteCaption = "Optional. The note goes with the files, so the team knows what they are for."
    static let footer = "From now on, changes to these files go to the team by themselves. You can stop syncing a file at any time."
    static let changesFile = "The file is shared as it is, so taking it out changes your file."

    var checking: Bool { draft?.checking ?? true }
    var findings: [TeamShareDraft.Finding] { draft?.findings ?? [] }
    var checkError: String? { draft?.checkError }

    /// The check's new word. The person's note and their choices on findings still there are kept.
    mutating func take(_ draft: TeamShareDraft) {
        self.draft = draft
        let present = Set(draft.findings.map(\.id))
        choices = choices.filter { present.contains($0.key) }
    }

    static func name(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    /// The folder a file sits in, as the row's quiet second column.
    static func folder(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder == "/" ? "" : folder
    }

    /// "One thing to check before it goes".
    var findingsTitle: String? {
        switch findings.count {
        case 0: nil
        case 1: "One thing to check before it goes"
        default: "\(findings.count) things to check before it goes"
        }
    }

    /// What a finding says while the person has not chosen.
    static func text(_ finding: TeamShareDraft.Finding) -> String {
        "\(name(finding.path)), \(lowerFirst(finding.location)): \(finding.text)"
    }

    /// What it says once chosen; Undo takes the choice back.
    static func chosen(_ finding: TeamShareDraft.Finding, _ choice: Choice) -> String {
        switch choice {
        case .takeOut: "\(finding.location) will be taken out of \(name(finding.path)) when you share"
        case .keep: "\(finding.location) of \(name(finding.path)) will be shared as it is"
        }
    }

    private static func lowerFirst(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }

    /// The Share button's word: it waits visibly when pressed during the check.
    var shareLabel: String {
        if sending { return checking ? "Checking…" : "Sharing…" }
        return checkError != nil ? "Share anyway" : "Share"
    }

    /// Share can be pressed during the check (the gateway finishes it first). Once
    /// the check has found things, each needs the person's choice first.
    var canShare: Bool {
        !sending && findings.allSatisfy { choices[$0.id] != nil }
    }

    /// What Share sends for what the person sees now.
    func send() -> TeamShareSend? {
        guard let draft, canShare else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return TeamShareSend(
            rev: draft.rev, note: trimmed.isEmpty ? nil : trimmed,
            remove: findings.filter { choices[$0.id] == .takeOut }.map(\.id),
            unchecked: draft.checkError != nil ? true : nil, id: id)
    }
}

extension AppModel {
    /// A file as the team kinds name it: inside the deployment's first root, relative to it; else absolute.
    func teamPath(forAbsolute path: String) -> String {
        guard let root = hello?.roots.first else { return path }
        let base = URL(fileURLWithPath: (root.path as NSString).expandingTildeInPath).standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
    }

    /// Whether Share with team… is offered for a file: the deployment has team knowledge and the file is not shared yet.
    func canShareWithTeam(absolutePath: String) -> Bool {
        team != nil && teamFile(at: absolutePath) == nil
    }

    /// The person chose Share with team…: the dialog opens at once and the check starts.
    func teamShareStart(absolutePaths: [String]) {
        guard team != nil, !absolutePaths.isEmpty else { return }
        let session = TeamShareSession(id: teamRequestId(), paths: absolutePaths.map(teamPath(forAbsolute:)))
        teamShare = session
        send(.teamSharePrepare(TeamSharePrepare(paths: session.paths, id: session.id)))
    }

    func teamShareChoose(_ finding: String, _ choice: TeamShareSession.Choice?) {
        teamShare?.choices[finding] = choice
    }

    func teamShareSend() {
        guard var session = teamShare, let message = session.send() else { return }
        session.sending = true
        session.refusal = nil
        session.sent = message
        teamShare = session
        send(.teamShareSend(message))
    }

    /// Closed or cancelled: nothing is shared and no file was changed. Not once Share was
    /// pressed: a share under way cannot be called back, so the dialog stays until its result.
    func teamShareCancel() {
        guard let session = teamShare, !session.sending else { return }
        teamShare = nil
        send(.teamShareCancel(TeamShareCancel(id: session.id)))
    }

    /// A new connection: a Share or a Get whose result never came is asked again by the same id.
    /// The gateway does a request once, so this only learns what happened.
    func teamReconnected() {
        teamGetPending = nil
        if let session = teamShare, session.sending, let sent = session.sent {
            send(.teamShareSend(sent))
        }
    }

    /// The gateway could not carry out the open share's request: the dialog says so and can be used again.
    func teamShareErrorArrived(_ error: ErrorMessage) {
        guard var session = teamShare, session.sending, error.id == session.id else { return }
        session.sending = false
        session.refusal = error.message
        teamShare = session
    }

    func teamShareDraftArrived(_ draft: TeamShareDraft) {
        guard draft.chat == nil, var session = teamShare, session.id == draft.id else { return }
        session.take(draft)
        teamShare = session
    }

    /// Whether `result` was for the open share; if so the dialog closes, or says why it was not done.
    func teamShareResultArrived(_ result: TeamResult) -> Bool {
        guard var session = teamShare, session.id == result.id else { return false }
        if result.ok {
            teamShare = nil
        } else {
            session.sending = false
            session.refusal = result.reason ?? result.failed?.first?.reason ?? "The files were not shared."
            teamShare = session
        }
        return true
    }
}
