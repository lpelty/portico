import SwiftUI

/// What the New space dialog collects (v0.16, AO2). Create sends it to Main
/// as one ordinary message.
struct NewSpaceDraft: Equatable {
    var name: String = ""
    var prompt: String = ""

    /// Both fields need words; Create stays dimmed until they have them.
    var canCreate: Bool { !trimmedName.isEmpty && !trimmedPrompt.isEmpty }

    /// `New space: <name>`, a blank line, then what the person wants.
    var message: String { "New space: \(trimmedName)\n\n\(trimmedPrompt)" }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The sheet: Name, What do you want?, Cancel and Create ⌘↩.
struct NewSpaceSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = NewSpaceDraft()
    @FocusState private var focus: Field?

    enum Field { case name, prompt }

    static let width: CGFloat = 480
    static let title = "New space"
    static let helper = "Main's agent makes it. It shows up in the space switcher when it's ready."
    static let footnote = "Sends to Main as a message."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            Text(Self.helper)
                .scaledFont(12)
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            label("Name").padding(.top, 14)
            TextField("", text: $draft.name)
                .textFieldStyle(.plain)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .focused($focus, equals: .name)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(outline(focused: focus == .name))
                .padding(.top, 6)
                .accessibilityLabel("Name")

            label("What do you want?").padding(.top, 14)
            TextEditor(text: $draft.prompt)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .prompt)
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
                .frame(height: 96)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(outline(focused: focus == .prompt))
                .padding(.top, 6)
                .accessibilityLabel("What do you want?")

            HStack(spacing: 8) {
                Text(Self.footnote)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text2)
                Spacer(minLength: 12)
                Button("Cancel") { model.newSpaceShown = false }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.createSpace(draft)
                } label: {
                    HStack(spacing: 5) {
                        Text("Create")
                        Text("⌘↩").scaledFont(11)
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.canCreate)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: Self.width)
        .background(Theme.panel)
        .onAppear { focus = .name }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .scaledFont(12)
            .foregroundStyle(Theme.text2)
    }

    private func outline(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(focused ? (model.brand.accent ?? Theme.accent) : Theme.border, lineWidth: focused ? 1.5 : 1)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Present the New space dialog while the model says it is up.
    func newSpaceSheet(_ model: AppModel) -> some View {
        sheet(isPresented: Binding(get: { model.newSpaceShown }, set: { model.newSpaceShown = $0 })) {
            NewSpaceSheet().environmentObject(model)
        }
    }
}
