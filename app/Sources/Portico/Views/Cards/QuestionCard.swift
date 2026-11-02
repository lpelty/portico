import SwiftUI

/// What the person has chosen on a docked question card so far (v0.16,
/// AO1), and the `card.answer` it becomes: `{"answers": {<question>: <label>
/// | [labels]}}`, skipped questions left out; or, when every question was
/// skipped, the `skipped` decline. One question shows at a time (`page`);
/// answering one moves to the next still open, and after the last the
/// whole answer is returned. A single-select answers with one label (the
/// "Something else" text replaces any option); a multi-select with the
/// ticked labels in option order, plus the typed text. View-free so it can
/// be tested.
struct QuestionDraft: Equatable {
    let card: CardAsk
    /// The question on show.
    private(set) var page = 0
    /// The focused option on this page, an index into `ordered(page)`.
    private(set) var focused = 0
    private var selected: [Int: [String]] = [:]
    private var other: [Int: String] = [:]
    /// Questions answered or skipped: done with, whatever the page shows.
    private var answered: Set<Int> = []
    private var skipped: Set<Int> = []

    init(card: CardAsk) {
        self.card = card
    }

    var questions: [Question] { card.questions ?? [] }

    private func question(_ index: Int) -> Question? {
        questions.indices.contains(index) ? questions[index] : nil
    }

    // MARK: pages

    /// Show question `page` (clamped to the questions), its first option focused.
    mutating func goTo(_ page: Int) {
        self.page = min(max(page, 0), max(questions.count - 1, 0))
        focused = 0
    }

    /// Move the focus within this page's options (↑/↓), stopping at the ends.
    mutating func move(by step: Int) {
        let count = ordered(page).count
        guard count > 0 else { return }
        focused = min(max(focused + step, 0), count - 1)
    }

    /// Put the focus on one of this page's options (the pointer on it, a digit key).
    mutating func focus(_ index: Int) {
        guard ordered(page).indices.contains(index) else { return }
        focused = index
    }

    /// A multi-select's button: "Submit" when this is the last question
    /// still open, "Next" otherwise.
    var advanceLabel: String {
        questions.indices.allSatisfy { $0 == page || isDone($0) } ? "Submit" : "Next"
    }

    private func isDone(_ index: Int) -> Bool {
        answered.contains(index) || skipped.contains(index)
    }

    // MARK: options

    /// The question's options as shown: the one whose label ends
    /// "(Recommended)" first, the rest in the agent's order.
    func ordered(_ index: Int) -> [Option] {
        let options = question(index)?.options ?? []
        return options.filter(isRecommended) + options.filter { !isRecommended($0) }
    }

    func isRecommended(_ option: Option) -> Bool {
        option.label.trimmingCharacters(in: .whitespaces).hasSuffix("(Recommended)")
    }

    /// Whether any option of the question carries a preview: the preview
    /// column shows only then.
    func hasPreviews(_ index: Int) -> Bool {
        (question(index)?.options ?? []).contains { !($0.preview ?? "").isEmpty }
    }

    /// The focused option's preview, `nil` when the question has none.
    func preview(_ index: Int) -> String? {
        guard hasPreviews(index) else { return nil }
        let options = ordered(index)
        let at = index == page ? focused : 0
        return options.indices.contains(at) ? options[at].preview : nil
    }

    // MARK: answering

    /// A single-select's pick: answers the question and moves on; after
    /// the last open question, the whole answer.
    mutating func choose(_ label: String, for index: Int) -> CardAnswer? {
        selected[index] = [label]
        other[index] = nil
        return resolve(index)
    }

    /// Tick or untick a multi-select's option, keeping option order.
    mutating func toggle(_ label: String, for index: Int) {
        var list = selected[index] ?? []
        if let at = list.firstIndex(of: label) {
            list.remove(at: at)
        } else {
            list.append(label)
        }
        let order = question(index)?.options.map(\.label) ?? []
        list.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        selected[index] = list
    }

    func isSelected(_ label: String, for index: Int) -> Bool {
        (selected[index] ?? []).contains(label)
    }

    /// A multi-select's Next or Submit: answers this page with what is
    /// ticked (and typed). Nothing chosen does nothing.
    mutating func next() -> CardAnswer? {
        guard !labels(for: page).isEmpty else { return nil }
        return resolve(page)
    }

    mutating func setOther(_ text: String, for index: Int) {
        other[index] = text
    }

    func otherText(for index: Int) -> String {
        other[index] ?? ""
    }

    /// Return in "Something else": answers with the typed text (a
    /// single-select's only label, one more for a multi-select). Blank
    /// does nothing.
    mutating func submitOther(for index: Int) -> CardAnswer? {
        guard trimmedOther(for: index) != nil else { return nil }
        if question(index)?.multiSelect != true { selected[index] = nil }
        return resolve(index)
    }

    /// Skip: leave the question unanswered and move on. When every
    /// question is skipped, the `skipped` decline.
    mutating func skip(_ index: Int) -> CardAnswer? {
        selected[index] = nil
        other[index] = nil
        answered.remove(index)
        skipped.insert(index)
        return resolve(index, answering: false)
    }

