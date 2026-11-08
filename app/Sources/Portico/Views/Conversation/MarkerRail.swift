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
            let inViewIndices = Set(markers.indices.filter { inView.ids.contains(markers[$0].id) })
            let slots = ConversationMarkers.slots(
                count: markers.count, height: height, inView: inViewIndices, hovered: hovered)
            ZStack(alignment: .topLeading) {
                // The hit area: the stack's column, the whole height.
                Color.clear
                    .frame(width: ConversationMarkers.railWidth, height: height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
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
                ForEach(slots.filter(\.drawn), id: \.index) { slot in
                    Rectangle()
                        .fill(Self.colour(slot.style))
                        .frame(width: slot.style.length, height: ConversationMarkers.thickness)
                        .position(x: slot.style.length / 2, y: slot.y)
                        .allowsHitTesting(false)
                }
                // VoiceOver: every message, drawn or thinned out, is a button.
                ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(x: 0, y: slots[index].y)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("Your message: \(marker.snippet)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { onJump(marker.id) }
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
