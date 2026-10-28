import CoreGraphics

/// How wide the sidebar and the viewer are. Both are dragged by their
/// divider and remembered (settings); the viewer remembers one width per
/// fit, so a prototype widened once opens wide again while documents keep
/// their narrower column. Growing the window widens the conversation, never
/// the side columns.
enum ColumnWidths {
    /// What the viewer is showing, for its remembered width.
    enum Fit: String, Sendable {
        /// Documents, text, code, PDFs, images: a reading column.
        case reading
        /// Web pages and prototypes: as wide as the person made it.
        case canvas

        init(media: Media?) {
            switch media {
            case .html, .url: self = .canvas
            default: self = .reading
            }
        }
    }

    static let sidebarDefault: CGFloat = 260
    static let sidebarRange: ClosedRange<CGFloat> = 200...480
    static let viewerDefault: CGFloat = 440
    static let canvasDefault: CGFloat = 640
    static let viewerMinimum: CGFloat = 320
    /// The conversation never gets narrower than this while a side column
    /// can still give way.
    static let conversationMinimum: CGFloat = 420

    static func viewerDefault(for fit: Fit) -> CGFloat {
        fit == .canvas ? canvasDefault : viewerDefault
    }

    /// The widths to draw in a window `window` wide: the remembered widths,
    /// narrowed (viewer first, then the sidebar, never below their minimums)
    /// until the conversation has its minimum. `nil` is a hidden column.
    /// The remembered widths themselves are left alone, so a window that
    /// grows again gets them back.
    static func fit(sidebar: CGFloat?, viewer: CGFloat?, window: CGFloat) -> (sidebar: CGFloat?, viewer: CGFloat?) {
        var sidebar = sidebar.map(clampSidebar)
        var viewer = viewer.map { max($0, viewerMinimum) }
        var overflow = (sidebar ?? 0) + (viewer ?? 0) + conversationMinimum - window
        if overflow > 0, let v = viewer {
            let give = min(overflow, v - viewerMinimum)
            viewer = v - give
            overflow -= give
        }
        if overflow > 0, let s = sidebar {
            sidebar = s - min(overflow, s - sidebarRange.lowerBound)
        }
        return (sidebar, viewer)
    }

    static func clampSidebar(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarRange.lowerBound), sidebarRange.upperBound)
    }

    /// A dragged viewer width: at least the minimum, and no wider than
    /// leaves the conversation its minimum beside `sidebar` (0 when hidden).
    static func clampViewer(_ width: CGFloat, sidebar: CGFloat, window: CGFloat) -> CGFloat {
        let widest = max(viewerMinimum, window - sidebar - conversationMinimum)
        return min(max(width, viewerMinimum), widest)
    }
}
