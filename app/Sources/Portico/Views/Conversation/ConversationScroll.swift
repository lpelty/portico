import CoreGraphics

/// Whether the conversation was last seen at its bottom, so a change of
/// the column's width (the viewer opening or closing, a space opening or
/// going back to Work, the sidebar folding) keeps it there (v0.11
/// decision 6, item 67).
///
/// A narrower column wraps every line again and the transcript grows, so
/// the bottom is no longer the bottom: that case scrolls back to it. A
/// conversation scrolled up is left alone: the scroll view's own position
/// (`scrollPosition(id:anchor:)`) keeps the message at the top and the
/// point in it across the reflow. v0.14 fix: this used to scroll to the
/// start of a remembered top message as well, which was coarse (the start
/// of a long reply, not the line being read) and could be stale (noted
/// only when the view left the bottom), so a space and back jumped the
/// conversation to another place.
struct ConversationScrollMemory: Equatable, Sendable {
    /// How close to the end still counts as at the bottom.
    static let bottomSlack: CGFloat = 24

    /// Where to scroll after the width changes.
    enum Target: Equatable, Sendable {
        case bottom
    }

    /// At the bottom until the person scrolls away: a conversation opens there.
    private(set) var atBottom = true
    /// The column's width the place was last seen at.
    private(set) var width: CGFloat?
    /// Whether an offset is at the end of the content (or the content fits).
    static func isAtBottom(offset: CGFloat, visible: CGFloat, content: CGFloat) -> Bool {
        content <= visible || offset + visible >= content - bottomSlack
    }

    /// The conversation is seen at this place (scrolled there, or following the newest message).
    mutating func seen(atBottom: Bool, width: CGFloat) {
        self.atBottom = atBottom
        self.width = width
    }

    /// The app scrolled to the end itself (the person's send, or following
    /// the newest message): the conversation is at its bottom (v0.15 task 2b
    /// fix round 1; the jump's own readings are not the person's).
    mutating func followed() {
        atBottom = true
    }

    /// One scroll-geometry reading, as the view gets it: its width, whether
    /// it is at the end, and whether the person is scrolling (the scroll
    /// view's phase). Returns where to scroll, if anywhere.
    ///
    /// A reading taken on a frame whose width changed is the reflow's, not
    /// the person's (fix round 1): scrolled up near the end, a step of the
    /// column's animation can read as the bottom, and recording it would
    /// snap the conversation to its end at the next change.
    ///
    /// v0.15 fix (task 2b): nor is any reading taken while the person is
    /// not scrolling. Found hosted: the width step scrolled to the end of
    /// the lazy stack's estimate, the rows then resolved at the new width
    /// and the end moved (189 pt), and at an unchanged width the layout
    /// moved the offset by itself (134 pt, content unchanged) and the
    /// app's own scroll landed short; each was taken for the person leaving
    /// the bottom, or never seen again. Only the person's scroll (and the
    /// app's `followed()`) moves the memory now. Any other reading off the
    /// end, while the memory says at the bottom, goes back to the bottom;
    /// scrolled up, it is left alone.
    mutating func observe(width: CGFloat, atBottom: Bool, byPerson: Bool) -> Target? {
        if let known = self.width, abs(known - width) >= 1 {
            return widthChanged(to: width)
        }
        if byPerson {
            seen(atBottom: atBottom, width: width)
            return nil
        }
        guard self.width != nil else {
            self.width = width  // the first look: a conversation opens at its bottom
            return nil
        }
        return self.atBottom && !atBottom ? .bottom : nil
    }

    /// The column became `newWidth` wide: `.bottom` when it was at the
    /// bottom; `nil` when nothing changed, nothing is known, or it was
    /// scrolled up (the scroll view keeps that place itself).
    mutating func widthChanged(to newWidth: CGFloat) -> Target? {
        defer { width = newWidth }
        guard let width, abs(width - newWidth) >= 1 else { return nil }
        return atBottom ? .bottom : nil
    }
}
