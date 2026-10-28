import SwiftUI

/// What the person has filled in on a form card, and the `card.answer`
/// it becomes: one value per field key (`text` → string, `choice` →
/// the chosen option, `toggle` → bool). View-free so it can be tested.
struct FormDraft: Equatable {
    let card: CardAsk
    private var values: [String: JSONValue] = [:]

    init(card: CardAsk) {
        self.card = card
        for field in card.form ?? [] {
            switch field.kind {
            case .text: values[field.key] = .string("")
            case .choice: values[field.key] = .string(field.options?.first ?? "")
            case .toggle: values[field.key] = .bool(false)
            }
        }
    }

    var fields: [FormField] { card.form ?? [] }

    func text(for key: String) -> String { values[key]?.stringValue ?? "" }
    mutating func setText(_ text: String, for key: String) { values[key] = .string(text) }

    func choice(for key: String) -> String { values[key]?.stringValue ?? "" }
    mutating func setChoice(_ option: String, for key: String) { values[key] = .string(option) }

    func toggle(for key: String) -> Bool {
        if case .bool(let on)? = values[key] { return on }
        return false
    }
    mutating func setToggle(_ on: Bool, for key: String) { values[key] = .bool(on) }

    /// Every text field has something in it and every choice is made.
    var isComplete: Bool {
        fields.allSatisfy { field in
            switch field.kind {
            case .text: !text(for: field.key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .choice: !choice(for: field.key).isEmpty
            case .toggle: true
            }
        }
    }

    func answer() -> CardAnswer? {
        guard isComplete else { return nil }
        var body: [String: JSONValue] = [:]
        for field in fields {
            switch field.kind {
            case .text: body[field.key] = .string(text(for: field.key).trimmingCharacters(in: .whitespacesAndNewlines))
            case .choice: body[field.key] = .string(choice(for: field.key))
            case .toggle: body[field.key] = .bool(toggle(for: field.key))
            }
        }
        return CardAnswer(chat: card.chat, id: card.id, answer: body)
    }
}

/// A deployment's structured ask: labelled fields by kind, and Submit
/// once every one is filled. The reference gateway never sends one; the
/// view exists so a deployment that does needs no app change.
struct FormCard: View {
    let card: CardAsk
    let onAnswer: (CardAnswer) -> Void
    @State private var draft: FormDraft

    init(card: CardAsk, onAnswer: @escaping (CardAnswer) -> Void) {
        self.card = card
        self.onAnswer = onAnswer
        _draft = State(initialValue: FormDraft(card: card))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.fields.isEmpty {
                Text("Nothing to fill in.")
                    .foregroundStyle(.secondary)
            }
            ForEach(draft.fields, id: \.key) { field in
                fieldRow(field)
            }
            HStack {
                Spacer()
                Button("Submit") {
                    if let answer = draft.answer() { onAnswer(answer) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isComplete)
                .help(draft.isComplete ? "Send the form" : "Fill in every field first")
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: FormField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.label, text: Binding(
                get: { draft.text(for: field.key) },
                set: { draft.setText($0, for: field.key) }))
                .textFieldStyle(.roundedBorder)
        case .choice:
            Picker(field.label, selection: Binding(
                get: { draft.choice(for: field.key) },
                set: { draft.setChoice($0, for: field.key) })) {
                ForEach(field.options ?? [], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { draft.toggle(for: field.key) },
                set: { draft.setToggle($0, for: field.key) }))
        }
    }
}
