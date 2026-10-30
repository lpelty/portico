import AppKit
import SwiftUI

// How anything clickable answers the pointer: the pointing hand, a tint
// while the pointer is over it, a deeper tint while it is held down.
// Buttons get all three from `HoverButtonStyle` (or `PillButtonStyle`);
// rows that act on a tap and menus get the hand and the hover tint from
// `.hoverHighlight()`.

extension Theme {
    /// Laid over a clickable thing while the pointer is on it.
    static let hoverTint = tint(lightAlpha: 0.05, darkAlpha: 0.07)
    /// Laid over it while it is pressed.
    static let pressTint = tint(lightAlpha: 0.10, darkAlpha: 0.13)

    private static func tint(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: darkAlpha)
                : NSColor(white: 0, alpha: lightAlpha)
        })
    }
}

/// The plain button of the app: the label as drawn, plus the pointing hand,
/// the hover tint and the press tint in `shape`. `.text` is for a button
/// that is only words ("Not now"): it underlines on hover instead.
struct HoverButtonStyle: ButtonStyle {
    enum Kind { case tint, text }

    var kind: Kind = .tint
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(label: configuration.label, pressed: configuration.isPressed, kind: kind, shape: shape)
    }

    private struct HoverBody<Label: View>: View {
        let label: Label
        let pressed: Bool
        let kind: Kind
        let shape: AnyShape
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Group {
                switch kind {
                case .tint:
                    label.overlay {
                        shape.fill(pressed ? Theme.pressTint : hovering ? Theme.hoverTint : .clear)
                            .allowsHitTesting(false)
                    }
                case .text:
                    label
                        .underline(hovering && isEnabled)
                        .opacity(pressed ? 0.6 : 1)
                }
            }
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// `HoverButtonStyle` with the rounded-rectangle tint.
    static var hover: HoverButtonStyle { HoverButtonStyle() }
    /// `HoverButtonStyle` in the composer's button box: radius 6, as Send (v0.11, 72).
    static var hoverBox: HoverButtonStyle {
        HoverButtonStyle(shape: AnyShape(RoundedRectangle(cornerRadius: InputBar.iconButtonCorner, style: .continuous)))
    }
    /// `HoverButtonStyle` tinting a capsule (chips).
    static var hoverCapsule: HoverButtonStyle { HoverButtonStyle(shape: AnyShape(Capsule())) }
    /// `HoverButtonStyle` for a button that is only words.
    static var hoverText: HoverButtonStyle { HoverButtonStyle(kind: .text) }
}

/// The hand and the hover tint for something that is not a `Button`: a
/// row that acts on a tap, a menu.
struct HoverHighlight: ViewModifier {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.fill(hovering ? Theme.hoverTint : .clear)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}

extension View {
    func hoverHighlight(_ shape: some Shape = RoundedRectangle(cornerRadius: 5, style: .continuous)) -> some View {
        modifier(HoverHighlight(shape: AnyShape(shape)))
    }
}
