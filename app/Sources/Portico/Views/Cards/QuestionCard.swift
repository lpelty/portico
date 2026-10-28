import SwiftUI

/// What the person has chosen on a question card so far, and the
/// `card.answer` it becomes: `{"answers": {<question>: <label> | [labels]}}`.
/// A single-select question answers with one label; a multi-select with
/// the chosen labels in option order. "Other" text is the label for a
/// single-select (it replaces the chosen option) and one more label for a
/// multi-select. View-free so it can be tested.
struct QuestionDraft: Equatable {
    let card: CardAsk
    private var selected: [Int: [String]] = [:]
    private var other: [Int: String] = [:]

    init(card: CardAsk) {
        self.card = card
    }

    var questions: [Question] { card.questions ?? [] }

    /// Pick one option for a single-select question (replaces any earlier pick).
    mutating func choose(_ label: String, for index: Int) {
        selected[index] = [label]
    }

    /// Add or remove one option of a multi-select question, keeping option order.
    mutating func toggle(_ label: String, for index: Int) {
        var list = selected[index] ?? []
        if let at = list.firstIndex(of: label) {
            list.remove(at: at)
        } else {
            list.append(label)
        }
        let order = questions.indices.contains(index) ? questions[index].options.map(\.label) : []
        list.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        selected[index] = list
    }

    func isSelected(_ label: String, for index: Int) -> Bool {
        (selected[index] ?? []).contains(label)
    }

    mutating func setOther(_ text: String, for index: Int) {
        other[index] = text
    }

    func otherText(for index: Int) -> String {
        other[index] ?? ""
    }

    private func trimmedOther(for index: Int) -> String? {
        let text = otherText(for: index).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The labels the question answers with, as the answer will carry them.
    func labels(for index: Int) -> [String] {
        let chosen = selected[index] ?? []
        let multi = questions.indices.contains(index) && questions[index].multiSelect
        guard let extra = trimmedOther(for: index) else { return chosen }
        return multi ? chosen + [extra] : [extra]
    }

    /// Every question has at least one label.
    var isComplete: Bool {
        questions.indices.allSatisfy { !labels(for: $0).isEmpty }
    }

    func answer() -> CardAnswer? {
        guard isComplete else { return nil }
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let labels = labels(for: index)
            answers[question.question] = question.multiSelect ? .array(labels.map(JSONValue.string)) : .string(labels[0])
        }
        return CardAnswer(chat: card.chat, id: card.id, answer: ["answers": .object(answers)])
    }
}

/// The agent asks the person to choose: each question with its header,
/// its options (one pick, or several when `multi_select`), an "Other"
/// field, and Submit once every question has an answer.
struct QuestionCard: View {
    let card: CardAsk
    let onAnswer: (CardAnswer) -> Void
    @State private var draft: QuestionDraft

    init(card: CardAsk, onAnswer: @escaping (CardAnswer) -> Void) {
        self.card = card
        self.onAnswer = onAnswer
        _draft = State(initialValue: QuestionDraft(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(draft.questions.enumerated()), id: \.offset) { index, question in
                questionBlock(question, at: index)
            }
            HStack {
                Spacer()
                Button("Submit") {
                    if let answer = draft.answer() { onAnswer(answer) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isComplete)
                .help(draft.isComplete ? "Send these answers" : "Answer every question first")
            }
        }
    }

    private func questionBlock(_ question: Question, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .fontWeight(.medium)
                .textSelection(.enabled)
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                optionRow(option, question: question, at: index)
            }
            TextField("Other", text: Binding(
                get: { draft.otherText(for: index) },
                set: { draft.setOther($0, for: index) }))
                .textFieldStyle(.roundedBorder)
                .help(question.multiSelect ? "Add an answer of your own" : "An answer of your own instead of the options")
        }
    }

    private func optionRow(_ option: Option, question: Question, at index: Int) -> some View {
        let on = draft.isSelected(option.label, for: index)
        return Button {
            if question.multiSelect {
                draft.toggle(option.label, for: index)
            } else {
                draft.choose(option.label, for: index)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: question.multiSelect
                    ? (on ? "checkmark.square.fill" : "square")
                    : (on ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
