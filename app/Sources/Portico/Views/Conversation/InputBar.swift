import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer under the conversation: attachment chips, a multi-line
/// editor, the deployment's action buttons from `hello.actions`, and
/// Send (⌘↩) — or Stop (⌘.) while the chat is `working` or
/// `waiting on you`. File URLs dropped anywhere on the bar become chips;
/// the Files pane adds chips through `AppModel.attach`.
struct InputBar: View {
    let chat: Int
    /// The document view's open file (F3): the placeholder asks about it
    /// and the message carries it as an attachment.
    var about: String? = nil
    @EnvironmentObject private var model: AppModel
    @FocusState private var editorFocused: Bool

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
    private var canSend: Bool {
        connected && !busy && !sending && !renewing
            && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Attach files to the next message")
                .disabled(!connected)
                Spacer(minLength: 0)
                Button(action: { model.stopTurn(chat: chat) }) {
                    Text("Stop")
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the running turn (⌘.)")
                .disabled(!busy || !connected)
                Button(action: send) {
                    Text("Send")
                }
                .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
                .disabled(!canSend)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
                .frame(minHeight: 20, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($editorFocused)
                .disabled(renewing)
        }
    }

    private var placeholder: String {
        if !connected { return "Not connected" }
        if renewing { return "Starting the next session…" }
        if busy { return "Working — Stop to interrupt" }
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
                    .disabled(!connected || busy || sending || renewing)
                }
            }
        }
    }

    /// The model clears the draft on send and restores it if the gateway
    /// refuses (`attachment.missing`, `chat.busy`).
    private func send() {
        guard canSend else { return }
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
