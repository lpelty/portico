import AppKit
import SwiftUI

/// A marker click: scroll `chat`'s conversation to the message `id`.
/// `serial` makes a second click on the same mark a new request.
struct MarkerJumpRequest: Equatable {
    let chat: Int
    let id: String
    let serial: Int
}

/// The ids of the person's messages on screen (`ConversationView` notes them as it scrolls).
@MainActor
final class MarkersInView: ObservableObject {
    @Published var ids: Set<String> = []
}

/// v0.26 (PORT-12, ZG3/ZG3b, Larry's reference): the conversation markers, a
/// tight stack of short marks in the chat pane's left margin (10 pt from its
/// edge, the longest mark ending at the 32 pt margin), centred on its height. Hover shows the message, the start of the reply and its time; a
/// click goes back to it. Laid over the transcript, so it never moves the text.
struct MarkerRail: View {
    let markers: [ConversationMarker]
    /// Each marker's position by id (`MarkerIndex.positions`).
    var positions: [String: Int] = [:]
    @ObservedObject var inView: MarkersInView
    let onJump: (String) -> Void
    /// The tip's width at most, and how far right of the stack it sits.
    static let tipWidth: CGFloat = 330
    static let tipGap: CGFloat = 10
    /// The hover answers this close to a drawn mark.
    static let reach: CGFloat = 10

    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let inViewIndices = Set(inView.ids.compactMap { positions[$0] })
            let slots = ConversationMarkers.slots(
                count: markers.count, height: height, inView: inViewIndices, hovered: hovered)
            let drawn = slots.filter(\.drawn)
            let band = Self.hitBand(drawn)
            ZStack(alignment: .topLeading) {
                // The hit area: only the stack (review M2), from the first drawn mark minus
                // `reach` to the last plus `reach`; elsewhere the margin is the transcript's.
                Color.clear
                    .frame(width: ConversationMarkers.railWidth, height: band.height)
                    .contentShape(Rectangle())
                    .offset(y: band.minY)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let local):
                            let point = CGPoint(x: local.x, y: local.y + band.minY)
                            let index = ConversationMarkers.nearest(point.y, in: slots)
                            hovered = index.flatMap { abs(slots[$0].y - point.y) <= Self.reach ? $0 : nil }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture {
                        if let hovered, markers.indices.contains(hovered) { onJump(markers[hovered].id) }
                    }
                    .pointerStyle(hovered == nil ? nil : .link)
                    .accessibilityHidden(true)
                // The drawn marks only (review H2), each one VoiceOver button.
                ForEach(drawn, id: \.index) { slot in
                    Rectangle()
                        .fill(Self.colour(slot.style))
                        .frame(width: slot.style.length, height: ConversationMarkers.thickness)
                        .position(x: slot.style.length / 2, y: slot.y)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(Self.spokenLabel(index: slot.index, count: markers.count))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onJump(markers[slot.index].id) }
                }
                if let hovered, markers.indices.contains(hovered) {
                    MarkerTip(marker: markers[hovered])
                        .frame(width: Self.tipWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.top) { tip in
                            // Centred on the mark, clamped inside the transcript.
                            let top = slots[hovered].y - tip.height / 2
                            return -min(max(4, top), max(4, height - tip.height - 4))
                        }
                        .offset(x: ConversationMarkers.railWidth + Self.tipGap)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: ConversationMarkers.railWidth)
    }

    /// The vertical band the rail answers in: the drawn stack, `reach` beyond each end.
    static func hitBand(_ drawn: [MarkerSlot]) -> (minY: CGFloat, height: CGFloat) {
        guard let first = drawn.first?.y, let last = drawn.last?.y else { return (0, 0) }
        let top = drawn.map(\.y).min() ?? first, bottom = drawn.map(\.y).max() ?? last
        return (top - reach, bottom - top + 2 * reach)
    }

    /// What VoiceOver reads for a mark: its place, not the message (worked out only on hover).
    static func spokenLabel(index: Int, count: Int) -> String {
        "Your message \(index + 1) of \(count)"
    }

    /// Normal `text3`, in view `text2`, hovered `text` (Larry's reference).
    static func colour(_ style: MarkerSlot.Style) -> Color {
        switch style {
        case .normal: Theme.text3
        case .inView: Theme.text2
        case .hovered: Theme.text
        }
    }
}

/// The marker's tip, in the tooltip's style with a 10 pt corner: the person's
/// message on one line (semibold), the first two lines of the reply, then
/// the time and "Click to go back". The tip is the same dark bubble in either
/// appearance, so its second and third lines take `text2`'s and `text3`'s
/// dark values.
struct MarkerTip: View {
    let marker: ConversationMarker
    var now: Date = Date()
    static let cornerRadius: CGFloat = 10
    static let replyColour = Color(nsColor: NSColor(hex: Theme.hex(.text2).dark))
    static let footerColour = Color(nsColor: NSColor(hex: Theme.hex(.text3).dark))

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(marker.snippet)
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Theme.tipText)
                .lineLimit(1)
                .truncationMode(.tail)
            if let reply = marker.reply {
                Text(reply)
                    .scaledFont(11.5)
                    .foregroundStyle(Self.replyColour)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Text(ConversationMarkers.tipFooter(marker.at, now: now))
                .scaledFont(10.5)
                .foregroundStyle(Self.footerColour)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Theme.tipFill)
                .shadow(color: Theme.tipShadow, radius: Tip.shadowRadius / 2, y: Tip.shadowY))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Theme.tipStroke, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}
