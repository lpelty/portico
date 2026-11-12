import CoreGraphics
import Foundation
import os

/// A field diagnostic for "empty space under the conversation" (v0.16,
/// a deployment's field report, 11-02 item 11): not reproduced hosted, so the app
/// logs the one line that would show it when it happens on a person's
/// screen. v0.26.2: a view left past the content's end is also put back (`pastEnd`).
enum TranscriptBlankSpace {
    /// How long the view must stay blank, with no scroll phase, before it is reported.
    static let grace: TimeInterval = 1

    /// The clip may show this far past the document's end before it counts (rubber-banding, rounding).
    static let slack: CGFloat = 1

    /// Whether the visible area now shows blank where the conversation should be.
    /// - Parameters:
    ///   - hasRows: the conversation has rows to draw.
    ///   - rowFrames: the frames the drawn transcript rows report, in the scroll view's own space (its visible
    ///     area has its top left at the origin).
    ///   - otherFrames: the frames of what is drawn under the rows (calling cards, the working line), same space.
    ///   - clip: the scroll view's clip bounds (its visible area in the document).
    ///   - documentHeight: the document view's height.
    ///
    /// v0.26.4 (a field trace, 11-12): with rows to draw and not one of them laid out, the view is blank
    /// whatever else is in view. The lazy stack had dropped every row and parked the view at its estimated
    /// end; the cards under the rows follow that end, so counting them as drawn kept this quiet.
    static func isBlank(
        hasRows: Bool, rowFrames: [CGRect], otherFrames: [CGRect] = [], clip: CGRect, documentHeight: CGFloat
    ) -> Bool {
        guard hasRows, clip.height > 0 else { return false }
        if rowFrames.isEmpty { return true }
        let visible = CGRect(x: 0, y: 0, width: clip.width, height: clip.height)
        if !(rowFrames + otherFrames).contains(where: { $0.intersects(visible) }) { return true }
        return clip.maxY > documentHeight + slack
    }

    /// v0.26.4 (the same trace): back at the end, whether the last row must be scrolled to by its id before
    /// the bottom edge. Always, as since v0.19, with one exception: the reading is one where the view's
    /// visible height changed, nothing was wrapped again, and the last row is in view. There, the id scroll
    /// made with the last rows on screen is where the lazy stack swapped its measured height (7673) for an
    /// estimate (9570) and dropped every row; the edge alone keeps a measured end. Every other return to the
    /// end (a reply growing, the layout moving the offset, a width or text-size change) is as it was.
    /// - Parameters:
    ///   - lastRow: the last drawn row's reported frame in the scroll view's space, nil when it is not laid out.
    ///   - visibleHeight: the scroll view's visible height.
    ///   - heightChanged: the visible height changed at this reading.
    ///   - reflowed: every line was wrapped again at this reading (`reflowed(widthChanged:textScaleChangedAt:now:)`).
    static func endNeedsRowLayout(
        lastRow: CGRect?, visibleHeight: CGFloat, heightChanged: Bool, reflowed: Bool
    ) -> Bool {
        guard heightChanged, !reflowed, let lastRow, visibleHeight > 0, lastRow.height > 0 else { return true }
        return !(lastRow.maxY > 0 && lastRow.minY < visibleHeight)
    }

    /// Whether the visible height changed between two readings (none before the first).
    static func heightChanged(from previous: CGFloat?, to now: CGFloat) -> Bool {
        previous.map { abs($0 - now) >= 1 } ?? false
    }

    /// How long after a text-size change a reading still counts as its reflow: the rows are laid out again
    /// over several frames, and the scroll view's own width does not change to mark them.
    static let reflowWindow: TimeInterval = 1

    /// Whether a reading at `now` is a reflow's: the column's width changed at it, or the text size changed
    /// within `reflowWindow` before it.
    static func reflowed(widthChanged: Bool, textScaleChangedAt: Date?, now: Date) -> Bool {
        if widthChanged { return true }
        guard let changed = textScaleChangedAt else { return false }
        let since = now.timeIntervalSince(changed)
        return since >= 0 && since <= reflowWindow
    }

    /// v0.26.2 (a field trace, 11-09): where to put a view left past
    /// the document's end, or nil when it isn't. A column-width animation
    /// re-estimated the lazy stack's content shorter under a view scrolled up
    /// near the end, and the clip stayed where it was: nothing drawn until the
    /// person scrolled. The view goes to the end of the content (its top at
    /// the document's height less the view's), the nearest place with rows.
    static func pastEnd(clip: CGRect, documentHeight: CGFloat) -> CGFloat? {
        guard clip.height > 0, clip.maxY > documentHeight + slack else { return nil }
        return max(0, documentHeight - clip.height)
    }

    /// Reports once per occurrence: after `grace` seconds of blank readings, and not
    /// again until a reading is not blank.
    struct Watch: Equatable {
        private(set) var blankSince: Date?
        private(set) var reported = false
        /// v0.26.4: heals made since the view was last settled. A heal that brought no row back is tried
        /// again after another grace, `maxHeals` times at most. The count starts again only once the view
        /// has shown a row for `settle` seconds on end: a row that comes back for one reading and drops
        /// again (the heal's own id scroll could do that) does not buy three more heals.
        private(set) var heals = 0
        static let maxHeals = 3
        static let settle: TimeInterval = 10
        private(set) var shownSince: Date?

        var mayHeal: Bool { heals < Self.maxHeals }

        /// The view was scrolled back to its last row at `now`: the grace runs again from here.
        mutating func healed(now: Date) {
            heals += 1
            blankSince = now
            reported = false
        }

        /// One reading at `now`. Returns true when this reading is the one to log.
        mutating func observe(blank: Bool, scrolling: Bool, now: Date) -> Bool {
            guard blank, !scrolling else {
                // A scroll phase, or a view that is not blank, ends the occurrence.
                blankSince = nil
                reported = false
                if blank {
                    shownSince = nil
                } else {
                    let since = shownSince ?? now
                    shownSince = since
                    if now.timeIntervalSince(since) >= Self.settle { heals = 0 }
                }
                return false
            }
            shownSince = nil
            guard let since = blankSince else {
                blankSince = now
                return false
            }
            guard !reported, now.timeIntervalSince(since) > grace else { return false }
            reported = true
            return true
        }
    }

    /// The line that is logged: chat number, document height, clip bounds, the last
    /// reported row's frame, the scroll phase, whether the position is the bottom edge.
    static func line(
        chat: Int, documentHeight: CGFloat, clip: CGRect, lastRow: CGRect?, phase: String, atBottomEdge: Bool
    ) -> String {
        func rect(_ r: CGRect) -> String {
            "(x \(Int(r.minX)), y \(Int(r.minY)), w \(Int(r.width)), h \(Int(r.height)))"
        }
        return "blank space under the conversation: chat \(chat), document height \(Int(documentHeight)), "
            + "clip \(rect(clip)), last row \(lastRow.map(rect) ?? "none"), scroll phase \(phase), "
            + "position at bottom edge \(atBottomEdge ? "yes" : "no")"
    }

    /// Where the line goes: `log show --predicate 'subsystem == "<bundle id>" AND category == "transcript"'`.
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.portico", category: "transcript")

    static func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
