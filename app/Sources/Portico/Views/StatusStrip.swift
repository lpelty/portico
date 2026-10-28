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
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(strip.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help(strip.text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(strip.text)")
    }

    private var dotColor: Color {
        switch model.connection {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}
