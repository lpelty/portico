import AppKit
import QuartzCore
import WebKit

// MARK: - AgentPointer

/// The agent's pointer over the viewer's page (v0.18 §4.1, plan ruling 38,
/// Pen AR5–AR6). Before the agent clicks, and before it types into a
/// field, the pointer glides to the target and, for a click, pulses one
/// ring out from its tip; the action lands once the glide is over. It
/// fades `fadeAfter` after the last step and comes back on the next.
///
/// It is a view of its own laid over the `WKWebView` (the parent the
/// target's outline ring uses), one per web view. It is drawn only: it
/// takes no clicks, isn't read by VoiceOver, and the person's own mouse
/// never moves.
@MainActor
final class AgentPointer: NSView {
    enum Kind { case click, type }

    /// The glide, about a third of a second (AR6 "1 · Glides there").
    static let glide: TimeInterval = 0.33
    /// After a second and a half with no step, it fades (AR6 "4 · Fades").
    static let fadeAfter: TimeInterval = 1.5
    /// The click's one ring out from the tip (AR6 "2 · Clicks").
    static let pulse: TimeInterval = 0.35
    /// Under Reduce Motion: a fade only, no glide and no ring scale.
    static let calmFade: TimeInterval = 0.15
    /// How long the idle fade itself takes.
    static let fadeOut: TimeInterval = 0.3
    /// The glide's curve: its control point sits this share of the
    /// distance off the straight line.
    static let curve: CGFloat = 0.12
    /// A type rests this far in from the field's left edge.
    static let typeInset: CGFloat = 8

    // The glyph, copied from AR6's "Pointer" path node: drawn from its tip
    // at (0, 0), y down, in the node's own units (Pen draws a path's
    // geometry in a 0 0 width height view box, unscaled).
    static let geometry = "M0 0l0 18 4.6-4.4 3.2 7.2 3.2-1.4-3.1-7 6.1 0z"
    static let strokeWidth: CGFloat = 1.5
    static let shadowOpacity: Float = Float(0x59) / 255
    static let shadowOffsetDown: CGFloat = 2
    static let shadowBlur: CGFloat = 5
    // AR6's two "Click ring" ellipses, centred on the tip: the ring at its
    // start (30 pt, 2 pt stroke, 90 %) and on its way out (48 pt, 1.5 pt, 35 %).
    static let ringStart: (diameter: CGFloat, stroke: CGFloat, opacity: Float) = (30, 2, 0.9)
    static let ringOut: (diameter: CGFloat, stroke: CGFloat, opacity: Float) = (48, 1.5, 0.35)

    /// The view is a square around the tip, big enough for the glyph, its
    /// shadow and the ring at its widest.
    private static let half: CGFloat = 32

    /// The tip, in the web view's coordinates; `nil` until it first moves.
    private(set) var tipPosition: CGPoint?
    /// When the last glide ended (tests: the action lands after it).
    private(set) var lastArrival: Date?
    /// The brand's accent, the glyph's fill and the ring's stroke.
    var accent: NSColor = NSColor(Theme.accent) {
        didSet { applyColours() }
    }

    private let reduceMotion: () -> Bool
    private let glyph = CAShapeLayer()
    /// Bumped by every step, so an older fade or glide stands down.
    private var step = 0

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        super.init(frame: CGRect(x: 0, y: 0, width: Self.half * 2, height: Self.half * 2))
        wantsLayer = true
        layer?.masksToBounds = false
        glyph.path = Self.glyphPath()
        glyph.lineWidth = Self.strokeWidth
        glyph.lineJoin = .round
        glyph.position = CGPoint(x: Self.half, y: Self.half)
        glyph.shadowOpacity = Self.shadowOpacity
        glyph.shadowColor = NSColor.black.cgColor
        glyph.shadowOffset = CGSize(width: 0, height: Self.shadowOffsetDown)
        glyph.shadowRadius = Self.shadowBlur / 2
        layer?.addSublayer(glyph)
        applyColours()
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The glyph and ring are laid out y down, from the tip.
    override var isFlipped: Bool { true }
    /// Drawn only: clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    /// Where the tip lands for `rect` (in the web view's coordinates): a
    /// click at the box's centre; a type 8 pt in from the field's left
    /// edge, vertically centred.
    func tip(for rect: CGRect, kind: Kind) -> CGPoint {
        switch kind {
        case .click: CGPoint(x: rect.midX, y: rect.midY)
        case .type: CGPoint(x: rect.minX + Self.typeInset, y: rect.midY)
        }
    }

