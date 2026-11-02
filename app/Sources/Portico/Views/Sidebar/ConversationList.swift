import SwiftUI

/// The sidebar's CONVERSATIONS list (v0.16 §9.6, Pen AP4/AP5): Main,
/// Thread 1, Thread 2 in a fixed order, all on the same left edge and
/// width, so nothing moves when you switch. The row you're in is the open
/// card (`SessionCard`); the others are rows with their label, subtitle
/// and a status (working spinner, amber Needs you, an accent dot and New
/// reply, or the last reply's age). No key glyph: the tooltip spells the
/// key (§9.2). A click switches; a thread's row has Close thread in its
/// context menu.
struct ConversationList: View {
    @EnvironmentObject private var model: AppModel

    /// The rows' and the open card's inner left edge, so the icons line up.
    static let rowInset: CGFloat = 10

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                ForEach(model.sidebarThreads.rows(now: context.date)) { row in
                    if row.isOpen, let card = model.sidebarCard, card.chat == row.chat {
                        SessionCard(summary: card)
                            .padding(.vertical, 2)
                    } else {
                        ThreadRow(row: row)
                        // A refused close shows under its row, so Close without
                        // logging is reachable from Main too. The open card
                        // shows it in its footnote.
                        if let failure = row.closeFailure {
                            CloseFailureLine(chat: row.chat, failure: failure)
                                .padding(.horizontal, Self.rowInset)
                                .padding(.bottom, 4)
                        }
                    }
                }
            }
        }
    }
}

/// Main's speech bubble, a thread's branch (§9.6).
struct ConversationIcon: View {
    let isThread: Bool

    var body: some View {
        Image(systemName: isThread ? "arrow.triangle.branch" : "bubble.left")
            .font(Theme.iconFont(13))
            .foregroundStyle(Theme.text2)
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

private struct ThreadRow: View {
    let row: ThreadRowPresentation
    @EnvironmentObject private var model: AppModel

    private var needsYou: Bool { row.status == .needsYou }

    var body: some View {
        Button { model.switchToConversation(slot: row.slot) } label: {
            HStack(spacing: 8) {
                ConversationIcon(isThread: row.isThread)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .scaledFont(13, weight: .medium)
                        .foregroundStyle(Theme.text)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .scaledFont(11)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                status
            }
            .padding(.vertical, 6)
            .padding(.horizontal, ConversationList.rowInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
        .background(needsYou ? Theme.waitSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusEffectDisabled()
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if row.isThread {
                Button("Close thread") { model.requestCloseThread(chat: row.chat) }
                    .disabled(model.isClosing(chat: row.chat) || model.connection != .connected)
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
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Theme.wait)
        case .newReply:
            // §9.3: until the thread is opened.
            HStack(spacing: 5) {
                Circle()
                    .fill(model.brand.accent ?? Theme.accent)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("New reply")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
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
