import SwiftUI

/// v0.26 (PORT-12, ZG3, Larry's reference 2026-11-08): one mark per message
/// the person sent, in a tight stack (8 pt apart) centred on the chat's
/// height, just left of the reading column, in conversation order (the list
/// is lazy: off-screen rows have no measured position). This is the layout,
/// with no view in it; `MarkerRail` draws it.
struct ConversationMarker: Equatable, Identifiable {
    /// The transcript entry's id, which the scroll position knows.
    let id: String
    /// The tip's first line: the person's message on one line.
    let snippet: String
    /// The first two lines of the agent's reply to it; nil when there is none yet.
    var reply: String? = nil
    /// When the message was sent, if that is known (v0.25's rule: none beats a wrong one).
    let at: Date?
}

struct MarkerSlot: Equatable {
    let index: Int
    let y: CGFloat
    let drawn: Bool
    let style: Style

    enum Style: Equatable { case normal, inView, hovered }
}

extension MarkerSlot.Style {
    /// The mark's length (it grows to the right); every mark is 2 pt thick.
    var length: CGFloat {
        switch self {
        case .normal: 10
        case .inView: 14
        case .hovered: 22
        }
    }
}

enum ConversationMarkers {
    /// Fewer person messages than this: no rail.
    static let minimumCount = 3
    /// Drawn marks are this far apart.
    static let spacing: CGFloat = 8
    /// The stack thins out once it would be taller than this share of the chat's height.
    static let maximumShare: CGFloat = 0.4
    static let thickness: CGFloat = 2
    /// The rail's width: the hovered mark's length.
    static let railWidth: CGFloat = 22

    /// Whether a rail is drawn for `count` markers.
    static func shown(count: Int) -> Bool { count >= minimumCount }

    /// The person's drawn messages, oldest first; a thread's brief (`briefID`) is left out (ruling 19).
    /// Each carries the start of the agent's reply: the first reply text after it, before the
    /// person's next message.
    static func markers(_ entries: [TranscriptEntry], briefID: String?) -> [ConversationMarker] {
        var out: [ConversationMarker] = []
        var awaitingReply = false
        for entry in entries {
            guard case .item(let item) = entry else { continue }
            switch item {
            case .userText(let user):
                awaitingReply = false
                guard entry.id != briefID else { continue }
                out.append(ConversationMarker(
                    id: entry.id, snippet: snippet(user.text, lines: .max),
                    at: user.noTime == true ? nil : SessionTime.parse(user.ts)))
                awaitingReply = true
            case .assistantText(_, let text, _) where awaitingReply:
                let start = snippet(text)
                if !start.isEmpty, !out.isEmpty {
                    out[out.count - 1].reply = start
                    awaitingReply = false
                }
            default:
                continue
            }
        }
        return out
    }

    /// 1, 2, 4, 8 …: the smallest stride whose drawn marks, `spacing` apart, stay within
    /// `maximumShare` of the chat's `height`.
    static func stride(count: Int, height: CGFloat) -> Int {
        let allowed = height * maximumShare
        var s = 1
        while s < count {
            let gaps = Int((Double(count) / Double(s)).rounded(.up)) - 1
            if CGFloat(gaps) * spacing <= allowed { return s }
            s *= 2
        }
        return s
    }

    /// Every mark's y by order, the stack centred on `height` (drawn marks `spacing` apart,
    /// the thinned ones between them), and whether it is drawn: index % stride == 0, or
    /// hovered, or in view.
    static func slots(count: Int, height: CGFloat, inView: Set<Int>, hovered: Int?) -> [MarkerSlot] {
        guard count > 0 else { return [] }
        let step = stride(count: count, height: height)
        let pitch = spacing / CGFloat(step)
        let top = height / 2 - CGFloat(count - 1) * pitch / 2
        return (0..<count).map { index in
            let style: MarkerSlot.Style = index == hovered ? .hovered : inView.contains(index) ? .inView : .normal
            return MarkerSlot(
                index: index, y: top + CGFloat(index) * pitch, drawn: index % step == 0 || style != .normal,
                style: style)
        }
    }

    /// The drawn slot nearest `y`, for hover and click.
    static func nearest(_ y: CGFloat, in slots: [MarkerSlot]) -> Int? {
        slots.filter(\.drawn).min { abs($0.y - y) < abs($1.y - y) }?.index
    }

    /// A text's first `lines` lines (`\n`-split, trimmed, empty lines skipped), joined with a space.
    static func snippet(_ text: String, lines: Int = 2) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .joined(separator: " ")
    }

    /// "Yesterday 2:05 PM · Click to go back", or "Click to go back" with no time.
    static func tipFooter(
        _ at: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let at else { return "Click to go back" }
        return "\(MessageTime.short(at, now: now, calendar: calendar, locale: locale)) · Click to go back"
    }
}
