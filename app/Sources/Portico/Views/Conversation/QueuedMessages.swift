import SwiftUI

/// Messages typed while the agent works (v0.11, item 74; AG5): one card
/// per message the gateway holds, oldest first, on the composer and as
/// wide as it. Each says "Queued — sends at Acme's next step" with Edit
/// (back into the composer) and Cancel, then the message. A card goes
/// when the gateway's `chat.queue` no longer lists it: the message is in
/// the conversation by then, as the person's, where it went, or (after
/// Stop) back in the composer.
struct QueuedMessages: View {
    let chat: Int
    /// The composer's side margins, so a card is exactly its width.
    let sideInset: CGFloat
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.queuedMessages(chat: chat)
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { item in
                    card(item)
                }
            }
            .padding(.horizontal, sideInset)
            .padding(.bottom, 8)
        }
    }

    private func card(_ item: QueuedMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                Text(model.queuedLine(chat: chat))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SmallButton(symbol: "pencil", title: "Edit") { model.editQueued(chat: chat, id: item.id) }
                    .help("Take it back into the message box to change it")
                SmallButton(symbol: "xmark", title: "Cancel") { model.cancelQueued(chat: chat, id: item.id) }
                    .help("Don't send it")
            }
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.attachments.isEmpty {
                Text(item.attachments.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 8))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.queuedLine(chat: chat)): \(item.text)")
    }
}

/// The card's Edit and Cancel: a symbol and a word in a small bordered
/// box in the control colour, radius 6.
private struct SmallButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.text)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))))
    }
}
