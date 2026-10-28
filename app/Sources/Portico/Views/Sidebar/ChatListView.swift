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
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.chats, id: \.chat) { summary in
                        Button {
                            if model.selected != summary.chat { model.open(chat: summary.chat) }
                        } label: {
                            row(for: ChatRow(summary: summary))
                        }
                        .buttonStyle(.hover)
                        .background(
                            model.selected == summary.chat ? Theme.selected : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contextMenu { menu(for: summary) }
                        .accessibilityAddTraits(model.selected == summary.chat ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
            }
            .overlay {
                if model.chats.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left", description: Text("Your chats will be listed here."))
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

    private var aliasPresented: Binding<Bool> {
        Binding(get: { aliasTarget != nil }, set: { if !$0 { aliasTarget = nil } })
    }

    /// The frame's ChatRow: number, alias, and the state as a dot and word.
    @ViewBuilder
    private func row(for row: ChatRow) -> some View {
        let waiting = row.summary.state == .waitingOnYou
        HStack(spacing: 8) {
            Text(row.number)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
            Text(row.alias ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Circle()
                    .fill(stateColor(row.summary.state))
                    .frame(width: 7, height: 7)
                Text(row.stateWord)
                    .font(.system(size: 11, weight: waiting ? .semibold : .regular))
                    .foregroundStyle(waiting ? Theme.wait : Theme.text2)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .help(row.folderName)
    }

    private func stateColor(_ state: ChatStateWord) -> Color {
        switch state {
        case .idle: Theme.idle
        case .working: Theme.working
        case .waitingOnYou: Theme.wait
        case .stopped: Theme.stopped
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
            .buttonStyle(.hover)
            .help("Start a new chat")
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .padding(.horizontal, 16)
    }

    /// New Chat opens the start screen; the folder is chosen there and the
    /// chat is made on the first Send.
    private func newChat() {
        model.showStart()
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
