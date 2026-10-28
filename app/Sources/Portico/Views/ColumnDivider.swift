import AppKit
import SwiftUI

/// The 1-point line between two columns, with a 14-point invisible grip
/// centred on it (drawn above both neighbours, so all of it answers):
/// drag it to resize the column beside it, double-click it to put that
/// column back to its default width. The pointer shows the resize cursor
/// over the grip.
struct ColumnDivider: View {
    /// The drag so far, in points, positive to the right.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture(count: 2, perform: onReset)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onDrag($0.translation.width) }
                            .onEnded { _ in onEnd() }
                    )
            }
            .onDisappear {
                if hovering { NSCursor.pop() }
            }
            // Above the columns on both sides: otherwise the one drawn
            // after it covers half the grip.
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
