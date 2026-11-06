import AppKit
import SwiftUI

/// v0.18 §4.2 (ruling 39): Portico draws its own tooltip, centred under its
/// control (screen AR7), where macOS put it at the pointer. It shows after
/// 0.8 s of hover, hides on hover end, on any click and when the window
/// stops being key, stays 8 pt inside the window, flips above the control
/// near the window's bottom, and still gives VoiceOver the text as a hint.
///
/// This is the only file that may use SwiftUI's `.help(`: the menu fallback
/// below, where a hover panel cannot attach (an `NSMenu` item).
enum Tip {
    static let delay: TimeInterval = 0.8
    /// The gap between the control's edge and the tip.
    static let gap: CGFloat = 6
    /// How far inside the window's content the tip stays.
    static let margin: CGFloat = 8
    /// A long tip wraps at this width (text, before padding).
    static let maxTextWidth: CGFloat = 320

    // AR7's v0.18 tooltip node (`rm4j7`): one style in light and dark.
    static let fillHex = "#2B2B2E"
    static let textHex = "#E6E6E8"
    static let strokeHex = "#FFFFFF1F"
    static let shadowHex = "#00000066"
    static let fontSize: CGFloat = 11.5
    static let cornerRadius: CGFloat = 5
    static let padding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
    static let shadowRadius: CGFloat = 10
    static let shadowY: CGFloat = 3
    /// Room around the bubble in the panel for its shadow.
    static let shadowRoom: CGFloat = 14
}

/// Where a tip goes, in AppKit coordinates (y grows upward), the one place
/// the flip is handled: "below" is a smaller y.
enum TipPlacement {
    /// `control`, `window` and `screen` are all in screen coordinates (the
    /// window's content and the screen's visible frame). The tip stays
    /// inside both; on a screen whose origin is not (0, 0), such as a second
    /// display, nothing here assumes it is.
    static func frame(for control: CGRect, size: CGSize, in window: CGRect, screen: CGRect? = nil) -> CGRect {
        var area = window
        if let screen, !screen.isEmpty {
            let shared = window.intersection(screen)
            if !shared.isNull, !shared.isEmpty { area = shared }
        }
        var x = control.midX - size.width / 2
        x = min(x, area.maxX - Tip.margin - size.width)
        x = max(x, area.minX + Tip.margin)
        var y = control.minY - Tip.gap - size.height
        if y < area.minY + Tip.margin {
            // Near the window's (or screen's) bottom: above the control.
            y = control.maxY + Tip.gap
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The panel's frame for a bubble: the bubble plus room for its shadow.
    /// The panel never takes another size (see `TipPanel.init`).
    static func panelFrame(bubble: CGRect) -> CGRect {
        bubble.insetBy(dx: -Tip.shadowRoom, dy: -Tip.shadowRoom)
    }
}

/// Where a `.tip` is attached: a view (the hover panel) or an item in a menu
/// (`contextMenu`, `Menu` content), where only the native help can show.
enum TipHost {
    case menu
}

extension View {
    /// Portico's tooltip. Also sets the VoiceOver hint to `text`.
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text, setsHint: true))
    }

    /// A tip on a view that sets its own `.accessibilityHint`, which wins.
    func tip(_ text: String, keepsOwnHint: Bool) -> some View {
        modifier(TipModifier(text: text, setsHint: !keepsOwnHint))
    }

    /// A tip on a menu item: the system's own help (a hover panel cannot
    /// attach to an `NSMenu` item).
    func tip(_ text: String, in host: TipHost) -> some View {
        help(text)
    }
}

struct TipModifier: ViewModifier {
    let text: String
    /// The VoiceOver hint this applies: the text, unless the view sets its own.
    let hint: String?
    @Environment(\.textScale) private var scale

    /// Fixed for a call site, so the branch below never changes the view's
    /// identity (only the text changes as the view's state does).
    private let setsHint: Bool

    init(text: String, setsHint: Bool) {
        self.text = text
        self.setsHint = setsHint
        hint = setsHint && !text.isEmpty ? text : nil
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if setsHint {
            // An empty text gives an empty hint, which VoiceOver does not read.
            content
                .background(TipAnchor(text: text, scale: scale))
                .accessibilityHint(text)
        } else {
            content
                .background(TipAnchor(text: text, scale: scale))
        }
    }
}

/// The view's own geometry and hover, as an AppKit view behind it: its
/// tracking area sees the pointer even over AppKit-backed controls (menus,
/// text fields), and it never takes a click.
private struct TipAnchor: NSViewRepresentable {
    let text: String
    let scale: CGFloat

    func makeNSView(context: Context) -> TipAnchorView {
        let view = TipAnchorView()
        view.text = text
        view.scale = scale
        return view
    }

    func updateNSView(_ view: TipAnchorView, context: Context) {
        view.text = text
        view.scale = scale
    }

    static func dismantleNSView(_ view: TipAnchorView, coordinator: ()) {
        view.hide()
    }
}

