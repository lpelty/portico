import AppKit
import SwiftUI

/// The person's own input to the transcript, by its source (v0.15 task 2b
/// fix round 2). The scroll view's phase says when a person scrolls by
/// trackpad, mouse (a plain wheel too, found hosted) or scroller; the keys (Page Up and Down, Home,
/// End, the arrows, Space) and VoiceOver's page scroll report none, so at
/// the bottom their scroll read as the layout's and snapped back to the
/// end. An app event monitor marks them, and so does the view when
/// VoiceOver's cursor moves to another row (fix round 3); the mark counts
/// for the readings within `span` after it. Fix round 4: the mark carries
/// the input's direction, and only readings moving that way are the
/// person's (`ConversationScrollMemory.observe`); it is no longer spent by
/// the first one.
///
/// Found hosted, on v0.14.0 alike: the first scroll after the app's
/// `scrollTo("bottom")` is put back once by SwiftUI (it re-applies that
/// target on its next update), whatever the input; the next one holds.
/// v0.16 §5: gone with the move to `ScrollPosition`'s edge target. Every
/// mark here stays: the spike found `isPositionedByUser` false for all of
/// these inputs (`ConversationScroll.swift`).
@MainActor
final class TranscriptPersonInput {
    /// How long one input counts for the readings that follow it.
    static let span: TimeInterval = 0.3
    /// Page Up, Page Down, Home, End, Up, Down, Space.
    static let scrollKeys: Set<UInt16> = [116, 121, 115, 119, 126, 125, 49]
    /// The keys toward earlier messages (Space too, with Shift).
    static let upKeys: Set<UInt16> = [116, 115, 126]
    typealias Direction = ConversationScrollMemory.Direction
    /// The transcript's scroll view, found by `TranscriptScrollViewProbe`.
    weak var scrollView: NSScrollView?
    /// The clock (a test sets its own).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var last: (time: TimeInterval, direction: Direction)?
    private var monitor: Any?
    /// v0.26.4 (D5): every wheel and key event the transcript takes, while a
    /// recording runs (nil otherwise).
    var onEvent: ((NSEvent) -> Void)?

    /// Whether the person's input came within the last `span`.
    var isRecent: Bool { recent != nil }

    /// The direction of the person's input within the last `span`, if any.
    var recent: Direction? {
        guard let last, now() - last.time < Self.span else { return nil }
        return last.direction
    }

    /// The person scrolled the transcript, `direction` (fix round 4; the
    /// round 3 `consume()` is gone: SwiftUI putting its own offset back
    /// after a wheel moves against the wheel, so the direction tells it
    /// apart, and an animated key scroll's later frames stay the person's).
    func mark(direction: Direction) {
        last = (now(), direction)
    }

    func install() {
        guard monitor == nil, NSApp != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let direction = self.direction(of: event) {
                    self.mark(direction: direction)
                    self.onEvent?(event)
                }
            }
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether an event scrolls the transcript.
    func takes(_ event: NSEvent) -> Bool { direction(of: event) != nil }

    /// Which way an event scrolls the transcript, if it does: a wheel over
    /// it (any phase; a positive delta is toward the top, as `page(toward:)`
    /// sends it), or a scroll key while the focus is inside it (its rows are
    /// selectable, so the keys reach it).
    func direction(of event: NSEvent) -> Direction? {
        guard let scroll = scrollView, let window = scroll.window else { return nil }
        switch event.type {
        case .scrollWheel:
            let point: NSPoint
            if let eventWindow = event.window {
                guard eventWindow === window else { return nil }
                point = event.locationInWindow
            } else {
                // Not bound to a window: the location is on the screen.
                point = window.convertPoint(fromScreen: event.locationInWindow)
            }
            guard scroll.bounds.contains(scroll.convert(point, from: nil)) else { return nil }
            let delta = event.scrollingDeltaY
            return delta > 0 ? .up : delta < 0 ? .down : .either
        case .keyDown:
            guard Self.scrollKeys.contains(event.keyCode), event.window === window,
                  let focus = window.firstResponder as? NSView, focus.isDescendant(of: scroll) else { return nil }
            if event.keyCode == 49 { return event.modifierFlags.contains(.shift) ? .up : .down }
            return Self.upKeys.contains(event.keyCode) ? .up : .down
        default:
            return nil
        }
    }

    /// VoiceOver's page scroll: a page toward `edge`, marked as the
    /// person's, as a wheel does (a pixel wheel event handed to the scroll
    /// view: SwiftUI follows it; a move of its clip view it puts back).
    func page(toward edge: Edge) {
        guard edge == .top || edge == .bottom, let scroll = scrollView, let window = scroll.window else { return }
        mark(direction: edge == .top ? .up : .down)
        let clip = scroll.contentView
        let page = max(clip.bounds.height - scroll.verticalPageScroll, clip.bounds.height / 2)
        // A wheel's delta is up the content: positive scrolls toward the top.
        let delta = Int32(clamping: Int((edge == .top ? page : -page).rounded()))
        guard let wheel = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        else { return }
        // Over the transcript (CG's screen origin is the main screen's top left).
        let point = window.convertPoint(toScreen: scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil))
        wheel.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        guard let event = NSEvent(cgEvent: wheel) else { return }
        scroll.scrollWheel(with: event)
    }
}

/// A view inside the transcript that hands its scroll view to
/// `TranscriptPersonInput` (v0.15 task 2b fix round 2).
struct TranscriptScrollViewProbe: NSViewRepresentable {
    let input: TranscriptPersonInput

    final class Probe: NSView {
        weak var input: TranscriptPersonInput?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            input?.scrollView = enclosingScrollView
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.input = input
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.input = input
        if let scroll = probe.enclosingScrollView { input.scrollView = scroll }
    }
}

/// A transcript row that marks the person's input when VoiceOver's cursor
/// lands on it (v0.15 task 2b fix round 3): the cursor scrolls the row into
/// view, with no scroll phase and no event. Each row keeps its own focus
/// state: read in the transcript's body, it set off a loop of scrolls
/// (found hosted, after a send).
struct MarksVoiceOverFocus: ViewModifier {
    let input: TranscriptPersonInput
    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityFocused($focused)
            .onChange(of: focused) { _, now in
                if now { input.mark(direction: .either) }
            }
    }
}
