import SwiftUI

/// One chat's conversation: the transcript (user bubbles, the agent's
/// Markdown, folded tool rows, cards, a note under a stopped or failed
/// turn) scrolled to the newest item, the chat's last status line, and
/// the input bar.
struct ConversationView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel
    /// The message at the top of the transcript's view (v0.11, item 67).
    @State private var topItem: String?
    /// Where the transcript was seen, put back when its width changes (v0.11, item 67).
    @State private var scrollMemory = ConversationScrollMemory()
    /// The transcript's width, for the reading column's (v0.11, item 58).
    @State private var transcriptWidth: CGFloat?

    private var items: [TranscriptItem] { model.transcripts[chat] ?? [] }

    /// The chat's folder, for showing the agent's paths relative to it.
    private var folder: String? { model.chats.first { $0.chat == chat }?.folder }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                // Y2: pinned over an earlier session's transcript, so the
                // way back is in view however long it is (v0.6; it used to
                // sit at the end, where the composer would be). An inset,
                // not a row above: the transcript's first item starts below
                // the bar, and what scrolls up goes under it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.showsEarlierBar(chat: chat) {
                        EndedSessionBar(chat: chat)
                            .padding(.horizontal, Self.sideInset)
                            .inConversationColumn()
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .background(Theme.window)
                    }
                }
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
                    .inConversationColumn()
            }
            if !model.showsEarlierBar(chat: chat) {
                // The running turn's agents or workflow sit on the composer,
                // as wide as it (v0.10 decisions 1 and 2, AF2 and AF3).
                AgentDock(chat: chat, sideInset: Self.sideInset)
                    .inConversationColumn()
                // What the person sent while the agent works, waiting for its next step (v0.11, AG5).
                QueuedMessages(chat: chat, sideInset: Self.sideInset)
                    .inConversationColumn()
                // An ended session is read-only: no composer.
                // The composer draws above the queued cards and the dock:
                // its slash list (v0.11 item 66) rises from the box's top
                // edge and floats over them while it is open.
                InputBar(chat: chat)
                    .id(chat)
                    .padding(.horizontal, Self.sideInset)
                    .inConversationColumn()
                    .padding(.bottom, 16)
                    .zIndex(1)
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
                    ForEach(items.filter { model.isDrawn($0, in: chat) }) { item in
                        TranscriptItemView(item: item, folder: folder, chat: chat)
                            .id(item.id)
                    }
                    if model.showsWorkingLine(chat: chat) {
                        WorkingLine(activity: model.activity(for: chat), since: model.turnStartedAt[chat])
                            .id("working")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                // v0.11 (58): the reading column, centred; its items size
                // themselves from its width (`conversationColumn`).
                .frame(maxWidth: ConversationColumn.maxWidth, alignment: .leading)
                .padding(.horizontal, Self.sideInset)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transcriptWidth = $0 }
            .environment(
                \.conversationColumn,
                transcriptWidth.map { ConversationColumn.width(available: $0, sideInset: Self.sideInset) })
            .scrollPosition(id: $topItem, anchor: .top)
            // v0.11 (67): opening the viewer narrows the column and every
            // line wraps again; put the conversation back where it was seen
            // (the bottom stays the bottom, else the same top message).
            .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
                TranscriptGeometry(
                    width: geometry.containerSize.width,
                    atBottom: ConversationScrollMemory.isAtBottom(
                        offset: geometry.contentOffset.y, visible: geometry.containerSize.height,
                        content: geometry.contentSize.height))
            } action: { _, now in
                switch scrollMemory.widthChanged(to: now.width) {
                case .bottom: proxy.scrollTo("bottom", anchor: .bottom)
                case .item(let id): proxy.scrollTo(id, anchor: .top)
                case nil: scrollMemory.seen(atBottom: now.atBottom, topItem: topItem, width: now.width)
                }
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
            .inConversationColumn()
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

/// The transcript's width and whether it is at its end, as its scroll
/// geometry changes (v0.11, item 67).
private struct TranscriptGeometry: Equatable {
    var width: CGFloat
    var atBottom: Bool
}

/// One transcript item, by kind.
struct TranscriptItemView: View {
    let item: TranscriptItem
    var folder: String? = nil
    /// The chat the item belongs to: a tool row asks it whether its
    /// permission card is still open.
    var chat: Int? = nil
    @EnvironmentObject private var model: AppModel
    /// The reading column's width, once measured (v0.11, item 58).
    @Environment(\.conversationColumn) private var column

    /// Replies and tool rows: 92% of the column, the whole width until it is measured.
    private var replyWidth: CGFloat {
        column.map(ConversationColumn.replyWidth) ?? .infinity
    }

    var body: some View {
        switch item {
        case .userText(let user):
            UserBubble(text: user.text, maxWidth: column.map(ConversationColumn.bubbleMaxWidth) ?? UserBubble.fallbackMaxWidth)
        case .assistantText(let id, let text):
            MarkdownText(text: text, id: id)
                .frame(maxWidth: replyWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let row):
            ToolRowView(
                row: row, folder: folder,
                waiting: chat.map { model.permissionCard(chat: $0, toolUseId: row.toolUseId) != nil } ?? false)
                .frame(maxWidth: replyWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .card(let card):
            CardInlineView(card: card, status: model.cardStatus(chat: card.chat, id: card.id))
        case .turnMarker(let marker):
            TurnMarkerView(marker: marker)
        case .compacted:
            CompactedLine()
        case .notice(_, let text):
            NoticeLine(text: text)
        case .agents(let group):
            if let chat {
                AgentGroupView(group: group, chat: chat, folder: folder)
            }
        }
    }
}

/// What the person sent, right-aligned on a tinted background. The text
/// is the gateway's `user.text`: what the engine received, attachments
/// listed under it. v0.11 (58, AG1): the replies' 16-point text, 10 by 16
/// padding, at most 70% of the reading column; a short message hugs.
struct UserBubble: View {
    let text: String
    /// The bubble's widest (`ConversationColumn.bubbleMaxWidth`).
    var maxWidth: CGFloat = fallbackMaxWidth

    /// Before the column is measured: 70% of the widest column.
    static let fallbackMaxWidth = ConversationColumn.bubbleMaxWidth(column: ConversationColumn.maxWidth)

    var body: some View {
        Text(text)
            .font(.system(size: MarkdownText.bodySize))
            .lineSpacing(MarkdownText.lineSpacing)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The end of a turn (v0.4): nothing for a turn that finished, a
/// one-line note under a stopped or failed one. The markers stay in the
/// model; chat apps draw no rule between turns.
struct TurnMarkerView: View {
    let marker: TurnMarker

    /// Whether an item is drawn at all: a finished turn's marker is not.
    static func isDrawn(_ item: TranscriptItem) -> Bool {
        if case .turnMarker(let marker) = item { return label(marker.outcome) != nil }
        return true
    }

    /// `Stopped`, `This turn ended with an error`, or nothing.
    static func label(_ outcome: Outcome) -> String? {
        switch outcome {
        case .done: nil
        case .stopped: "Stopped"
        case .error: "This turn ended with an error"
        }
    }

    var body: some View {
        if let label = Self.label(marker.outcome) {
            HStack(spacing: 6) {
                Image(systemName: marker.outcome == .error ? "exclamationmark.triangle" : "stop.circle")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(marker.outcome == .error ? Theme.deny : Theme.text3)
            .accessibilityElement(children: .combine)
        }
    }
}

/// S5's divider at the top of a session that followed another:
/// `✓ Session 13 · Interview codebook · logged today, 11:40 AM` between two
/// rules, and `Session 14 · started today, 11:42 AM` under it; re-read each
/// minute so a relative time moves (v0.7 decision 1).
struct SessionDivider: View {
    let parent: SessionPresentation
    let current: SessionPresentation

    var body: some View {
        TimelineView(.everyMinute) { context in
            lines(now: context.date)
        }
    }

    private func lines(now: Date) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 6) {
                    if parent.summary.logged == true {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(parent.parentLine(now: now))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
                .fixedSize()
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            Text(current.startedSecondLine(now: now))
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

/// Over an ended session opened from "Earlier" (Y2): which session, when
/// it ended, that it is read-only, and the way back to the live one as
/// the primary button.
struct EndedSessionBar: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
            TimelineView(.everyMinute) { context in
                Text(line(now: context.date))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let live = model.backTarget(from: chat) {
                Button { model.open(chat: live) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left")
                        Text("Back to Session \(live)")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(PillButtonStyle(kind: .primary(model.brand.accent ?? Theme.accent)))
                .help("Go back to Session \(live)")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

extension EndedSessionBar {
    /// `Session 12 · ended Oct 27, 4:12 PM · read-only`.
    private func line(now: Date) -> String {
        guard let summary = model.summary(of: chat) else { return "Session \(chat) · read-only" }
        return SessionPresentation(summary: summary).endedBarLine(now: now)
    }
}

// MARK: - The reading column (v0.11, item 58)

private struct ConversationColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The conversation's reading column width (`ConversationColumn`),
    /// `nil` until the transcript has been measured.
    var conversationColumn: CGFloat? {
        get { self[ConversationColumnKey.self] }
        set { self[ConversationColumnKey.self] = newValue }
    }
}

extension View {
    /// Cap something that pads itself by the conversation's side insets at
    /// the reading column plus those insets, centred: the composer, the
    /// queued cards, the dock and the status line line up with the replies.
    func inConversationColumn(sideInset: CGFloat = ConversationView.sideInset) -> some View {
        frame(maxWidth: ConversationColumn.outerWidth(sideInset: sideInset))
            .frame(maxWidth: .infinity)
    }
}
