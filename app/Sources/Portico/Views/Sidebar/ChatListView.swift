import AppKit
import SwiftUI

/// What a sidebar row shows for one chat: its number, the optional alias,
/// and its state in exactly the protocol's words (spec §5.4).
struct ChatRow: Equatable, Sendable {
    let summary: ChatSummary

    init(summary: ChatSummary) {
        self.summary = summary
    }

    var number: String { "#\(summary.chat)" }

    var alias: String? {
        let trimmed = summary.alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var stateWord: String { summary.state.rawValue }

    /// The folder's last path component, for the secondary line.
    var folderName: String {
        URL(fileURLWithPath: summary.folder).lastPathComponent
    }

    /// `#3 · notes` or `#3`.
    var title: String {
        alias.map { "\(number) · \($0)" } ?? number
    }
}

/// The chat list: numbered rows with state words, a New Chat button that
/// asks for a folder, and a context menu with stop, remove and alias.
struct ChatListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var aliasTarget: Int?
    @State private var aliasDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: selectionBinding) {
                ForEach(model.chats, id: \.chat) { summary in
                    row(for: ChatRow(summary: summary))
                        .tag(summary.chat)
                        .contextMenu { menu(for: summary) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.chats.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left", description: Text("New Chat picks a folder to work in."))
                }
            }
        }
        .alert("Alias for chat #\(aliasTarget ?? 0)", isPresented: aliasPresented) {
            TextField("Alias", text: $aliasDraft)
            Button("Save") {
                if let chat = aliasTarget { model.alias(chat: chat, aliasDraft) }
                aliasTarget = nil
            }
            Button("Cancel", role: .cancel) { aliasTarget = nil }
        } message: {
            Text("Optional. Leave it empty to clear.")
        }
    }

    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { model.selected },
            set: { chat in
                guard let chat, chat != model.selected else { return }
                model.open(chat: chat)
            })
    }

    private var aliasPresented: Binding<Bool> {
        Binding(get: { aliasTarget != nil }, set: { if !$0 { aliasTarget = nil } })
    }

    @ViewBuilder
    private func row(for row: ChatRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.number)
                    .font(.body.monospacedDigit())
                    .fontWeight(.medium)
                if let alias = row.alias {
                    Text(alias)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(row.stateWord)
                    .font(.caption)
                    .foregroundStyle(stateColor(row.summary.state))
            }
            Text(row.folderName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func stateColor(_ state: ChatStateWord) -> Color {
        switch state {
        case .idle: .secondary
        case .working: .accentColor
        case .waitingOnYou: .orange
        case .stopped: .secondary
        }
    }

    @ViewBuilder
    private func menu(for summary: ChatSummary) -> some View {
        Button("Open") { model.open(chat: summary.chat) }
        Button("Stop") { model.stop(chat: summary.chat) }
            .disabled(summary.state == .stopped)
        Button("Alias…") {
            aliasDraft = summary.alias ?? ""
            aliasTarget = summary.chat
        }
        Divider()
        Button("Remove", role: .destructive) { model.remove(chat: summary.chat) }
    }

    /// Ask for a folder (directories only) and start a chat there.
    /// The frame's "CHATS" header with the New Chat button at its right.
    private var header: some View {
        HStack(spacing: 8) {
            SidebarSectionLabel("Chats")
            Spacer(minLength: 0)
            Button(action: newChat) {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("New Chat").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.text)
                .padding(.vertical, 3)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Start a chat in a folder")
            .disabled(model.connection != .connected)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .padding(.horizontal, 16)
    }

    private func newChat() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Start Chat"
        panel.message = "Choose the folder the agent works in"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.newChat(folder: folder)
    }
}


/// A sidebar section label the way the frame sets it: small caps-like
/// tracking, 11 points, the dim text colour.
struct SidebarSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.text3)
    }
}
