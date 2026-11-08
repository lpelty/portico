import SwiftUI

/// v0.26 (PORT-12, ZG3, Larry's reference 2026-11-08): one mark per message
/// the person sent, in a tight stack (8 pt apart) centred on the chat's
/// height, in the chat pane's left margin, in conversation order (the list
/// is lazy: off-screen rows have no measured position). This is the layout,
/// with no view in it; `MarkerRail` draws it.
///
/// Review H2: a marker holds its texts as they are (no copy) and works out the
/// tip's lines only when asked, from at most the first lines of each text.
struct ConversationMarker: Equatable, Identifiable {
    /// The transcript entry's id, which the scroll position knows.
    let id: String
    /// The person's message as sent.
    let text: String
    /// The agent's reply to it, as written; nil while there is none yet.
    var replyText: String? = nil
    /// The message's `ts`, nil when it has no real time (v0.25's rule: none beats a wrong one).
    let ts: String?

    init(id: String, text: String, replyText: String? = nil, ts: String?) {
        self.id = id
        self.text = text
        self.replyText = replyText
        self.ts = ts
    }

    init(id: String, text: String, replyText: String? = nil, at: Date?) {
        self.init(id: id, text: text, replyText: replyText, ts: at.map { ISO8601DateFormatter().string(from: $0) })
    }

    /// When the message was sent, parsed only when asked (the hovered tip).
    var at: Date? { ts.flatMap { SessionTime.parse($0) } }

    /// The tip's first line: the person's message on one line.
    var snippet: String { ConversationMarkers.snippet(text, lines: 3) }
    /// The first two lines of the agent's reply; nil when there is none yet.
    var reply: String? {
        guard let replyText else { return nil }
        let start = ConversationMarkers.snippet(replyText)
        return start.isEmpty ? nil : start
    }
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
    /// Each carries the agent's reply: the first reply text after it, before the person's next
    /// message. No text is split or copied here (review H2).
    static func markers(_ entries: [TranscriptEntry], briefID: String?) -> [ConversationMarker] {
        var out: [ConversationMarker] = []
        var awaitingReply = false
        for entry in entries {
            guard case .item(let item) = entry else { continue }
            switch item {
            case .userText(let user):
                awaitingReply = false
                guard entry.id != briefID else { continue }
                out.append(ConversationMarker(id: entry.id, text: user.text, ts: user.noTime == true ? nil : user.ts))
                awaitingReply = true
            case .assistantText(_, let text, _) where awaitingReply:
                if !out.isEmpty, text.contains(where: { !$0.isWhitespace }) {
                    out[out.count - 1].replyText = text
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

    /// A text's first `lines` non-empty lines (trimmed), joined with a space. Review H2: it reads
    /// only as far as it needs, never splitting the whole text, and keeps at most `maxLength` characters.
    static let maxSnippetLength = 300

    static func snippet(_ text: String, lines: Int = 2) -> String {
        var found: [Substring] = []
        var start = text.startIndex
        var length = 0
        while start < text.endIndex, found.count < lines, length < maxSnippetLength {
            // A line is looked at only as far as a snippet could reach.
            let reach = text.index(start, offsetBy: maxSnippetLength + 1, limitedBy: text.endIndex) ?? text.endIndex
            let newline = text[start..<reach].firstIndex(of: "\n")
            let end = newline ?? (text[reach...].firstIndex(of: "\n") ?? text.endIndex)
            let line = text[start..<(newline ?? reach)].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                found.append(Substring(line))
                length += line.count
            }
            start = end < text.endIndex ? text.index(after: end) : end
        }
        let joined = found.joined(separator: " ")
        return joined.count > maxSnippetLength ? String(joined.prefix(maxSnippetLength)) : joined
    }

    /// "Yesterday 2:05 PM · Click to go back", or "Click to go back" with no time.
    static func tipFooter(
        _ at: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let at else { return "Click to go back" }
        return "\(MessageTime.short(at, now: now, calendar: calendar, locale: locale)) · Click to go back"
    }
}

/// Review H2: the markers worked out once per transcript change, by its
/// revision key; scroll readings and redraws use what's here.
@MainActor
final class MarkerIndex {
    private(set) var key: String?
    private(set) var markers: [ConversationMarker] = []
    /// Each marker's position in `markers`, by id.
    private(set) var positions: [String: Int] = [:]
    /// How many times the markers were worked out (tests).
    private(set) var builds = 0

    /// The markers for the transcript at revision `key`; `entries` is asked only when it changed.
    func markers(key: String, entries: () -> [TranscriptEntry], briefID: String?) -> [ConversationMarker] {
        let full = key + "|" + (briefID ?? "")
        if full != self.key {
            markers = ConversationMarkers.markers(entries(), briefID: briefID)
            positions = Dictionary(markers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.key = full
            builds += 1
        }
        return markers
    }

    /// The person's messages whose rows (`frames`, in the scroll view) intersect 0…`visible`.
    func inView(frames: [String: CGRect], visible: CGFloat) -> Set<String> {
        var shown: Set<String> = []
        for (id, frame) in frames where frame.maxY > 0 && frame.minY < visible && positions[id] != nil {
            shown.insert(id)
        }
        return shown
    }
}
