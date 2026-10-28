import SwiftUI

/// The 1-point line between two panes, with a 14-point invisible grip
/// centred on it (drawn above both neighbours, so all of it answers):
/// drag it to resize the pane beside it, double-click it to put that pane
/// back to its default size. The pointer shows the resize cursor over the
/// grip. `.vertical` is a line between columns (dragged sideways),
/// `.horizontal` one between stacked panes (dragged up and down).
struct ColumnDivider: View {
    var axis: Axis = .vertical
    /// The drag so far, in points: positive to the right, or down.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    private static let grip: CGFloat = 14

    var body: some View {
        let sideways = axis == .vertical
        Rectangle()
            .fill(Theme.border)
            .frame(width: sideways ? 1 : nil, height: sideways ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: sideways ? Self.grip : nil, height: sideways ? nil : Self.grip)
                    .contentShape(Rectangle())
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
