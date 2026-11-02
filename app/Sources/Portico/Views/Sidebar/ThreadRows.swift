import SwiftUI

/// The other conversations under the sidebar's card (v0.16 §2.5, AM1):
/// label, title, a status (working spinner, amber Needs you, or the last
/// reply's age) and the key. A click switches; a thread's row has Close
/// thread in its context menu.
struct ThreadRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                ForEach(model.sidebarThreads.rows(now: context.date)) { row in
                    ThreadRow(row: row)
                    // A refused close shows under its row, so Close without
                    // logging is reachable from Main too.
                    if let failure = row.closeFailure {
                        CloseFailureLine(chat: row.chat, failure: failure)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
    }
}

private struct ThreadRow: View {
    let row: ThreadRowPresentation
    @EnvironmentObject private var model: AppModel

    private var needsYou: Bool { row.status == .needsYou }
    private var isThread: Bool { model.thread(of: row.chat) != nil }
    private var slot: Int { model.thread(of: row.chat)?.slot ?? 0 }

    var body: some View {
        Button { model.switchToConversation(slot: slot) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.text)
                    if let title = row.title {
                        Text(title)
                            .scaledFont(11)
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                status
                Text(row.key)
                    .scaledFont(11, monospacedDigit: true)
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(needsYou ? Theme.waitSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .help("Go to \(row.label) (\(row.key))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if isThread {
                Button("Close thread") { model.requestCloseThread(chat: row.chat) }
                    .disabled(model.closingThreads[row.chat] != nil || model.connection != .connected)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Working")
        case .needsYou:
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .font(Theme.iconFont(10))
                    .accessibilityHidden(true)
                Text("Needs you")
                    .scaledFont(11, weight: .medium)
            }
            .foregroundStyle(Theme.wait)
        case .lastReply(let ago):
            Text(ago)
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .fixedSize()
        case .none:
            EmptyView()
        }
    }
}