final class TipAnchorView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            if text.isEmpty { hide() } else { panel?.update(text: text, scale: scale); place() }
        }
    }
    var scale: CGFloat = 1

    private var timer: Timer?
    private var panel: TipPanel?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var deactivateObserver: NSObjectProtocol?
    private var hovering = false
    /// A click hides the tip until the pointer leaves and comes back.
    private var suppressed = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hide() }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        suppressed = false
        guard !text.isEmpty, window != nil else { return }
        startWatching()
        timer?.invalidate()
        let timer = Timer(timeInterval: Tip.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        hide()
    }

    private func show() {
        timer = nil
        guard hovering, !suppressed, !text.isEmpty, let window, window.isVisible else { return }
        let panel = self.panel ?? TipPanel()
        self.panel = panel
        panel.update(text: text, scale: scale)
        place()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    /// Puts the panel under the control, in screen coordinates.
    private func place() {
        guard let panel, let window else { return }
        let control = window.convertToScreen(convert(bounds, to: nil))
        panel.place(bubble: TipPlacement.frame(
            for: control, size: panel.bubbleSize, in: Self.bounds(of: window),
            screen: (window.screen ?? NSScreen.main)?.visibleFrame))
    }

    /// The window's content in screen coordinates. A popover's window is
    /// small, so its tips may also use the window it hangs from.
    private static func bounds(of window: NSWindow) -> CGRect {
        let own = window.convertToScreen(window.contentLayoutRect)
        guard let parent = window.parent else { return own }
        return own.union(parent.convertToScreen(parent.contentLayoutRect))
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if !hovering { stopWatching() }
    }

    /// While the pointer is over the control: any click, or the window
    /// losing key, hides the tip.
    private func startWatching() {
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.clicked()
                return event
            }
        }
        if resignObserver == nil, let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked() }
            }
        }
        if deactivateObserver == nil {
            deactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked() }
            }
        }
    }

    private func clicked() {
        suppressed = true
        hide()
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
    }
}

extension Theme {
    /// AR7's tooltip: the same dark bubble in light and dark appearance.
    static let tipFill = dynamic(Tip.fillHex, Tip.fillHex)
    static let tipText = dynamic(Tip.textHex, Tip.textHex)
    static let tipStroke = dynamic(Tip.strokeHex, Tip.strokeHex)
    static let tipShadow = dynamic(Tip.shadowHex, Tip.shadowHex)
}

/// The tip's window: borderless, non-activating, never key, and the mouse
/// passes through it.
final class TipPanel: NSPanel {
    private(set) var tipText = ""
    private(set) var bubbleSize = CGSize.zero
    private let host = NSHostingView(rootView: TipBubble(text: "", scale: 1))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // Hidden by its anchor when the app resigns active, so it never
        // comes back on its own when the app is activated again.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        // v0.22 item 7: the panel's frame is `place(bubble:)`'s alone. By
        // default a hosting view that is a window's content constrains the
        // window to its SwiftUI content's minimum and maximum sizes; a
        // wrapping `Text`'s minimum is very tall and narrow, so once the
        // panel was on screen AppKit resized it to that (keeping its top
        // edge), and the bubble, centred in it, landed far below and left of
        // its control (a long path: near the window's bottom).
        host.sizingOptions = []
        // v0.22.1: and the hosting view is not the window's content, only
        // inside it. In the running app (the SwiftUI App lifecycle, never in
        // XCTest) a hosting view that is a window's content view also gets
        // SwiftUI's window-size bridge, whatever its sizingOptions: on every
        // layout it fits the window to the content's minimum and maximum
        // sizes. A wrapping `Text`'s minimum depends on its width, so that
        // fit and `place(bubble:)` never agreed: tips showed resized, and
        // some panels never settled, each pass asking for another until
        // AppKit raised (more Update Constraints passes than views) and the
        // app quit, widening the viewer being the usual way to meet one.
        // A plain view as the content has no bridge; the hosting view just
        // fills it.
        let content = NSView(frame: .zero)
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The bubble's frame in screen coordinates (the panel adds room for the
    /// shadow around it).
    var bubbleFrame: CGRect { frame.insetBy(dx: Tip.shadowRoom, dy: Tip.shadowRoom) }

    func update(text: String, scale: CGFloat) {
        tipText = text
        host.rootView = TipBubble(text: text, scale: scale)
        let controller = NSHostingController(rootView: TipBubble(text: text, scale: scale))
        let fitted = controller.sizeThatFits(in: CGSize(
            width: Tip.maxTextWidth * scale + Tip.padding.leading + Tip.padding.trailing + 2 * Tip.shadowRoom,
            height: .greatestFiniteMagnitude))
        bubbleSize = CGSize(
            width: ceil(fitted.width) - 2 * Tip.shadowRoom, height: ceil(fitted.height) - 2 * Tip.shadowRoom)
    }

    func place(bubble: CGRect) {
        setFrame(TipPlacement.panelFrame(bubble: bubble), display: true)
    }
}

/// AR7's bubble: dark fill, light text, a hairline and a soft shadow.
struct TipBubble: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        Text(text)
            .scaledFont(Tip.fontSize)
            .foregroundStyle(Theme.tipText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Tip.padding)
            .background(
                RoundedRectangle(cornerRadius: Tip.cornerRadius, style: .continuous)
                    .fill(Theme.tipFill)
                    .shadow(color: Theme.tipShadow, radius: Tip.shadowRadius / 2, y: Tip.shadowY))
            .overlay(
                RoundedRectangle(cornerRadius: Tip.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.tipStroke, lineWidth: 1))
            .padding(Tip.shadowRoom)
            .environment(\.textScale, scale)
    }
}
