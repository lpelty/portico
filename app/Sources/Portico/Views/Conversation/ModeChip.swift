import SwiftUI

/// How the three permission modes read (V2): the chip's label, the
/// menu's line under it, and the icon.
struct PermissionModePresentation: Equatable {
    let mode: PermissionMode

    /// The order the menu lists them.
    static let all: [PermissionMode] = [.default, .acceptEdits, .auto]

    var label: String {
        switch mode {
        case .default: "Ask each time"
        case .acceptEdits: "Edits allowed"
        case .auto: "Auto"
        }
    }

    var detail: String {
        switch mode {
        case .default: "Every edit and command waits for you."
        case .acceptEdits: "File edits in this folder go through. Commands still ask."
        case .auto: "A safety check approves or blocks each step."
        }
    }

    var icon: String {
        switch mode {
        case .default: "hand.raised"
        case .acceptEdits: "square.and.pencil"
        case .auto: "checkmark.shield"
        }
    }

    /// The menu's heading: `WHEN PORTICO WANTS TO ACT`.
    static func heading(agentName: String) -> String {
        "When \(agentName) wants to act".uppercased()
    }

    static let footer = "New sessions start in the deployment's default mode."
}

/// The composer's mode chip: the mode's icon and label with a chevron;
/// a click opens the three modes, the current one checked.
struct ModeChip: View {
    let mode: PermissionMode
    var agentName: String = "Portico"
    var enabled: Bool = true
    let onPick: (PermissionMode) -> Void
    @State private var open = false

    var body: some View {
        let shown = PermissionModePresentation(mode: mode)
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: shown.icon)
                    .font(.system(size: 11))
                Text(shown.label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverCapsule)
        .disabled(!enabled)
        .help("When the agent wants to act: \(shown.label)")
        .accessibilityLabel("Permission mode: \(shown.label)")
        .popover(isPresented: $open, arrowEdge: .top) {
            menu
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(PermissionModePresentation.heading(agentName: agentName))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
            ForEach(PermissionModePresentation.all, id: \.self) { option in
                let shown = PermissionModePresentation(mode: option)
                Button {
                    open = false
                    onPick(option)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: shown.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shown.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text(shown.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if option == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(option == mode ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
            }
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
            Text(PermissionModePresentation.footer)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: 320)
    }
}

/// V2's working line at the end of the conversation while a turn runs:
/// a spinner, `Working`, what it is doing, and the elapsed time.
struct WorkingLine: View {
    let activity: String
    let since: Date?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
            Text("Working")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(detail(now: context.date))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(now: Date) -> String {
        guard let since else { return activity }
        return "\(activity) · \(AppModel.elapsedText(now.timeIntervalSince(since)))"
    }
}
