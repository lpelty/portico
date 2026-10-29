import SwiftUI

/// The answers a permission card takes (V1), in the order the buttons
/// show them, left to right. Scope words are the protocol's: `once` and
/// `chat` ("this session"); deny carries none. The protocol's `always`
/// scope stays in the types, but the app does not offer it until it
/// writes a rule we have seen written (spec decision 4).
enum PermissionChoice: CaseIterable, Equatable {
    case deny
    case allowSession
    case allowOnce

    /// The button's label. `Deny…` opens the note first; the note's own
    /// button says `Deny`.
    var label: String {
        switch self {
        case .deny: "Deny…"
        case .allowSession: "Allow for this session"
        case .allowOnce: "Allow once"
        }
    }

    var scope: Scope? {
        switch self {
        case .allowOnce: .once
        case .allowSession: .chat
        case .deny: nil
        }
    }

    /// The `card.answer` for this choice. The note goes only with a deny
    /// (it is what the agent reads instead of being told no); a blank one
    /// is left out.
    func answer(for card: CardAsk, note: String = "") -> CardAnswer {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardAnswer(
            chat: card.chat, id: card.id,
            answer: ["decision": .string(self == .deny ? "deny" : "allow")],
            scope: scope, note: self == .deny && !trimmed.isEmpty ? trimmed : nil)
    }
}

/// What a permission card shows: the plain question (the gateway's
/// title), the tool as a tag, the one-line summary, and the full input
/// behind the disclosure.
struct PermissionPresentation: Equatable {
    let card: CardAsk

    var tool: String { card.permission?.tool ?? "tool" }
    var summary: String { card.permission?.summary ?? "" }
    var prettyInput: String { PrettyJSON.render(card.permission?.input ?? [:]) }

    /// The question; a card without a title asks `Use <tool>?`.
    var question: String {
        let trimmed = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Use \(tool)?" : trimmed
    }

    /// `in Research vault`: the folder the step happens in, by name.
    static func whereLine(folder: String?) -> String? {
        guard let folder, !folder.isEmpty else { return nil }
        return "in " + URL(fileURLWithPath: folder).lastPathComponent
    }

    /// The line under the buttons: what "this session" covers, as the
    /// gateway says it (`card.ask.scope_note`); an older gateway that does
    /// not say gets the general line.
    var scopeNote: String {
        let said = card.scopeNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return said.isEmpty ? Self.generalScopeNote : said
    }

    static let generalScopeNote = "For this session: no more asks like this one until you start a new session."

    /// The line under the deny note.
    static func noteHint(agentName: String) -> String {
        "Optional. \(agentName) reads this instead of just being told no."
    }
}

/// V1's one permission unit, the card half: pinned above the composer
/// while the tool row reads "waiting for your OK". Asking: the question,
/// the tool tag, the summary, the full input on request, then
/// `Deny…` · `Allow for this session` · `Allow once`. `Deny…` turns the
/// card into a note field with `Back` and a red `Deny`. On an answer the
/// card goes and the row carries the outcome.
struct PermissionCard: View {
    let card: CardAsk
    var folder: String? = nil
    var agentName: String = "Portico"
    var accent: Color = Theme.accent
    let onAnswer: (CardAnswer) -> Void
    @State private var denying = false
    @State private var note = ""
    @State private var showInput = false
    @FocusState private var noteFocused: Bool

    private var shown: PermissionPresentation { PermissionPresentation(card: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !shown.summary.isEmpty {
                Text(shown.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            disclosure
            if denying {
                denyNote
            } else {
                choices
            }
        }
        .padding(16)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.wait, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundStyle(Theme.wait)
                .frame(width: 26, height: 26)
                .background(Theme.waitSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                if let line = PermissionPresentation.whereLine(folder: folder) {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                }
            }
            Spacer(minLength: 8)
            Text(shown.tool)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help("The tool the agent wants to use")
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showInput.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showInput ? 90 : 0))
                    Text("Show the full input")
                        .font(.system(size: 12))
                }
                .foregroundStyle(accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            if showInput {
                ScrollView {
                    Text(shown.prettyInput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(PermissionChoice.deny.label) {
                    denying = true
                    noteFocused = true
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .help("Refuse, with a note to the agent if you like")
                Spacer(minLength: 0)
                Button(PermissionChoice.allowSession.label) { answer(.allowSession) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .help(shown.scopeNote)
                Button(PermissionChoice.allowOnce.label) { answer(.allowOnce) }
                    .buttonStyle(PillButtonStyle(kind: .primary(accent)))
                    .help("Allow this one step")
            }
            Text(shown.scopeNote)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
    }

    private var denyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tell the agent why, or what to do instead", text: $note)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(accent, lineWidth: 1))
                .focused($noteFocused)
                .onSubmit { answer(.deny) }
            Text(PermissionPresentation.noteHint(agentName: agentName))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            HStack {
                Button("Back") { denying = false }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Deny") { answer(.deny) }
                    .buttonStyle(PillButtonStyle(kind: .primary(Theme.deny)))
                    .help("Refuse; the note, if any, goes to the agent")
            }
        }
    }

    private func answer(_ choice: PermissionChoice) {
        onAnswer(choice.answer(for: card, note: note))
    }
}
