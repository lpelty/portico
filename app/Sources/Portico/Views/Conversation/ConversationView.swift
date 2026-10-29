import SwiftUI

/// One chat's conversation: the transcript (user bubbles, streamed
/// assistant text, folded tool rows, cards, turn markers) scrolled to the
/// newest item, the chat's last status line, and the input bar.
struct ConversationView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    private var items: [TranscriptItem] { model.transcripts[chat] ?? [] }

    /// The chat's folder, for showing the agent's paths relative to it.
    private var folder: String? { model.chats.first { $0.chat == chat }?.folder }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !model.pinnedCards(for: chat).isEmpty {
                pinnedCards
            }
            if let status = model.status[chat], !status.isEmpty {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 8)
            }
            if model.isSinglePresentation && model.isEnded(chat: chat) {
                EndedSessionBar(chat: chat)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 16)
            } else {
                InputBar(chat: chat)
                    .id(chat)
                    .padding(.horizontal, Self.sideInset)
                    .padding(.bottom, 16)
            }
        }
    }

    /// S5: a session that followed another opens with the line that says
    /// how the last one ended and when this one started.
    private var sessionDivider: SessionDivider? {
        guard model.isSinglePresentation, let summary = model.summary(of: chat), let parent = summary.parent else { return nil }
        let parentSummary = model.summary(of: parent)
            ?? ChatSummary(chat: parent, folder: summary.folder, alias: nil, state: .stopped, created: summary.created)
        return SessionDivider(parent: SessionPresentation(summary: parentSummary), current: SessionPresentation(summary: summary))
    }

    /// The frame's conversation inset: 32 at the sides, 24 above.
    static let sideInset: CGFloat = 32

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let divider = sessionDivider {
                        divider
                    }
                    if items.isEmpty {
                        emptyState
                    }
                    ForEach(items) { item in
                        TranscriptItemView(item: item, folder: folder, chat: chat)
                            .id(item.id)
                    }
                    if model.showsWorkingLine(chat: chat) {
                        WorkingLine(activity: model.activity(for: chat), since: model.turnStartedAt[chat])
                            .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollKey) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// The chat's open cards, pinned above the input until answered or
    /// cancelled. The answer goes through the model, which unpins the card
    /// and marks the inline copy.
    private var pinnedCards: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.pinnedCards(for: chat)) { card in
                    CardView(card: card, folder: folder, onAnswer: { model.answerCard($0) })
                        .id(card.id)
                }
            }
            .padding(.horizontal, Self.sideInset)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 320)
    }

    /// Changes whenever an item is added or the streaming tail grows.
    private var scrollKey: String {
        let working = model.showsWorkingLine(chat: chat) ? ":w" : ""
        return itemsKey + working
    }

    private var itemsKey: String {
        guard let last = items.last else { return "" }
        if case .assistantText(let id, let text) = last { return "\(items.count):\(id):\(text.count)" }
        return "\(items.count):\(last.id)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isSinglePresentation ? "Session \(chat)" : "Chat #\(chat)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(model.isLive(chat: chat) ? "Nothing yet. Say something below." : "Loading the transcript…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
        }
    }
}

/// One transcript item, by kind.
struct TranscriptItemView: View {
    let item: TranscriptItem
    var folder: String? = nil
    /// The chat the item belongs to: a tool row asks it whether its
    /// permission card is still open.
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch item {
        case .userText(let user):
            UserBubble(text: user.text)
        case .assistantText(_, let text):
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(7)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let row):
            ToolRowView(
                row: row, folder: folder,
                waiting: chat.map { model.permissionCard(chat: $0, toolUseId: row.toolUseId) != nil } ?? false)
        case .card(let card):
            CardInlineView(card: card, status: model.cardStatus(chat: card.chat, id: card.id))
        case .turnMarker(let marker):
            TurnMarkerView(marker: marker)
        case .compacted:
            CompactedLine()
        case .notice(_, let text):
            NoticeLine(text: text)
        }
    }
}

/// What the person sent, right-aligned on a tinted background. The text
/// is the gateway's `user.text`: what the engine received, attachments
/// listed under it.
struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(6)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 440, alignment: .trailing)
        }
    }
}

/// A thin line between turns with the outcome word; `done` stays quiet,
/// `stopped` and `error` say so.
struct TurnMarkerView: View {
    let marker: TurnMarker

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(marker.outcome == .error ? .red : Theme.text3)
                .fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var label: String {
        switch marker.outcome {
        case .done: "turn \(marker.turn)"
        case .stopped: "turn \(marker.turn) stopped"
        case .error: "turn \(marker.turn) ended with an error"
        }
    }
}

/// S5's divider at the top of a session that followed another:
/// `✓ Session 13 · Interview codebook · logged 11:40` between two rules,
/// and `Session 14 · started 11:42` under it.
struct SessionDivider: View {
    let parent: SessionPresentation
    let current: SessionPresentation

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 6) {
                    if parent.summary.logged == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(parent.parentLine())
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize()
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            Text(current.startedSecondLine())
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The quiet line a compaction leaves (S5): the engine summarized the
/// earlier conversation to make room. Shown, never hidden (design §2.1).
struct CompactedLine: View {
    static let text = "Earlier in this session was summarized to make room."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            Text(Self.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A quiet line from the gateway (`chat.notice`): an unknown command, say.
/// Not the agent's words, so small and dimmed, with no bubble.
struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text3)
        .accessibilityElement(children: .combine)
    }
}

/// Instead of the composer, for an ended session opened from "Earlier":
/// it is read-only, and the live one is a click away.
struct EndedSessionBar: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
            Text("Session \(chat) has ended. It is read-only.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
            if let live = model.liveSession {
                Button("Back to Session \(live.chat)") { model.open(chat: live.chat) }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}
