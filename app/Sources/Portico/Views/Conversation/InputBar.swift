import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer under the conversation (V2): attachment chips, a
/// multi-line editor, the deployment's action buttons from
/// `hello.actions`, then `+` (attach), the permission mode chip, the
/// Enter hint, and Send — or Stop alone (⌘.) while the chat is `working`
/// or `waiting on you`. Enter sends, Shift+Enter adds a line. File URLs
/// dropped anywhere on the bar become chips; the Files pane adds chips
/// through `AppModel.attach`.
///
/// v0.11 (item 66, AG4): `/` at the start opens the slash list above the
/// box — Portico's own commands, then the agent's — filtered as one types;
/// ↑/↓ move, Enter or Tab pick, Esc closes.
struct InputBar: View {
    let chat: Int
    /// The document view's open file (F3): the placeholder asks about it
    /// and the message carries it as an attachment.
    var about: String? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dictation: Dictation
    @FocusState private var editorFocused: Bool
    @State private var slash = SlashListState()

    /// The editor's text lives in the model (per chat) so it survives
    /// switching chats and comes back when the gateway refuses a send.
    private var draft: Binding<String> {
        Binding(get: { model.draft(for: chat) }, set: { model.setDraft($0, for: chat) })
    }
    private var attachments: [String] { model.draftAttachments[chat] ?? [] }
    private var busy: Bool { model.isBusy(chat: chat) }
    /// A send is out and unanswered: the gateway may be starting the
    /// engine (seconds) before `turn.started` makes the chat `working`.
    private var sending: Bool { model.isSending(chat: chat) }
    private var connected: Bool { model.connection == .connected }
    /// A `session.renew` is out: the session is logging and the next one
    /// is not there yet, so nothing is sent until it is.
    private var renewing: Bool { model.isRenewing(chat: chat) }
    /// A `session.log` is out (v0.4): typing goes on, sending waits.
    private var logging: Bool { model.isLogging(chat: chat) }
    private var canSend: Bool { InputBar.canSend(model, chat: chat, text: draft.wrappedValue) }
    /// The slash list for what is typed, when it is open (v0.11 item 66).
    private var slashCompletion: SlashCompletion? {
        guard connected, !renewing else { return nil }
        return slash.completion(text: draft.wrappedValue, agentCommands: model.agentCommands(chat: chat))
    }

