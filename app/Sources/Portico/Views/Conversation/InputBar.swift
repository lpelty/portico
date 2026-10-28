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
    @EnvironmentObject private var model: AppModel
    @State private var draft: String = ""
    @FocusState private var editorFocused: Bool

    private var attachments: [String] { model.draftAttachments[chat] ?? [] }
    private var busy: Bool { model.isBusy(chat: chat) }
    private var connected: Bool { model.connection == .connected }
    private var canSend: Bool {
        connected && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                chips
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor
                VStack(spacing: 6) {
                    if busy {
                        Button(action: { model.stopTurn(chat: chat) }) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the running turn (⌘.)")
                        .disabled(!connected)
                    } else {
                        Button(action: send) {
                            Label("Send", systemImage: "paperplane.fill")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .help("Send (⌘↩)")
                        .disabled(!canSend)
                    }
                    Button(action: pickAttachments) {
                        Label("Attach", systemImage: "paperclip")
                    }
                    .help("Attach files to the next message")
                    .disabled(!connected)
                }
                .labelStyle(.iconOnly)
                .controlSize(.regular)
            }
            if let actions = model.hello?.actions, !actions.isEmpty {
                actionButtons(actions)
            }
        }
        .padding(10)
        .background(.bar)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && !isDirectory($0) }.map(\.path)
            guard !files.isEmpty else { return false }
            model.attach(files, to: chat)
            return true
        }
        .onAppear { editorFocused = true }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($editorFocused)
        }
        .padding(2)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private var placeholder: String {
        if !connected { return "Not connected" }
        if busy { return "Working — Stop to interrupt" }
        return "Message \(model.hello?.brand.agentName ?? "the agent") (⌘↩ to send)"
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
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(path)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help(path)
                }
            }
        }
    }

    private func actionButtons(_ actions: [Action]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.label) {
                        model.sendMessage(chat: chat, text: action.text)
                    }
                    .controlSize(.small)
                    .help(action.text)
                    .disabled(!connected || busy)
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        model.sendMessage(chat: chat, text: draft)
        draft = ""
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
