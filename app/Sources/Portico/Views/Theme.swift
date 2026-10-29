import AppKit
import SwiftUI

/// The window's colours and measures, from `design/portico.pen` (variables
/// `window`, `sidebar`, `panel`, ... with a light and a dark value each),
/// so the app reads like the A1 frame in either appearance. The brand's
/// accent from `hello` replaces `accent` when the gateway sends one.
enum Theme {
    // MARK: colours (light, dark)

    static let window = dynamic("#FFFFFF", "#1E1E20")
    static let sidebar = dynamic("#F3F3F5", "#28282A")
    static let panel = dynamic("#F8F8F9", "#232325")
    static let surface = dynamic("#F2F2F4", "#2C2C2E")
    static let control = dynamic("#FFFFFF", "#343436")
    static let border = dynamic("#E4E4E7", "#3A3A3E")
    static let borderStrong = dynamic("#CDCDD2", "#4C4C50")
    static let text = dynamic("#1C1C1E", "#F2F2F4")
    static let text2 = dynamic("#6B6B70", "#A3A3A9")
    static let text3 = dynamic("#A3A3A8", "#6F6F75")
    static let selected = dynamic("#E3E3E7", "#3A3A3E")
    static let accent = dynamic("#3B6BE0", "#6B8FF2")
    static let accentSoft = dynamic("#EBF0FC", "#26304A")
    static let wait = dynamic("#B86E00", "#F0B24A")
    static let waitSoft = dynamic("#FFF3DE", "#3B2E16")
    static let working = dynamic("#2DA44E", "#4CC86A")
    /// Deny and decline (V1): the Deny button, a declined or blocked step.
    static let deny = dynamic("#C93C37", "#F0706A")
    static let idle = dynamic("#B5B5BB", "#6A6A70")
    static let stopped = dynamic("#8E8E93", "#8E8E93")
    /// The context meter's empty track (S1) and its fill below the nudge.
    static let meterTrack = dynamic("#E4E4E7", "#3A3A3E")
    static let meterFill = dynamic("#A3A3A8", "#A3A3A9")

    // MARK: measures

    /// The frame is 1440 x 900. The column widths are `ColumnWidths`.
    static let defaultWindowSize = CGSize(width: 1440, height: 900)
    static let minimumWindowSize = CGSize(width: 960, height: 600)
    static let toolbarHeight: CGFloat = 52
    static let statusStripHeight: CGFloat = 30
    /// Room for the traffic lights when the sidebar (which normally holds
    /// them in its own top band) is collapsed.
    static let trafficLightsInset: CGFloat = 78
    /// F3: the document view's folder tree.
    static let documentTreeWidth: CGFloat = 280
    /// F4: the quick-open palette.
    static let quickOpenWidth: CGFloat = 580
    /// S1: the session card's corner and the meter's height.
    static let cardRadius: CGFloat = 8
    static let meterHeight: CGFloat = 4

    /// A colour with one value in light appearance and another in dark.
    static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init(hex: String) {
        var digits = hex.dropFirst(hex.hasPrefix("#") ? 1 : 0)
        var value: UInt64 = 0
        if digits.count == 6 { digits += "FF" }
        Scanner(string: String(digits)).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 24) & 0xFF) / 255,
            green: CGFloat((value >> 16) & 0xFF) / 255,
            blue: CGFloat((value >> 8) & 0xFF) / 255,
            alpha: CGFloat(value & 0xFF) / 255)
    }
}
