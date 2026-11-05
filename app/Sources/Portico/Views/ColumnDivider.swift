import SwiftUI

/// The 1-point line between two panes, with a 14-point invisible grip
/// centred on it (drawn above both neighbours, so all of it answers):
/// drag it to resize the pane beside it, double-click it to put that pane
/// back to its default size. The pointer shows the resize cursor over the
/// grip. `.vertical` is a line between columns (dragged sideways),
/// `.horizontal` one between stacked panes (dragged up and down).
///
/// `gripSide` (v0.14, §6b.2) moves the grip off-centre: `.leading` puts
/// all of it on the line's left (or upper) side. The viewer divider uses
/// it, because the web view beside it is an AppKit view that takes the
/// mouse over whatever part of the grip overlaps it.
struct ColumnDivider: View {
    enum GripSide { case centred, leading, trailing }

    var axis: Axis = .vertical
    var gripSide: GripSide = .centred
    /// The drag so far, in points: positive to the right, or down.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    static let grip: CGFloat = 14
    private static let line: CGFloat = 1

    /// Where the grip runs across the line, in the line's coordinates (the
    /// line itself is `0...1`).
    static func gripSpan(_ side: GripSide) -> ClosedRange<CGFloat> {
        let start = (line - grip) / 2 + offset(side)
        return start...(start + grip)
    }

    /// How far the grip reaches past the line's leading (left or top) edge.
    static func overhang(_ side: GripSide) -> CGFloat {
        -gripSpan(side).lowerBound
    }

    /// How far the grip moves from centred on the line: negative is left (or up).
    static func offset(_ side: GripSide) -> CGFloat {
        switch side {
        case .centred: 0
        case .leading: -(grip - line) / 2
        case .trailing: (grip + line) / 2 - line
        }
    }

    var body: some View {
        let sideways = axis == .vertical
        Rectangle()
            .fill(Theme.border)
            .frame(width: sideways ? Self.line : nil, height: sideways ? nil : Self.line)
            .overlay {
                Color.clear
                    .frame(width: sideways ? Self.grip : nil, height: sideways ? nil : Self.grip)
                    .contentShape(Rectangle())
                    .offset(x: sideways ? Self.offset(gripSide) : 0, y: sideways ? 0 : Self.offset(gripSide))
                    .pointerStyle(sideways ? .columnResize : .rowResize)
                    .onTapGesture(count: 2, perform: onReset)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onDrag(sideways ? $0.translation.width : $0.translation.height) }
                            .onEnded { _ in onEnd() }
                    )
            }
            // Above the panes on both sides: otherwise the one drawn after
            // it covers half the grip.
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// How far the viewer divider's grip reaches over the conversation
    /// (fix I-1): its scrollers keep this far from the column's right edge.
    var viewerGripClearance: CGFloat {
        get { self[ViewerGripClearanceKey.self] }
        set { self[ViewerGripClearanceKey.self] = newValue }
    }
}

private struct ViewerGripClearanceKey: EnvironmentKey {
    static var defaultValue: CGFloat { 0 }
}

extension View {
    /// Moves this scroll view's scrollers in by `viewerGripClearance`, so
    /// the viewer divider's grip never sits over them (a drag on the
    /// scroller scrolls, rather than resizing the viewer).
    func clearOfViewerGrip() -> some View {
        modifier(ClearOfViewerGrip())
    }
}

private struct ClearOfViewerGrip: ViewModifier {
    @Environment(\.viewerGripClearance) private var clearance

    func body(content: Content) -> some View {
        content.contentMargins(.trailing, clearance, for: .scrollIndicators)
    }
}
