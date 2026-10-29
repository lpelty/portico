import SwiftUI

/// A card's id is the protocol's card id, so a list of open cards can be
/// a `ForEach`.
extension CardAsk: Identifiable {}

// MARK: - Presentation

/// How a card's status reads: nothing while open, `answered`, or
/// `cancelled: <reason>` (the gateway's reason, when it gave one).
struct CardStatusPresentation: Equatable {
    let status: CardStatus

    var label: String? {
        switch status {
        case .open: nil
        case .answered: "answered"
        case .cancelled(let reason): reason.isEmpty ? "cancelled" : "cancelled: \(reason)"
        }
    }

    var icon: String {
        switch status {
        case .open: "rectangle.on.rectangle.angled"
        case .answered: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }

    var tint: Color {
        switch status {
        case .open: .orange
        case .answered: .green
        case .cancelled: .secondary
        }
    }
}

/// A JSON object as people read it: keys sorted, two-space indented,
/// slashes unescaped. Shared by the tool row and the permission card.
enum PrettyJSON {
    static func render(_ object: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(object), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// One line that says what a card is about, for the inline copy and the
/// pinned card's header.
enum CardSummary {
    static func line(for card: CardAsk) -> String {
        switch card.kind {
        case .permission:
            let shown = PermissionPresentation(card: card)
            return shown.summary.isEmpty ? shown.tool : "\(shown.tool) — \(shown.summary)"
        case .question:
            let count = card.questions?.count ?? 0
            return count == 1 ? "1 question" : "\(count) questions"
        case .form:
            let count = card.form?.count ?? 0
            return count == 1 ? "1 field" : "\(count) fields"
        }
    }
}

// MARK: - The interactive card

/// A card the person can answer, by kind. Pinned above the input while
/// open; `onAnswer` receives the finished `card.answer`. A permission card
/// is drawn in its own V1 frame; questions and forms keep this one.
struct CardView: View {
    let card: CardAsk
    var folder: String? = nil
    let onAnswer: (CardAnswer) -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if card.kind == .permission {
            PermissionCard(
                card: card, folder: folder,
                agentName: model.hello?.brand.agentName ?? model.brand.name,
                accent: model.brand.accent ?? Theme.accent,
                onAnswer: onAnswer)
        } else {
            framed
        }
    }

    private var framed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: CardStatusPresentation(status: .open).icon)
                    .foregroundStyle(.orange)
                Text(card.title)
                    .font(.headline)
                Spacer()
                Text(card.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch card.kind {
            case .permission:
                EmptyView()
            case .question:
                QuestionCard(card: card, onAnswer: onAnswer)
            case .form:
                FormCard(card: card, onAnswer: onAnswer)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.4)))
    }
}

// MARK: - The inline copy

/// The card's place in the transcript: where it was asked, what it was
/// about, and what became of it. While open it points at the pinned copy
/// below; afterwards it says `answered` or `cancelled: <reason>`.
struct CardInlineView: View {
    let card: CardAsk
    let status: CardStatus

    private var shown: CardStatusPresentation { CardStatusPresentation(status: status) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: shown.icon)
                .foregroundStyle(shown.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .fontWeight(.medium)
                Text(CardSummary.line(for: card))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(shown.label ?? "waiting — answer below")
                .font(.caption)
                .foregroundStyle(status == .open ? .orange : .secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(shown.tint.opacity(status == .open ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shown.tint.opacity(0.4)))
        .help(shown.label ?? "Waiting for your answer in the card above the input")
    }
}
