import SwiftUI

/// The four answers a permission card takes, in the order the buttons show
/// them. Scope words are the protocol's: `once`, `chat`, `always`; deny
/// carries none.
enum PermissionChoice: CaseIterable, Equatable {
    case allowOnce
    case allowChat
    case allowAlways
    case deny

    var label: String {
        switch self {
        case .allowOnce: "Allow this time"
        case .allowChat: "Allow for this chat"
        case .allowAlways: "Always allow"
        case .deny: "Deny"
        }
    }

    var scope: Scope? {
        switch self {
        case .allowOnce: .once
        case .allowChat: .chat
        case .allowAlways: .always
        case .deny: nil
        }
    }

    /// The `card.answer` for this choice; a blank note is left out.
    func answer(for card: CardAsk, note: String) -> CardAnswer {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return CardAnswer(
            chat: card.chat, id: card.id,
            answer: ["decision": .string(self == .deny ? "deny" : "allow")],
            scope: scope, note: trimmed.isEmpty ? nil : trimmed)
    }
}

/// What a permission card shows: the tool, its one-line summary, and the
/// full input as pretty JSON behind the disclosure.
struct PermissionPresentation: Equatable {
    let card: CardAsk

    var tool: String { card.permission?.tool ?? "tool" }
    var summary: String { card.permission?.summary ?? "" }
    var prettyInput: String { PrettyJSON.render(card.permission?.input ?? [:]) }
}

/// The agent wants to use a tool: tool and summary, the input on request,
/// an optional note to the agent, and the four answers.
struct PermissionCard: View {
    let card: CardAsk
    let onAnswer: (CardAnswer) -> Void
    @State private var note = ""
    @State private var showInput = false

    private var shown: PermissionPresentation { PermissionPresentation(card: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ToolRowPresentation.toolIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(shown.tool)
                    .fontWeight(.medium)
                Text(shown.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.callout)
            DisclosureGroup("Full input", isExpanded: $showInput) {
                Text(shown.prettyInput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 4)
            }
            .font(.caption)
            TextField("Note to the agent (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(PermissionChoice.allCases, id: \.self) { choice in
                    button(for: choice)
                }
            }
        }
    }

    @ViewBuilder
    private func button(for choice: PermissionChoice) -> some View {
        switch choice {
        case .allowOnce:
            Button(choice.label) { answer(choice) }
                .buttonStyle(.borderedProminent)
                .help("Allow this one call")
        case .allowChat:
            Button(choice.label) { answer(choice) }
                .help("Allow \(shown.tool) for the rest of this chat without asking")
        case .allowAlways:
            Button(choice.label) { answer(choice) }
                .help("Add \(shown.tool) to the folder's own allow rules")
        case .deny:
            Button(choice.label, role: .destructive) { answer(choice) }
                .help("Refuse; the note, if any, goes to the agent")
        }
    }

    private func answer(_ choice: PermissionChoice) {
        onAnswer(choice.answer(for: card, note: note))
    }
}
