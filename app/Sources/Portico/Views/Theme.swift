import AppKit
import SwiftUI

/// The window's colours and measures, from `design/portico.pen` (variables
/// `window`, `sidebar`, `panel`, ... with a light and a dark value each),
/// so the app reads like the A1 frame in either appearance. The brand's
/// accent from `hello` replaces `accent` when the gateway sends one.
enum Theme {
    // MARK: colours (light, dark)

    /// The solid palette (v0.19 spec §2.2): one table, read by the code and the tests.
    enum Token: CaseIterable {
        case window, sidebar, panel, surface, control, border, borderStrong, text, text2, text3, selected
    }

    static let palette: [Token: (light: String, dark: String)] = [
        .window: ("#FFFFFF", "#161618"),
        .sidebar: ("#EFEFF2", "#1C1C1F"),
        .panel: ("#F5F5F7", "#1B1B1D"),
        .surface: ("#EEEEF1", "#242427"),
        .control: ("#FFFFFF", "#2D2D31"),
        .border: ("#CACAD0", "#45454B"),
        .borderStrong: ("#BDBDC4", "#5C5C63"),
        .text: ("#1C1C1E", "#F5F5F7"),
        .text2: ("#5E5E64", "#B6B6BC"),
        .text3: ("#6C6C72", "#8A8A91"),
        .selected: ("#E0E0E5", "#34343A"),
    ]

    static func hex(_ token: Token) -> (light: String, dark: String) {
        palette[token] ?? ("#FF00FF", "#FF00FF")
    }

    private static func color(_ token: Token) -> Color {
        let pair = hex(token)
        return dynamic(pair.light, pair.dark)
    }

    static let window = color(.window)
    static let sidebar = color(.sidebar)
    static let panel = color(.panel)
    static let surface = color(.surface)
    static let control = color(.control)
    static let border = color(.border)
    static let borderStrong = color(.borderStrong)
    static let text = color(.text)
    static let text2 = color(.text2)
    static let text3 = color(.text3)
    static let selected = color(.selected)
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
    /// The sidebar's top band, under the traffic lights (the conversation
    /// toolbar beside it stays `toolbarHeight`).
    static let sidebarBandHeight: CGFloat = 36
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

// MARK: - text scale (v0.15 §3)

extension EnvironmentValues {
    /// The person's text scale (Settings › Appearance › Text size, ⌘+ and
    /// ⌘−), set at the window's root. 1 is 100%.
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

private struct TextScaleKey: EnvironmentKey {
    static var defaultValue: CGFloat { 1 }
}

extension Theme {
    /// An AppKit system font at `size` points times `scale`: AppKit-backed
    /// text does not read SwiftUI's environment, so it is given the scale.
    static func nsFont(_ size: CGFloat, scale: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size * scale, weight: weight)
    }

    /// A symbol's font: the size it is drawn at, never scaled (spec §3.4:
    /// icons keep their size when the text grows).
    static func iconFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// A system font whose size follows the environment's text scale.
private struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// `.font(.system(size:weight:design:))` at the person's text scale:
    /// every piece of text the app draws goes through this (v0.15 §3).
    /// Icons do not: they keep their size.
    func scaledFont(
        _ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}

// MARK: - popovers (v0.15 §5.7, 11-02)

extension EnvironmentValues {
    /// The view is drawn inside a Portico popover (set by `popoverSurface()`),
    /// so views shared with the window draw their faint text brighter.
    var inPopover: Bool {
        get { self[InPopoverKey.self] }
        set { self[InPopoverKey.self] = newValue }
    }
}

private struct InPopoverKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension Theme {
    /// The faint secondary colour: `text3` in the window, `text2` inside a
    /// popover, where the glass behind would wash `text3` out.
    static func faintText(inPopover: Bool) -> Color {
        inPopover ? text2 : text3
    }
}

/// What a popover's presentation draws: a solid `Theme.panel`.
enum PopoverPresentation {
    static let background: Color = Theme.panel
}

/// A solid `Theme.panel` behind a popover's whole content, edge to edge.
/// `.presentationBackground` replaces the system glass, arrow area included;
/// the fill underneath covers the content's own bounds. The system's rim is kept.
private struct PopoverSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { PopoverPresentation.background.ignoresSafeArea() }
            .presentationBackground(PopoverPresentation.background)
            .environment(\.inPopover, true)
    }
}

extension View {
    /// A plain, solid list on `Theme.sidebar` (v0.19: no system vibrancy).
    /// Rows take `solidRow()`, section headers `solidHeader()`.
    func solidList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebar)
    }

    /// A list row: the old sidebar insets, no separator, no row fill.
    func solidRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A section header with its own solid fill, so a pinned header never
    /// shows rows through it.
    func solidHeader() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sidebar)
    }
}

extension View {
    /// Every `.popover` content gets this (guarded by `PopoverSurfaceTests`).
    func popoverSurface() -> some View {
        modifier(PopoverSurface())
    }
}
