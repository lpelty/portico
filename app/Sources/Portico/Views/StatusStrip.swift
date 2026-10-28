import SwiftUI

/// What the strip under the toolbar says, in order (spec §5.5): the
/// selected chat's state word · its folder's name · the gateway
/// (`stopped / starting / running :port / failed: …`) · the socket when it
/// is not simply connected · the last `status.set` line, verbatim.
struct StatusStripPresentation: Equatable, Sendable {
    /// The chat's state word in the protocol's words, or `no chat`.
    var chatText: String
    var folderName: String?
    var gatewayText: String
    var connectionText: String?
    var statusText: String?

    static let separator = " · "

    var text: String {
        [chatText, folderName, gatewayText, connectionText, statusText].compactMap { $0 }
            .joined(separator: Self.separator)
    }

    static func gatewayText(_ status: GatewaySupervisor.Status) -> String {
        switch status {
        case .stopped: "gateway stopped"
        case .starting: "gateway starting"
        case .running(let port): "gateway running :\(port)"
        case .failed(let reason): "gateway failed: \(reason)"
        }
    }

    /// The socket, only when it adds something: `connecting` while the
    /// app looks for a gateway, `not connected` when a running gateway has
    /// no socket, the reason when the connect failed for a reason the
    /// gateway indicator does not already give.
    static func connectionText(_ connection: AppModel.ConnectionState, gateway: GatewaySupervisor.Status) -> String? {
        switch connection {
        case .connected:
            nil
        case .connecting:
            "connecting"
        case .disconnected:
            if case .running = gateway { "not connected" } else { nil }
        case .failed(let reason):
            if case .failed(let why) = gateway, why == reason { nil } else { "cannot reach the gateway: \(reason)" }
        }
    }
}

extension AppModel {
    /// The strip's text for the selected chat and the supervisor's view of the gateway.
    func statusStrip(gateway: GatewaySupervisor.Status) -> StatusStripPresentation {
        let summary = selected.flatMap { id in chats.first { $0.chat == id } }
        return StatusStripPresentation(
            chatText: summary.map(\.state.rawValue) ?? "no chat",
            folderName: summary.map { URL(fileURLWithPath: $0.folder).lastPathComponent },
            gatewayText: StatusStripPresentation.gatewayText(gateway),
            connectionText: StatusStripPresentation.connectionText(connection, gateway: gateway),
            statusText: latestStatusLine(for: selected))
    }
}

/// The one-line strip under the toolbar: a dot for the socket, then the
/// composed text, truncated in the middle when the window is narrow.
struct StatusStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor

    var body: some View {
        let strip = model.statusStrip(gateway: supervisor.status)
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                Text(strip.chatText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            if let folder = strip.folderName {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(folder)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(gatewayColor)
                    .frame(width: 6, height: 6)
                Text(strip.gatewayText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            if let connection = strip.connectionText {
                Text(connection)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.wait)
            }
            Spacer(minLength: 8)
            if let status = strip.statusText {
                Text(status)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.statusStripHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .help(strip.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(strip.text)")
    }

    /// The chat's state in the frame's colours; the socket's trouble shows red.
    private var stateColor: Color {
        if case .failed = model.connection { return .red }
        guard let id = model.selected, let summary = model.chats.first(where: { $0.chat == id }) else { return Theme.idle }
        switch summary.state {
        case .idle: return Theme.idle
        case .working: return Theme.working
        case .waitingOnYou: return Theme.wait
        case .stopped: return Theme.stopped
        }
    }

    private var gatewayColor: Color {
        switch supervisor.status {
        case .running: model.connection == .connected ? Theme.working : Theme.wait
        case .starting: Theme.wait
        case .stopped: Theme.idle
        case .failed: .red
        }
    }
}
