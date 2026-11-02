import CoreGraphics
import Foundation
import os

/// A field diagnostic for "empty space under the conversation" (v0.16,
/// a deployment's field report, 11-02 item 11): not reproduced hosted, so the app
/// logs the one line that would show it when it happens on a person's
/// screen. Logs only; it changes nothing on screen.
enum TranscriptBlankSpace {
    /// How long the view must stay blank, with no scroll phase, before it is reported.
    static let grace: TimeInterval = 1

    /// The clip may show this far past the document's end before it counts (rubber-banding, rounding).
    static let slack: CGFloat = 1

    /// Whether the visible area now shows blank where the conversation should be.
    /// - Parameters:
    ///   - hasRows: the conversation has rows to draw.
    ///   - rowFrames: the frames the drawn rows report, in the scroll view's own
    ///     space (its visible area has its top left at the origin).
    ///   - clip: the scroll view's clip bounds (its visible area in the document).
    ///   - documentHeight: the document view's height.
    static func isBlank(hasRows: Bool, rowFrames: [CGRect], clip: CGRect, documentHeight: CGFloat) -> Bool {
        guard hasRows, clip.height > 0 else { return false }
        let visible = CGRect(x: 0, y: 0, width: clip.width, height: clip.height)
        if !rowFrames.contains(where: { $0.intersects(visible) }) { return true }
        return clip.maxY > documentHeight + slack
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
