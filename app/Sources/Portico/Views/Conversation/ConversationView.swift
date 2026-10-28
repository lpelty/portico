import SwiftUI

/// One chat's conversation: the transcript (user bubbles, streamed
/// assistant text, folded tool rows, cards, turn markers) scrolled to the
/// newest item, the chat's last status line, and the input bar.
struct ConversationView: View {
    let chat: Int
    @EnvironmentObject private var model: AppModel

    private var items: [TranscriptItem] { model.transcripts[chat] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !model.pinnedCards(for: chat).isEmpty {
                Divider()
                pinnedCards
            }
            if let status = model.status[chat], !status.isEmpty {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            Divider()
            InputBar(chat: chat)
                .id(chat)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        emptyState
                    }
                    ForEach(items) { item in
                        TranscriptItemView(item: item)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
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
                    CardView(card: card, onAnswer: { model.answerCard($0) })
                        .id(card.id)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 320)
        .background(.bar)
    }

    /// Changes whenever an item is added or the streaming tail grows.
    private var scrollKey: String {
        guard let last = items.last else { return "" }
        if case .assistantText(let id, let text) = last { return "\(items.count):\(id):\(text.count)" }
        return "\(items.count):\(last.id)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chat #\(chat)")
                .font(.title3)
            Text(model.isLive(chat: chat) ? "Nothing yet. Say something below." : "Loading the transcript…")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

/// One transcript item, by kind.
struct TranscriptItemView: View {
    let item: TranscriptItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch item {
        case .userText(let user):
            UserBubble(text: user.text)
        case .assistantText(_, let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        case .tool(let row):
            ToolRowView(row: row)
        case .card(let card):
            CardInlineView(card: card, status: model.cardStatus(chat: card.chat, id: card.id))
        case .turnMarker(let marker):
            TurnMarkerView(marker: marker)
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
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// A thin line between turns with the outcome word; `done` stays quiet,
/// `stopped` and `error` say so.
struct TurnMarkerView: View {
    let marker: TurnMarker

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(marker.outcome == .error ? .red : .secondary)
                .fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private var label: String {
        switch marker.outcome {
        case .done: "turn \(marker.turn)"
        case .stopped: "turn \(marker.turn) stopped"
        case .error: "turn \(marker.turn) ended with an error"
        }
    }
}