    /// The card declined as a whole (× is `.dismissed`).
    func decline(_ why: QuestionDecline) -> CardAnswer {
        .declining(chat: card.chat, id: card.id, why)
    }

    private func trimmedOther(for index: Int) -> String? {
        let text = otherText(for: index).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The labels the question answers with, as the answer will carry them.
    func labels(for index: Int) -> [String] {
        let chosen = selected[index] ?? []
        guard let extra = trimmedOther(for: index) else { return chosen }
        return question(index)?.multiSelect == true ? chosen + [extra] : [extra]
    }

    /// Mark a question done and show the next one still open (after it,
    /// then from the start); with none left, the whole answer.
    private mutating func resolve(_ index: Int, answering: Bool = true) -> CardAnswer? {
        if answering {
            skipped.remove(index)
            answered.insert(index)
        }
        let open = questions.indices.filter { !isDone($0) }
        if let following = open.first(where: { $0 > index }) ?? open.first {
            goTo(following)
            return nil
        }
        return answer()
    }

    /// The answer once every question is done: the answered ones by
    /// question text, or the `skipped` decline when none was answered.
    private func answer() -> CardAnswer {
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() where answered.contains(index) {
            let labels = labels(for: index)
            guard !labels.isEmpty else { continue }
            answers[question.question] = question.multiSelect ? .array(labels.map(JSONValue.string)) : .string(labels[0])
        }
        if answers.isEmpty { return decline(.skipped) }
        return CardAnswer(chat: card.chat, id: card.id, answer: ["answers": .object(answers)])
    }
}

/// The docked card's keys (Ruling 15): 1–4 choose an option, ↑/↓ move,
/// Return confirms, and only while the card itself has the focus. Typed
/// in the composer (or the "Something else" field), a digit is a digit.
/// Esc does nothing; × is the only dismiss.
enum QuestionDockKeys {
    enum Action: Equatable {
        /// An option by its place in the list shown (0 is "1").
        case choose(Int)
        case move(Int)
        case confirm
    }

    /// Whether the card's keys are live: the card has the focus and its own
    /// "Something else" field does not (typed there, a digit is a digit and
    /// Return submits the text). The composer focused is the card not.
    static func isActive(cardFocused: Bool, fieldFocused: Bool) -> Bool {
        cardFocused && !fieldFocused
    }

    /// Whether a card that docks takes the focus (controller ruling, fix
    /// round 1, refining Ruling 15): only when the composer does not have it,
    /// or has it with nothing typed. Typing is never interrupted; the card
    /// is a click (or Tab) away.
    static func takesFocusOnAppear(composerFocused: Bool, composerText: String) -> Bool {
        !composerFocused || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func action(for key: KeyEquivalent, cardFocused: Bool, optionCount: Int) -> Action? {
        guard cardFocused else { return nil }
        switch key {
        case .upArrow: return .move(-1)
        case .downArrow: return .move(1)
        case .return: return .confirm
        default:
            guard let digit = key.character.wholeNumberValue, (1...4).contains(digit), digit <= optionCount else { return nil }
            return .choose(digit - 1)
        }
    }
}

/// The docked question card (v0.16, AO1): the question in the header with
/// the pager and ×; the options numbered 1–4 (checkboxes for a
/// multi-select), the Recommended one first in the brand accent; the last
/// row "Something else" and Skip (and Next or Submit for a multi-select);
/// the focused option's preview at the right when the agent sent any.
/// The card takes the focus when it appears; `onAnswer` gets the
/// finished `card.answer`, an answer or a decline.
struct QuestionCard: View {
    let card: CardAsk
    var accent: Color = Theme.accent
    let onAnswer: (CardAnswer) -> Void
    @State private var draft: QuestionDraft
    @State private var expanded = false
    @FocusState private var cardFocused: Bool
    @FocusState private var fieldFocused: Bool
    /// Asked once the card is on screen: whether to take the focus.
    var takesFocus: () -> Bool = { true }

    init(
        card: CardAsk, accent: Color = Theme.accent, takesFocus: @escaping () -> Bool = { true },
        onAnswer: @escaping (CardAnswer) -> Void
    ) {
        self.card = card
        self.accent = accent
        self.takesFocus = takesFocus
        self.onAnswer = onAnswer
        _draft = State(initialValue: QuestionDraft(card: card))
    }

    private var page: Int { draft.page }
    private var question: Question? { draft.questions.indices.contains(page) ? draft.questions[page] : nil }
    private var multi: Bool { question?.multiSelect == true }
    private var options: [Option] { draft.ordered(page) }

