import SwiftUI

/// The answers a permission card takes (V1). Scope words are the protocol's: `once` and
/// `chat` ("this session"); deny carries none. The protocol's `always`
/// scope stays in the types, but the app does not offer it until it
/// writes a rule we have seen written (spec decision 4).
enum PermissionChoice: Equatable {
    case allowOnce
    case allowSession
    case deny

    /// The row's label. `Deny…` refuses with no note; the deny with a
    /// reason is the "Something else" row.
    var label: String {
        switch self {
        case .deny: "Deny…"
        case .allowSession: "Allow for this session"
        case .allowOnce: "Allow once"
        }
    }

    /// The dock's options and their order (v0.16, §3.4): keys 1–3. The
    /// shipped three, `Allow always` still not among them.
    static let docked: [PermissionChoice] = [.allowOnce, .allowSession, .deny]

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

/// What the person has done on a docked permission card so far (v0.16,
/// §3.4), and the `card.answer` it becomes. The options are
/// `PermissionChoice.docked`; the keys are `QuestionDockKeys`'. "Something
/// else" is the deny with a reason; × is a deny with none (Ruling 16).
/// View-free so it can be tested.
struct PermissionDraft: Equatable {
    let card: CardAsk
    /// The focused option, an index into `PermissionChoice.docked`.
    private(set) var focused = 0
    /// Whether the person has moved the focus themselves: an arrow, or a
    /// click on a row (Ruling R-c11). Until then neither Return nor a digit
    /// answers: the card takes the focus when it appears over an empty
    /// composer, so a "2" typed as the start of a sentence must not become
    /// Allow for this session. The pointer resting on a row does not count.
    private(set) var focusMoved = false
    /// The row under the pointer: highlighted, never armed.
    private(set) var hovered: Int?
    private(set) var reason = ""

    init(card: CardAsk) {
        self.card = card
    }

    /// Move the focus (↑/↓), stopping at the ends. The first arrow shows
    /// the focused row (Allow once) rather than stepping past it, and an
    /// arrow takes the highlight back from the pointer: the last input
    /// wins, as in a menu, so the row that shows is the one Return answers.
    mutating func move(by step: Int) {
        hovered = nil
        guard focusMoved else {
            focusMoved = true
            return
        }
        focused = min(max(focused + step, 0), PermissionChoice.docked.count - 1)
    }

    /// The pointer entered a row (or left them all, `nil`): it highlights,
    /// but arms neither Return nor the digits (Ruling R-c11).
    mutating func hover(_ index: Int?) {
        hovered = index.flatMap { PermissionChoice.docked.indices.contains($0) ? $0 : nil }
    }

    /// A click on a row: unambiguous, so it answers at once, and it counts
    /// as moving the focus.
    mutating func click(_ index: Int) -> CardAnswer? {
        guard PermissionChoice.docked.indices.contains(index) else { return nil }
        focusMoved = true
        focused = index
        return PermissionChoice.docked[index].answer(for: card)
    }

    /// The row that shows as selected: the pointer's, else the focus once
    /// the person has moved it.
    var highlighted: Int? { hovered ?? (focusMoved ? focused : nil) }

    /// The answer a key gives, once the person has moved the focus: a digit
    /// chooses that option (3 is a deny with no note), Return the focused
    /// one. Before that, and on a move, nothing.
    func answer(for action: QuestionDockKeys.Action) -> CardAnswer? {
        guard focusMoved else { return nil }
        switch action {
        case .choose(let index):
            return PermissionChoice.docked.indices.contains(index) ? PermissionChoice.docked[index].answer(for: card) : nil
        case .confirm:
            return PermissionChoice.docked[focused].answer(for: card)
        case .move:
            return nil
        }
    }

    mutating func setReason(_ text: String) {
        reason = text
    }

    /// Return in "Something else": a deny that carries the typed words.
    /// Blank does nothing.
    func submitReason() -> CardAnswer? {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PermissionChoice.deny.answer(for: card, note: reason)
    }

    /// ×: a deny with no note, whatever was typed.
    func dismiss() -> CardAnswer {
        PermissionChoice.deny.answer(for: card)
    }
}

/// What a permission card shows: the tool and its summary (the header), the
/// scope note, and the full input behind the disclosure.
struct PermissionPresentation: Equatable {
    let card: CardAsk

