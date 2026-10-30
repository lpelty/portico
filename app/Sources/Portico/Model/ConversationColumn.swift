import CoreGraphics

/// The conversation's reading column (v0.11, item 58; frames AG1 and AG2):
/// replies, tool rows, the person's bubbles and the composer share one
/// centred column at most 768 wide (the desktop app's measure); a narrower
/// window gives it the whole width less the side insets. Replies and tool
/// rows take 92% of it, left-aligned; the person's bubble at most 70%,
/// right-aligned, and hugs a short message.
enum ConversationColumn {
    static let maxWidth: CGFloat = 768
    static let replyShare: CGFloat = 0.92
    static let bubbleShare: CGFloat = 0.70

    /// The column in a conversation `available` wide with `sideInset` at
    /// each side: never wider than `maxWidth`, never negative.
    static func width(available: CGFloat, sideInset: CGFloat) -> CGFloat {
        max(0, min(maxWidth, available - 2 * sideInset))
    }

    /// How wide the column and its side insets may be together: what holds
    /// the composer, the queued cards and the dock (each pads itself by the
    /// insets) is capped at this and centred.
    static func outerWidth(sideInset: CGFloat) -> CGFloat {
        maxWidth + 2 * sideInset
    }

    /// A reply's or a tool row's width in a column `column` wide.
    static func replyWidth(column: CGFloat) -> CGFloat {
        (column * replyShare).rounded()
    }

    /// The widest the person's bubble gets in a column `column` wide.
    static func bubbleMaxWidth(column: CGFloat) -> CGFloat {
        (column * bubbleShare).rounded()
    }
}
