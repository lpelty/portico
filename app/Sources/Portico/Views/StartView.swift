import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The start screen, frame "V4 · First launch" in design/portico.pen
/// (A4 before it): shown when no chat is selected. A greeting, one large
/// composer with `+`, the permission mode chip and Send, the deployment's
/// actions as suggestion chips, and a quiet line saying where the agent
/// works — the folder is chosen once (at setup, or the deployment's
/// default) and changed in Settings, not here. Enter (or Send) starts the
/// session in that folder and sends the message in one motion.
struct StartView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var connected: Bool { model.connection == .connected }
    private var canSend: Bool {
        connected && model.startFolder != nil && !model.isStarting
            && !model.startDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 28) {
            greeting
            VStack(alignment: .leading, spacing: 8) {
                composer
                if let error = model.startError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
            if let actions = model.hello?.actions, !actions.isEmpty {
                suggestions(actions)
            }
            folderLine
        }
        .frame(maxWidth: 720)
        .padding(EdgeInsets(top: 32, leading: 48, bottom: 120, trailing: 48))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    // MARK: greeting

    private var greeting: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(model.brand.accent ?? Theme.accent)
                Image(systemName: "sparkle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            Text(Self.greeting())
                .font(.system(size: 40, design: .serif))
                .tracking(-0.6)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// "Good morning, Larry": the part of the day and the first word of the
    /// account's full name; no name, no comma.
    static func greeting(at date: Date = Date(), fullName: String = NSFullUserName()) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.startAttachments.isEmpty {
                chips
            }
            ZStack(alignment: .topLeading) {
                if model.startDraft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.startDraft)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .frame(minHeight: 44, maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        InputBar.handleReturn(modifiers: press.modifiers, send: send)
                    }
            }
            HStack(spacing: 8) {
                Button(action: pickAttachments) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Attach files to the first message")
                ModeChip(
                    mode: model.startModeShown, agentName: model.hello?.brand.agentName ?? model.brand.name,
                    enabled: connected && !model.isStarting
                ) { model.startMode = $0 }
                Spacer(minLength: 0)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(model.brand.accent ?? Theme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .opacity(canSend ? 1 : 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .keyboardShortcut(.return, modifiers: .command)
                .help(model.startFolder == nil ? "Choose a folder in Settings first" : "Start and send (Enter)")
                .disabled(!canSend)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 16))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }.map(\.path)
            guard !files.isEmpty else { return false }
            model.attachToStart(files)
            return true
        }
    }

    private var placeholder: String {
        if !connected { return "Not connected" }
        if model.isStarting { return "Starting…" }
        return "What should we work on? Ask anything, or drop a file here"
    }

    /// V4's quiet line: where the agent works, and that Settings changes it.
    private var folderLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(model.workingFolderLine)
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.text3)
        .help(model.startFolder?.path ?? "Settings › General › Folder")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.startAttachments, id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        Button { model.detachFromStart(path) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.hover)
                        .foregroundStyle(Theme.text3)
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

    // MARK: suggestions

    private func suggestions(_ actions: [Action]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(actions.prefix(4).enumerated()), id: \.offset) { _, action in
                Button {
                    model.startChat(text: action.text, fromComposer: false)
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
                .disabled(!connected || model.startFolder == nil || model.isStarting)
            }
        }
    }

    // MARK: actions

    private func send() {
        guard canSend else { return }
        model.startChat(text: model.startDraft)
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        model.attachToStart(panel.urls.map(\.path))
    }
}
