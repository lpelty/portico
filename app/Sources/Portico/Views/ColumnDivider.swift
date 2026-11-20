import SwiftUI

/// The 1-point line between two panes, with a 14-point invisible grip
/// centred on it (drawn above both neighbours, so all of it answers):
/// drag it to resize the pane beside it, double-click it to put that pane
/// back to its default size. The pointer shows the resize cursor over the
/// grip. `.vertical` is a line between columns (dragged sideways),
/// `.horizontal` one between stacked panes (dragged up and down).
///
/// `gripSide` (v0.14, §6b.2) moves the grip off-centre: `.leading` puts
/// all of it on the line's left (or upper) side.
///
/// `grips: false` (v0.28) draws the line alone. The viewer divider does
/// that and takes its grip from `DividerGrip`, an AppKit view laid over the
/// window: the web view beside the line is an AppKit view that takes the
/// mouse over whatever part of a SwiftUI grip overlaps it.
struct ColumnDivider: View {
    enum GripSide { case centred, leading, trailing }

    var axis: Axis = .vertical
    var gripSide: GripSide = .centred
    var grips = true
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
                if grips {
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
            }
            // Above the panes on both sides: otherwise the one drawn after
            // it covers half the grip.
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// v0.28: a column divider's grip as an AppKit view, for a line with an
/// AppKit view beside it (the viewer's web view). Laid over the window, it
/// is above that view, so the pointer on the line and on both sides of it
/// shows the resize cursor and a drag from there resizes. The same 14
/// points as `ColumnDivider`'s grip; a double click resets.
struct DividerGrip: NSViewRepresentable {
    /// The drag so far, in points: positive to the right.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> DividerGripView {
        let view = DividerGripView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DividerGripView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onReset = onReset
    }
}

final class DividerGripView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onReset: () -> Void = {}
    /// Where the pointer was on the screen when the drag began.
    private var dragStart: CGFloat?
    private var tracking: NSTrackingArea?

    static let cursor = NSCursor.columnResize

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    /// The view under the grip sets the pointer for itself as the mouse
    /// moves over it; the grip sets it again on every move.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { Self.cursor.set() }
    override func mouseEntered(with event: NSEvent) { Self.cursor.set() }
    override func mouseMoved(with event: NSEvent) { Self.cursor.set() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onReset()
            return
        }
        dragStart = Self.screenX(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        Self.cursor.set()
        onDrag(Self.screenX(event) - dragStart)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnd()
    }

    /// The event's x on the screen: the grip moves under the pointer as the column resizes.
    private static func screenX(_ event: NSEvent) -> CGFloat {
        guard let window = event.window else { return event.locationInWindow.x }
        return window.convertPoint(toScreen: event.locationInWindow).x
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