    static func canSend(_ model: AppModel, chat: Int, text: String) -> Bool {
        model.connection == .connected && !model.isBusy(chat: chat) && !model.isSending(chat: chat)
            && !model.isRenewing(chat: chat) && !model.isLogging(chat: chat)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// This composer for Talk (v0.9 decision 1): the words go into the
    /// chat's draft; "Send when I stop talking" sends it as Send would.
    private var voiceComposer: Dictation.Composer {
        Dictation.Composer(
            id: "chat-\(chat)",
            text: { [model, chat] in model.draft(for: chat) },
            setText: { [model, chat] in model.setDraft($0, for: chat) },
            send: { [model, chat, about] in
                let text = model.draft(for: chat)
                guard InputBar.canSend(model, chat: chat, text: text) else { return }
                model.sendMessage(chat: chat, text: text, about: about)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let actions = model.hello?.actions, !actions.isEmpty {
                actionChips(actions)
            }
            composer
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && !isDirectory($0) }.map(\.path)
            guard !files.isEmpty else { return false }
            model.attach(files, to: chat)
            return true
        }
        .onAppear { editorFocused = true }
    }

    /// The frame's Input: one bordered box in the control colour holding the
    /// editor, then a row with Attach at the left and Stop and Send at the right.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attachments.isEmpty {
                chips
            }
            editor
            HStack(spacing: 8) {
                Button(action: pickAttachments) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Attach files to the next message")
                .disabled(!connected)
                if let mode = model.mode(of: chat) {
                    ModeChip(
                        mode: mode, agentName: model.hello?.brand.agentName ?? model.brand.name,
                        enabled: connected && !renewing
                    ) { model.setMode($0, for: chat) }
                }
                Spacer(minLength: 0)
                // While Talk listens, its line in place of the Enter hint.
                Text(DictationLine.text(dictation, composer: voiceComposer.id) ?? InputBar.enterHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .layoutPriority(-1)
                MicButton(composer: voiceComposer)
                    .disabled(renewing)
                if busy {
                    Button(action: { model.stopTurn(chat: chat) }) {
                        Text("Stop")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the running turn (⌘.)")
                    .disabled(!connected)
                } else {
                    Button(action: send) {
                        Text("Send")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Enter)")
                    .disabled(!canSend)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .slashList {
            if let completion = slashCompletion {
                SlashCommandList(
                    completion: completion, selection: slash.selection,
                    agentName: model.hello?.brand.agentName ?? model.brand.name
                ) { item in
                    pickSlash(item, send: item.group == .portico)
                }
            }
        }
        .onChange(of: SlashCompletion.query(in: draft.wrappedValue)) { _, query in slash.queryChanged(to: query) }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: draft)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 20, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($editorFocused)
                .disabled(renewing)
                .onKeyPress(.return, phases: .down) { press in
                    if slashCompletion != nil, press.modifiers.isEmpty, !InputBar.isComposing() {
                        return slashKey(.enter)
                    }
                    return InputBar.handleReturn(modifiers: press.modifiers, composing: InputBar.isComposing(), send: send)
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down) { press in
                    guard let key = SlashCompletion.Key(press.key), press.modifiers.isEmpty || key != .tab else { return .ignored }
                    return slashKey(key)
                }
        }
    }

    /// A key while the slash list is open (v0.11 item 66); ignored when it is closed.
    private func slashKey(_ key: SlashCompletion.Key) -> KeyPress.Result {
        guard let completion = slashCompletion else { return .ignored }
        if let picked = slash.apply(completion.handle(key, selection: slash.selection)) {
            pickSlash(picked.item, send: picked.send)
        }
        return .handled
    }

    /// Put the picked command in the composer; send it when it is one of
    /// Portico's own picked with Enter (as Enter on a typed `/log` did).
    private func pickSlash(_ item: SlashCompletion.Item, send andSend: Bool) {
        draft.wrappedValue = item.completion
        editorFocused = true
        if andSend { send() }
    }

    private var placeholder: String {
        if !connected { return "Not connected" }
        if renewing { return "Starting the next session…" }
        if logging { return "Logging the session…" }
        if sending { return "Sending…" }
        if let about { return "Ask about \(URL(fileURLWithPath: about).lastPathComponent)" }
        return "Ask \(model.hello?.brand.agentName ?? model.brand.name), or drop a file here"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .lineLimit(1)
                        Button(action: { model.detach(path, from: chat) }) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.hover)
                        .foregroundStyle(.secondary)
                        .help("Remove \(path)")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .help(path)
                }
            }
        }
    }

    /// The deployment's actions as the frame's chips: a capsule in the
    /// control colour with a sparkle and the label.
    private func actionChips(_ actions: [Action]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        // On its own: the typed text and the chips stay for the
                        // message they belong to.
                        model.sendAction(chat: chat, text: action.text)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.text2)
                            Text(action.label)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Theme.control, in: Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.hoverCapsule)
                    .help(action.text)
                    .disabled(!connected || busy || sending || renewing || logging)
                }
            }
        }
    }

    static let enterHint = "Enter to send · Shift+Enter for a new line"

    /// Enter sends; Shift+Enter (or Option+Enter) is left to the editor,
    /// which adds a line. While an input method is composing (marked
    /// text: Japanese, Chinese, Korean…) Return belongs to it — it commits
    /// the composition — so it is left to the editor too and nothing is sent.
    static func handleReturn(
        modifiers: EventModifiers, composing: Bool = false, send: () -> Void
    ) -> KeyPress.Result {
        if composing || modifiers.contains(.shift) || modifiers.contains(.option) { return .ignored }
        send()
        return .handled
    }

    /// Whether the focused text view holds marked text from an input
    /// method. The composer is an `NSTextView` under SwiftUI's `TextEditor`,
    /// the key window's first responder while one types in it.
    @MainActor
    static func isComposing() -> Bool {
        guard let responder = NSApplication.shared.keyWindow?.firstResponder as? NSTextInputClient else { return false }
        return responder.hasMarkedText()
    }

    /// The model clears the draft on send and restores it if the gateway
    /// refuses (`attachment.missing`, `chat.busy`).
    private func send() {
        guard canSend else { return }
        // A talk into this composer ends first: what is shown is what goes.
        dictation.willSend(from: voiceComposer.id)
        model.sendMessage(chat: chat, text: draft.wrappedValue, about: about)
        editorFocused = true
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to the next message"
        guard panel.runModal() == .OK else { return }
        model.attach(panel.urls.map(\.path), to: chat)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}


/// The frame's Button: 13-point medium label, 6 by 14 padding, radius 6.
/// `primary` fills with the accent; `quiet` is the control colour with a
/// border, and reads dimmed when disabled (the frame's inactive Stop).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), quiet }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Pill(kind: kind, configuration: configuration)
    }

    /// The drawn pill; a view of its own so it can track the pointer.
    private struct Pill: View {
        let kind: Kind
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if case .quiet = kind {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(!isEnabled ? .clear : configuration.isPressed ? Theme.pressTint : hovering ? Theme.hoverTint : .clear)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }

    private var foreground: Color {
        if case .primary = kind { return .white }
        return Theme.text
    }

    private var background: Color {
        if case .primary(let accent) = kind { return accent }
        return Theme.control
    }
    }
}
