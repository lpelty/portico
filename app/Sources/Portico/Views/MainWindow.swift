import SwiftUI

/// The window: sidebar of chats on the left, the conversation in the
/// centre (a placeholder until Task 17), the viewer on the right (Task 19).
/// A one-line strip under the toolbar says what the connection is doing
/// until the status strip (Task 21) replaces it.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        NavigationSplitView {
            ChatListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            VStack(spacing: 0) {
                connectionLine
                Divider()
                detail
            }
        }
        .navigationTitle(model.hello?.brand.name ?? "Portico")
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        if let chat = model.selected {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat #\(chat)")
                    .font(.title2)
                Text("\((model.transcripts[chat] ?? []).count) items in the transcript")
                    .foregroundStyle(.secondary)
                Text("The conversation pane lands with the next task.")
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No chat selected", systemImage: "sidebar.left",
                description: Text("Pick a chat in the sidebar, or start one with New Chat."))
        }
    }

    private var connectionLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(connectionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let status = model.gatewayStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private var connectionText: String {
        switch model.connection {
        case .connected:
            let agent = model.hello?.brand.agentName ?? "agent"
            return "Connected to \(agent)" + (model.hello.map { " (gateway \($0.gatewayVersion))" } ?? "")
        case .connecting: return "Connecting to the gateway"
        case .disconnected: return "Not connected"
        case .failed(let reason): return "Cannot reach the gateway: \(reason)"
        }
    }
}
