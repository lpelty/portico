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

    /// v0.26.4 (the same trace): back at the end after the view's size changed, whether the last row must be
    /// scrolled to by its id before the bottom edge. Only when it is not in view already: there, the id scroll
    /// made with the last rows on screen is where the lazy stack swapped its measured height (7673) for an
    /// estimate (9570) and dropped every row; the edge alone keeps a measured end.
    /// - Parameters:
    ///   - lastRow: the last drawn row's reported frame in the scroll view's space, nil when it is not laid out.
    ///   - visibleHeight: the scroll view's visible height.
    static func endNeedsRowLayout(lastRow: CGRect?, visibleHeight: CGFloat) -> Bool {
        guard let lastRow, visibleHeight > 0 else { return true }
        return !(lastRow.maxY > 0 && lastRow.minY < visibleHeight)
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

        /// One reading at `now`. Returns true when this reading is the one to log.
        mutating func observe(blank: Bool, scrolling: Bool, now: Date) -> Bool {
            guard blank, !scrolling else {
                // A scroll phase, or a view that is not blank, ends the occurrence.
                blankSince = nil
                reported = false
                return false
            }
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
