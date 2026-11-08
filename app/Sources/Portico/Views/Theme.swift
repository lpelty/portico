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
        case window, sidebar, panel, surface, control, borderSubtle, border, borderStrong, text, text2, text3, selected
        /// v0.23: the agent's avatar on a comment card (teal).
        case agentAvatar
        /// v0.23: a destructive confirm (Delete) with white text, 4.5:1 or more; darker than `deny`.
        case dangerStrong
        /// v0.26 (PORT-25): every colour the app draws is a token.
        case accent, accentSoft, onAccent
        case wait, waitSoft, onWait, working, deny, idle, stopped, meterTrack, meterFill
        case hoverTint, pressTint, scrim, shadowStrong, shadowSoft, knob, pointerShadow
        case tipFill, tipText, tipStroke, tipShadow
        /// Pen only (ruling 15): the code never draws these; AppKit draws the real window buttons.
        case shadow, windowClose, windowMinimize, windowZoom
        case logo1, logo2, logo3, logo4, logo5, logo6, logo7, logo8, logo9, logo10
    }

    static let palette: [Token: (light: String, dark: String)] = [
        .window: ("#FFFFFF", "#161618"),
        .sidebar: ("#EFEFF2", "#1C1C1F"),
        .panel: ("#F5F5F7", "#1B1B1D"),
        .surface: ("#EEEEF1", "#242427"),
        .control: ("#FFFFFF", "#2D2D31"),
        .border: ("#CACAD0", "#45454B"),
        .borderStrong: ("#B2B2BA", "#68686F"),
        // A quieter line than `border`, for lines that separate whole
        // regions rather than outline a control (v0.22.1: the status strip).
        .borderSubtle: ("#DDDDE2", "#2C2C30"),
        .text: ("#1C1C1E", "#F5F5F7"),
        .text2: ("#5E5E64", "#B6B6BC"),
        .text3: ("#6C6C72", "#8A8A91"),
        .selected: ("#E0E0E5", "#34343A"),
        .agentAvatar: ("#2F7A6B", "#3E8E7E"),
        .dangerStrong: ("#B3261E", "#C4362E"),
        .accent: ("#3B6BE0", "#6B8FF2"),
        .accentSoft: ("#EBF0FC", "#26304A"),
        // White text or glyph on any coloured fill (accent, brand, logo, level bars).
        .onAccent: ("#FFFFFF", "#FFFFFF"),
        .wait: ("#B86E00", "#F0B24A"),
        .waitSoft: ("#FFF3DE", "#3B2E16"),
        // Text on the bright `wait` highlight (an active comment anchor or a draft).
        .onWait: ("#FFFFFF", "#1C1C1E"),
        .working: ("#2DA44E", "#4CC86A"),
        // Deny and decline (V1): the Deny button, a declined or blocked step.
        .deny: ("#C93C37", "#F0706A"),
        .idle: ("#B5B5BB", "#6A6A70"),
        .stopped: ("#8E8E93", "#8E8E93"),
        // The context meter's empty track (S1) and its fill below the nudge.
        .meterTrack: ("#E4E4E7", "#3A3A3E"),
        .meterFill: ("#A3A3A8", "#A3A3A9"),
        // Laid over a clickable thing while the pointer is on it / while it is pressed.
        .hoverTint: ("#0000000D", "#FFFFFF12"),
        .pressTint: ("#0000001A", "#FFFFFF21"),
        // Behind the quick-open palette.
        .scrim: ("#00000040", "#00000040"),
        .shadowStrong: ("#0000004D", "#0000004D"),
        .shadowSoft: ("#0000002E", "#0000002E"),
        // The switch's knob.
        .knob: ("#FFFFFF", "#FFFFFF"),
        // The agent pointer's shadow colour (its opacity is the layer's).
        .pointerShadow: ("#000000", "#000000"),
        // AR7's tooltip (`rm4j7`): one style in light and dark.
        .tipFill: ("#2B2B2E", "#2B2B2E"),
        .tipText: ("#E6E6E8", "#E6E6E8"),
        .tipStroke: ("#FFFFFF1F", "#FFFFFF1F"),
        .tipShadow: ("#00000066", "#00000066"),
        .shadow: ("#00000022", "#00000066"),
        .windowClose: ("#FF5F57", "#FF5F57"),
        .windowMinimize: ("#FEBC2E", "#FEBC2E"),
        .windowZoom: ("#28C840", "#28C840"),
        // AR1/AR4's initial badges (MCP servers, Plugins).
        .logo1: ("#4F7DF3", "#4F7DF3"),
        .logo2: ("#E07A3F", "#E07A3F"),
        .logo3: ("#2F9E8F", "#2F9E8F"),
        .logo4: ("#8A6BD1", "#8A6BD1"),
        .logo5: ("#C9A227", "#C9A227"),
        .logo6: ("#D1567A", "#D1567A"),
        .logo7: ("#3F6FD8", "#3F6FD8"),
        .logo8: ("#5D6874", "#5D6874"),
        .logo9: ("#3F8CD1", "#3F8CD1"),
        .logo10: ("#7A8A3F", "#7A8A3F"),
    ]

    /// MCP servers' badge colours, in AR1's order.
    static let mcpLogoFills: [Token] = [.logo1, .logo2, .logo3, .logo4, .logo5, .logo6, .logo7, .logo8]
    /// Plugins' badge colours (AR4's, then AR1's), in today's order.
    static let pluginLogoFills: [Token] = [.logo6, .logo9, .logo10, .logo1, .logo2, .logo3, .logo4, .logo5]

    /// The token's variable name in `design/portico.pen`: the case name in
    /// kebab case, a digit run split off (`borderSubtle` → `border-subtle`,
    /// `text2` → `text-2`, `logo10` → `logo-10`).
    static func penName(_ token: Token) -> String {
        var out = ""
        var previous: Character?
        for c in String(describing: token) {
            if let p = previous {
                if c.isUppercase || (c.isNumber && !p.isNumber) { out.append("-") }
            }
            out.append(contentsOf: c.lowercased())
            previous = c
        }
        return out
    }

    static func hex(_ token: Token) -> (light: String, dark: String) {
        palette[token] ?? ("#FF00FF", "#FF00FF")
    }

    static func color(_ token: Token) -> Color {
        Color(nsColor: nsColor(token))
    }

    /// A token as an AppKit colour that follows the appearance, for what
    /// AppKit draws itself (a window's background and title bar).
    static func nsColor(_ token: Token) -> NSColor {
        let pair = hex(token)
        return dynamicNSColor(pair.light, pair.dark)
    }

    static let window = color(.window)
    static let sidebar = color(.sidebar)
    static let panel = color(.panel)
    static let surface = color(.surface)
    static let control = color(.control)
    static let border = color(.border)
    static let borderStrong = color(.borderStrong)
    static let borderSubtle = color(.borderSubtle)
    static let text = color(.text)
    static let text2 = color(.text2)
    static let text3 = color(.text3)
    static let selected = color(.selected)
    static let accent = color(.accent)
    static let accentSoft = color(.accentSoft)
    /// White text or glyph on a coloured fill.
    static let onAccent = color(.onAccent)
    static let wait = color(.wait)
    static let waitSoft = color(.waitSoft)
    static let onWait = color(.onWait)
    static let working = color(.working)
    /// Deny and decline (V1): the Deny button, a declined or blocked step.
    static let deny = color(.deny)
    static let idle = color(.idle)
    static let stopped = color(.stopped)
    /// The context meter's empty track (S1) and its fill below the nudge.
    static let meterTrack = color(.meterTrack)
    static let meterFill = color(.meterFill)
    /// Laid over a clickable thing while the pointer is on it.
    static let hoverTint = color(.hoverTint)
    /// Laid over it while it is pressed.
    static let pressTint = color(.pressTint)
    static let scrim = color(.scrim)
    static let shadowStrong = color(.shadowStrong)
    static let shadowSoft = color(.shadowSoft)
    static let knob = color(.knob)
    static let pointerShadow = color(.pointerShadow)
    /// AR7's tooltip: the same dark bubble in light and dark appearance.
    static let tipFill = color(.tipFill)
    static let tipText = color(.tipText)
    static let tipStroke = color(.tipStroke)
    static let tipShadow = color(.tipShadow)

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
        Color(nsColor: dynamicNSColor(light, dark))
    }

    static func dynamicNSColor(_ light: String, _ dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
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
    /// Rows take `solidRow()`; a folder's name is a row too (v0.22.1).
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
}

extension View {
    /// Every `.popover` content gets this (guarded by `PopoverSurfaceTests`).
    func popoverSurface() -> some View {
        modifier(PopoverSurface())
    }
}