    var body: some View {
        DockedCard(
            title: question?.question ?? card.title,
            pager: draft.questions.count > 1
                ? DockedCardPager(page: page, count: draft.questions.count, go: { draft.goTo($0) }) : nil,
            closeHelp: "Dismiss the question",
            onClose: { onAnswer(draft.decline(.dismissed)) },
            showsTrailing: draft.hasPreviews(page)
        ) {
            optionList
        } trailing: {
            previewPane
        }
        .focusable()
        .focusEffectDisabled()
        .focused($cardFocused)
        .onKeyPress(phases: .down) { press in
            let active = QuestionDockKeys.isActive(cardFocused: cardFocused, fieldFocused: fieldFocused)
            guard let action = QuestionDockKeys.action(for: press.key, cardFocused: active, optionCount: options.count)
            else { return .ignored }
            perform(action)
            return .handled
        }
        // After the composer's own `onAppear` focus (it draws below), so a
        // conversation opened with a card already docked gives it the card.
        .task {
            await Task.yield()
            if takesFocus() { cardFocused = true }
        }
        .sheet(isPresented: $expanded) {
            PreviewSheet(title: question?.question ?? card.title, text: draft.preview(page) ?? "") { expanded = false }
        }
    }

    private func perform(_ action: QuestionDockKeys.Action) {
        switch action {
        case .choose(let index):
            draft.focus(index)
            pick(options[index])
        case .move(let step):
            draft.move(by: step)
        case .confirm:
            if multi {
                finish(draft.next())
            } else if options.indices.contains(draft.focused) {
                pick(options[draft.focused])
            }
        }
    }

    /// An option clicked or keyed: a single-select answers, a multi-select ticks.
    private func pick(_ option: Option) {
        if multi {
            draft.toggle(option.label, for: page)
        } else {
            finish(draft.choose(option.label, for: page))
        }
    }

    private func finish(_ answer: CardAnswer?) {
        if let answer { onAnswer(answer) }
    }

    // MARK: the options

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                optionRow(option, at: index)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 4)
            lastRow
        }
    }

    private func optionRow(_ option: Option, at index: Int) -> some View {
        let recommended = draft.isRecommended(option)
        let focusedRow = draft.focused == index
        let ticked = draft.isSelected(option.label, for: page)
        return Button {
            draft.focus(index)
            pick(option)
            cardFocused = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                badge(index: index, recommended: recommended, ticked: ticked)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(recommended ? accent : Theme.text)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .scaledFont(12)
                            .foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                focusedRow ? Theme.selected : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        // The pointer moves the focus (and the preview with it).
        .onHover { inside in if inside { draft.focus(index) } }
        .pointerStyle(.link)
        .help(multi ? (ticked ? "Untick \(option.label)" : "Tick \(option.label)") : "Answer \(option.label)")
        .accessibilityLabel(multi ? "\(option.label), \(ticked ? "ticked" : "not ticked")" : "\(index + 1). \(option.label)")
        .accessibilityHint(option.description)
    }

    /// The number 1–4 in a small box, or a checkbox for a multi-select;
    /// the Recommended one filled with the brand accent.
    @ViewBuilder
    private func badge(index: Int, recommended: Bool, ticked: Bool) -> some View {
        if multi {
            Image(systemName: ticked ? "checkmark.square.fill" : "square")
                .font(Theme.iconFont(16))
                .foregroundStyle(ticked || recommended ? accent : Theme.text2)
                .frame(width: 24, height: 24)
        } else {
            Text("\(index + 1)")
                .scaledFont(12, weight: .medium, monospacedDigit: true)
                .foregroundStyle(recommended ? Color.white : Theme.text2)
                .frame(width: 24, height: 24)
                .background(recommended ? accent : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(recommended ? .clear : Theme.border, lineWidth: 1))
        }
    }

    /// "Something else" (Return answers with it) and Skip; a multi-select
    /// adds Next or Submit.
    private var lastRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.text2)
                .frame(width: 24, height: 24)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            TextField("Something else", text: Binding(
                get: { draft.otherText(for: page) },
                set: { draft.setOther($0, for: page) }))
                .textFieldStyle(.plain)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .focused($fieldFocused)
                .onSubmit { finish(draft.submitOther(for: page)) }
                .help(multi ? "An answer of your own, with the ticked ones (Return)" : "An answer of your own (Return)")
            Button("Skip") { finish(draft.skip(page)) }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .help("Leave this question unanswered")
            if multi {
                Button(draft.advanceLabel) { finish(draft.next()) }
                    .buttonStyle(PillButtonStyle(kind: .primary(accent)))
                    .disabled(draft.labels(for: page).isEmpty)
                    .help(draft.labels(for: page).isEmpty ? "Tick an option first" : "Answer with the ticked options")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: the preview

    private var previewPane: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                MarkdownBlocksView(blocks: MarkdownCache.blocks(for: draft.preview(page) ?? ""))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Button { expanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(Theme.iconFont(11))
                    .foregroundStyle(Theme.text2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverBox)
            .help("Open the preview larger")
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// The preview opened larger: 640 by 480, the same renderer.
private struct PreviewSheet: View {
    let title: String
    let text: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                MarkdownBlocksView(blocks: MarkdownCache.blocks(for: text))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(width: 640, height: 480)
        .background(Theme.window)
    }
}