    /// The dock's header: the tool and its target, `Write · /tmp/a.md`.
    var dockTitle: String { summary.isEmpty ? tool : "\(tool) · \(summary)" }
    var tool: String { card.permission?.tool ?? "tool" }
    var summary: String { card.permission?.summary ?? "" }
    var prettyInput: String { PrettyJSON.render(card.permission?.input ?? [:]) }

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

/// The docked permission card (v0.16, §3.4): the tool and its target in
/// the header with ×; the shipped options as numbered rows (1 Allow once,
/// 2 Allow for this session, 3 Deny…), then "Something else", the deny
/// with a reason, and what "this session" covers under it. No pager, no
/// Skip. × denies with no note. It takes the focus when it appears, on
/// the same rules as a question card.
struct PermissionCard: View {
    let card: CardAsk
    var folder: String? = nil
    var agentName: String = "Portico"
    var accent: Color = Theme.accent
    /// Asked once the card is on screen: whether to take the focus.
    var takesFocus: () -> Bool = { true }
    let onAnswer: (CardAnswer) -> Void
    @State private var draft: PermissionDraft
    @State private var showInput = false
    @FocusState private var cardFocused: Bool
    @FocusState private var fieldFocused: Bool

    init(
        card: CardAsk, folder: String? = nil, agentName: String = "Portico", accent: Color = Theme.accent,
        takesFocus: @escaping () -> Bool = { true }, onAnswer: @escaping (CardAnswer) -> Void
    ) {
        self.card = card
        self.folder = folder
        self.agentName = agentName
        self.accent = accent
        self.takesFocus = takesFocus
        self.onAnswer = onAnswer
        _draft = State(initialValue: PermissionDraft(card: card))
    }

    private var shown: PermissionPresentation { PermissionPresentation(card: card) }

    var body: some View {
        DockedCard(
            title: shown.dockTitle, closeHelp: "Deny", titleLines: 3,
            onClose: { onAnswer(draft.dismiss()) }
        ) {
            VStack(alignment: .leading, spacing: 2) {
                if let line = PermissionPresentation.whereLine(folder: folder) {
                    Text(line)
                        .scaledFont(12)
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }
                ForEach(Array(PermissionChoice.docked.enumerated()), id: \.offset) { index, choice in
                    optionRow(choice, at: index)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                    .padding(.vertical, 4)
                reasonRow
                Text(shown.scopeNote)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                disclosure
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onKeyPress(phases: .down) { press in
            let active = QuestionDockKeys.isActive(cardFocused: cardFocused, fieldFocused: fieldFocused)
            guard
                let action = QuestionDockKeys.action(
                    for: press.key, cardFocused: active, optionCount: PermissionChoice.docked.count)
            else { return .ignored }
            if case .move(let step) = action {
                draft.move(by: step)
            } else if let answer = draft.answer(for: action) {
                onAnswer(answer)
            }
            return .handled
        }
        // After the composer's own `onAppear` focus, as the question card.
        .task {
            await Task.yield()
            if takesFocus() { cardFocused = true }
        }
    }

    private func optionRow(_ choice: PermissionChoice, at index: Int) -> some View {
        let primary = choice == .allowOnce
        return Button {
            if let answer = draft.click(index) { onAnswer(answer) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text("\(index + 1)")
                    .scaledFont(12, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(primary ? Color.white : Theme.text2)
                    .frame(width: 24, height: 24)
                    .background(primary ? accent : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(primary ? .clear : Theme.border, lineWidth: 1))
                Text(choice.label)
                    .scaledFont(13, weight: .medium)
                    .foregroundStyle(choice == .deny ? Theme.deny : Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                draft.highlighted == index ? Theme.selected : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                draft.hover(index)
            } else if draft.hovered == index {
                draft.hover(nil)
            }
        }
        .pointerStyle(.link)
        .help(help(for: choice))
        .accessibilityLabel("\(index + 1). \(choice.label)")
    }

    private func help(for choice: PermissionChoice) -> String {
        switch choice {
        case .allowOnce: "Allow this one step"
        case .allowSession: shown.scopeNote
        case .deny: "Refuse, with no note"
        }
    }

    /// "Something else": the deny with a reason (Return sends it).
    private var reasonRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            TextField("Something else", text: Binding(get: { draft.reason }, set: { draft.setReason($0) }))
                .textFieldStyle(.plain)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .onSubmit { if let answer = draft.submitReason() { onAnswer(answer) } }
                .help("Deny, and tell \(agentName) why or what to do instead (Return). \(PermissionPresentation.noteHint(agentName: agentName))")
            Button("Deny") { if let answer = draft.submitReason() { onAnswer(answer) } }
                .buttonStyle(PillButtonStyle(kind: .primary(Theme.deny)))
                .disabled(draft.submitReason() == nil)
                .help("Refuse; what you typed goes to \(agentName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showInput.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(Theme.iconFont(9, weight: .semibold))
                        .rotationEffect(.degrees(showInput ? 90 : 0))
                    Text("Show the full input")
                        .scaledFont(12)
                }
                .foregroundStyle(accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            if showInput {
                Text(shown.prettyInput)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}