    /// Glide to `rect` in `view` (and pulse, for a click), returning once
    /// the tip has arrived. The first time, it comes from the view's
    /// bottom centre. Under Reduce Motion it appears at the target with a
    /// short fade, no glide.
    func move(to rect: CGRect, in view: WKWebView, kind: Kind) async {
        step += 1
        let mine = step
        if superview !== view {
            // Another view's coordinates mean nothing here: start afresh.
            tipPosition = nil
        }
        if superview !== view || view.subviews.last !== self {
            // On top of anything added to the page since (marks, the outline ring).
            view.addSubview(self, positioned: .above, relativeTo: nil)
        }
        let target = tip(for: rect, kind: kind)
        let calm = reduceMotion()
        // From where it last was (faded or not); the first time, from the
        // view's bottom centre.
        let start = tipPosition ?? CGPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
        if alphaValue < 1 {
            fade(to: 1, over: Self.calmFade)
        }
        if calm {
            place(at: target)
        } else {
            place(at: start)
            await glide(from: start, to: target, step: mine)
        }
        guard step == mine else { return }
        place(at: target)
        lastArrival = Date()
        if kind == .click { pulseRing(calm: calm) }
        scheduleFade(step: mine)
    }

    // MARK: drawing

    private func place(at tip: CGPoint) {
        tipPosition = tip
        setFrameOrigin(CGPoint(x: tip.x - Self.half, y: tip.y - Self.half))
    }

    /// A quadratic Bézier from `from` to `to`, its control point 12 % of
    /// the distance off the line, eased in and out over `glide`.
    private func glide(from: CGPoint, to: CGPoint, step mine: Int) async {
        let dx = to.x - from.x, dy = to.y - from.y
        let control = CGPoint(x: (from.x + to.x) / 2 - dy * Self.curve, y: (from.y + to.y) / 2 + dx * Self.curve)
        let clock = ContinuousClock()
        let began = clock.now
        let total = Duration.milliseconds(Int(Self.glide * 1000))
        while true {
            let elapsed = clock.now - began
            let t = CGFloat(min(1, elapsed / total))
            let s = t * t * (3 - 2 * t)  // ease in and out
            let u = 1 - s
            let a = u * u, b = 2 * u * s, c = s * s
            place(at: CGPoint(
                x: a * from.x + b * control.x + c * to.x,
                y: a * from.y + b * control.y + c * to.y))
            if t >= 1 || step != mine { return }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// One ring out from the tip as the click lands. Under Reduce Motion it
    /// keeps its size and only fades.
    private func pulseRing(calm: Bool) {
        guard let layer else { return }
        let ring = CAShapeLayer()
        let start = Self.ringStart, out = Self.ringOut
        let circle = { (d: CGFloat) in CGPath(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d), transform: nil) }
        ring.path = circle(start.diameter)
        ring.position = CGPoint(x: Self.half, y: Self.half)
        ring.fillColor = nil
        ring.lineWidth = start.stroke
        ring.opacity = 0
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = self.accent.cgColor }
        layer.insertSublayer(ring, below: glyph)

        let duration = calm ? Self.calmFade : Self.pulse
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = calm ? [start.opacity, 0] : [start.opacity, out.opacity, 0]
        fade.keyTimes = calm ? [0, 1] : [0, 0.8, 1]
        var animations: [CAAnimation] = [fade]
        if !calm {
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = circle(start.diameter)
            grow.toValue = circle(out.diameter + (out.diameter - start.diameter) / 4)
            let thin = CABasicAnimation(keyPath: "lineWidth")
            thin.fromValue = start.stroke
            thin.toValue = out.stroke
            animations += [grow, thin]
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }

    /// Fades `fadeAfter` after this step, unless another step comes first.
    private func scheduleFade(step mine: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.fadeAfter * 1000)))
            guard let self, self.step == mine else { return }
            self.fade(to: 0, over: Self.fadeOut)
        }
    }

    private func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = duration
        animator().alphaValue = alpha
        NSAnimationContext.endGrouping()
    }

    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyph.fillColor = accent.cgColor
            glyph.strokeColor = NSColor.white.cgColor
        }
    }

    /// AR6's path: from the tip, down the left edge, the notch, the tail
    /// and back across to the tip.
    private static func glyphPath() -> CGPath {
        let path = CGMutablePath()
        var at = CGPoint.zero
        path.move(to: at)
        for (dx, dy) in [(0, 18), (4.6, -4.4), (3.2, 7.2), (3.2, -1.4), (-3.1, -7), (6.1, 0)] as [(CGFloat, CGFloat)] {
            at = CGPoint(x: at.x + dx, y: at.y + dy)
            path.addLine(to: at)
        }
        path.closeSubpath()
        return path
    }
}
