import SwiftUI

/// What the strip under the toolbar says, in order (spec §5.5): the
/// selected chat's state word · its folder's name · the model · the
/// context · the gateway (`stopped / starting / running :port / failed: …`)
/// · the socket when it is not simply connected. v0.3 dropped the free-text
/// status line: the working line in the conversation says what the agent
/// is doing.
struct StatusStripPresentation: Equatable, Sendable {
    /// The chat's state word in the protocol's words, or `no chat`.
    var chatText: String
    var folderName: String?
    var gatewayText: String
    var connectionText: String?
    /// The model's name from `context.usage` (A1/S5's Model segment), when known.
    var modelText: String? = nil
    /// `62% context`, when the gateway reports context usage.
    var contextText: String? = nil

    static let separator = " · "

    var text: String {
        [chatText, folderName, modelText, contextText, gatewayText, connectionText].compactMap { $0 }
            .joined(separator: Self.separator)
    }

    /// `claude-sonnet-5-5` reads `Claude Sonnet 5.5`; a dated id drops the
    /// date; a name that is not a Claude id is shown as sent.
    static func modelDisplayName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        guard parts.first?.lowercased() == "claude", parts.count > 1 else { return id }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.prefix { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = parts.drop { Int($0) == nil }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    static let restartText = "Restart the gateway to apply"

    static func updateText(_ version: String) -> String {
        "Update available (\(version))"
    }

    /// `62% context`, rounded to a whole percent.
    static func contextText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))% context"
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
            modelText: selected.flatMap { modelName(for: $0) }.map(StatusStripPresentation.modelDisplayName),
            contextText: selected.flatMap { contextPercent(for: $0) }.map(StatusStripPresentation.contextText))
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
                Text(model.selected == nil ? "ready" : strip.chatText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            if let folder = strip.folderName ?? (model.selected == nil ? model.startFolder?.lastPathComponent : nil) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(folder)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            }
            if let modelText = strip.modelText {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                    Text(modelText)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
            }
            if let contextText = strip.contextText {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 11))
                    Text(contextText)
                        .font(.system(size: 12).monospacedDigit())
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
            if model.configStale {
                Button {
                    Task { await model.restartGateway() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text(model.restarting ? "Restarting…" : StatusStripPresentation.restartText)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.wait)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .disabled(model.restarting)
                .help("The config file changed after the gateway started. Restart it to apply the change.")
            }
            if let version = model.offeredUpdate {
                Button {
                    Updater.relaunchForUpdate()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11))
                        Text(StatusStripPresentation.updateText(version))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(model.brand.accent ?? Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .help("Install the update: \(model.brand.name) closes, updates, and opens again")
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
