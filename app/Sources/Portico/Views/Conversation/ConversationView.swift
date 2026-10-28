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
            CardPlaceholder(card: card)
        case .turnMarker(let marker):
            TurnMarkerView(marker: marker)
        }
    }
}

/// What the person sent, right-aligned on a tinted background. The text
/// is as it went to the gateway; attachments appear in the engine's
/// transcript, not here.
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

/// A card's place in the transcript until the cards module (Task 18)
/// renders it: the kind, the title, and that it is waiting.
struct CardPlaceholder: View {
    let card: CardAsk

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .fontWeight(.medium)
                Text(card.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.4)))
    }
}
