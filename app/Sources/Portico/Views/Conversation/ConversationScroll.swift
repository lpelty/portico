import CoreGraphics

/// Where the conversation was last seen, so a
/// change of the column's width (the viewer opening or closing, the
/// sidebar folding) puts it back there (v0.11 decision 6, item 67).
///
/// A narrower column wraps every line again and the transcript grows; the
/// scroll view keeps its offset from the top, so what was in view slides
/// away and the bottom is no longer the bottom. This remembers the place
/// it was last seen at, read as it scrolls but never from the
/// change of width itself, and says where to go after the width changes:
/// the bottom when it was at the bottom, else the same top message.
struct ConversationScrollMemory: Equatable, Sendable {
    /// How close to the end still counts as at the bottom.
    static let bottomSlack: CGFloat = 24

    /// Where to scroll after the width changes.
    enum Target: Equatable, Sendable {
        case bottom
        case item(String)
    }

    /// At the bottom until the person scrolls away: a conversation opens there.
    private(set) var atBottom = true
    /// The message at the top of the view when it was last seen.
    private(set) var topItem: String?
    /// The column's width the place was last seen at.
    private(set) var width: CGFloat?

    /// Whether an offset is at the end of the content (or the content fits).
    static func isAtBottom(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
        content <= visible || offset + visible >= content - bottomSlack
    }

    /// The conversation is seen at this place (scrolled there, or following the newest message).
    mutating func seen(atBottom: Bool, topItem: String?, width: CGFloat) {
        self.atBottom = atBottom
        self.topItem = topItem
        self.width = width
    }

    /// The column became `newWidth` wide: where to scroll so the person
    /// sees what they saw, or `nil` when nothing changed or nothing is known.
    mutating func widthChanged(to newWidth: CGFloat) -> Target? {
        defer { width = newWidth }
        guard let width, abs(width - newWidth) >= 1 else { return nil }
        if atBottom { return .bottom }
        return topItem.map(Target.item)
    }
}
