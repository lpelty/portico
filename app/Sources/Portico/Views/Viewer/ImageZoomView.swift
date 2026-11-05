import AppKit
import SwiftUI

/// Keeps a document smaller than the view in the middle of it.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = document.frame.minX - (rect.width - document.frame.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = document.frame.minY - (rect.height - document.frame.height) / 2
        }
        return rect
    }
}

/// The scroll view; tells its controller when its size changes.
final class ZoomScrollView: NSScrollView {
    weak var controller: ImageZoomController?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        MainActor.assumeIsolated { controller?.viewportChanged() }
    }
}

/// The image at its own size. Double-click toggles Fit and 100%; a drag
/// pans (hand cursor) when the image is larger than the view.
final class ZoomImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    weak var controller: ImageZoomController?
    private var lastDrag: NSPoint?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private var overflows: Bool {
        guard let scroll = enclosingScrollView else { return false }
        let visible = scroll.contentView.bounds.size
        return frame.width > visible.width + 0.5 || frame.height > visible.height + 0.5
    }

    override func resetCursorRects() {
        if overflows { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            MainActor.assumeIsolated { controller?.toggleFitAndActual() }
            return
        }
        lastDrag = event.locationInWindow
        if overflows { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard overflows, let last = lastDrag, let scroll = enclosingScrollView else { return }
        let now = event.locationInWindow
        let clip = scroll.contentView
        let scale = max(scroll.magnification, 0.01)
        var origin = clip.bounds.origin
        origin.x -= (now.x - last.x) / scale
        // The view is flipped: window y grows upward, bounds y downward.
        origin.y += (now.y - last.y) / scale
        lastDrag = now
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if lastDrag != nil, overflows { NSCursor.pop() }
        lastDrag = nil
    }
}

/// Owns an image pane's zoom: Fit by default (never past 100%), the steps,
/// pinch, and the memory of where a file was left.
@MainActor
final class ImageZoomController: NSObject, ZoomTarget {
    let scroll: ZoomScrollView
    private let imageView = ZoomImageView()
    private(set) var path = ""
    private(set) var fitting = true
    private var imageSize = CGSize.zero
    var slot: ViewerAgent.Slot?
    var onChange: ((CGFloat) -> Void)?
    var memory: ZoomMemory = .shared
    /// The margin Fit leaves around the image.
    static let margin: CGFloat = 12

    override init() {
        scroll = ZoomScrollView()
        super.init()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = Zoom.minimum
        scroll.maxMagnification = Zoom.maximum
        scroll.documentView = imageView
        scroll.controller = self
        imageView.controller = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var scale: CGFloat { scroll.magnification }

    /// Show `image` from `path`, at the remembered scale or at Fit.
    func load(_ image: NSImage, path: String) {
        self.path = path
        imageSize = image.size
        imageView.image = image
        imageView.setFrameSize(image.size)
        if let remembered = memory.scale(for: path) {
            fitting = false
            apply(remembered)
        } else {
            fitting = true
            applyFit()
        }
    }

    private var fitScale: CGFloat {
        let box = scroll.contentSize
        let inset = Self.margin * 2
        return Zoom.fit(image: imageSize,
                        in: CGSize(width: max(box.width - inset, 1), height: max(box.height - inset, 1)))
    }

    private func apply(_ value: CGFloat) {
        scroll.minMagnification = min(Zoom.minimum, fitScale, value)
        let clamped = min(max(value, scroll.minMagnification), Zoom.maximum)
        let clip = scroll.contentView
        let centre = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(clamped, centeredAt: centre)
        imageView.window?.invalidateCursorRects(for: imageView)
        onChange?(clamped)
    }

    private func applyFit() {
        guard imageSize.width > 0 else { return }
        apply(fitScale)
    }

    /// The scroll view's size changed: Fit follows it, a chosen scale stays.
    func viewportChanged() {
        guard imageSize.width > 0 else { return }
        if fitting { applyFit() } else { scroll.minMagnification = min(Zoom.minimum, fitScale, scroll.magnification) }
    }

    @objc private func magnified() {
        fitting = false
        memory.set(scroll.magnification, for: path)
        onChange?(scroll.magnification)
    }

    private func choose(_ value: CGFloat) {
        fitting = false
        memory.set(value, for: path)
        apply(value)
    }

    func zoomIn() { choose(Zoom.next(after: scale)) }
    func zoomOut() { choose(Zoom.previous(before: scale)) }
    func zoomActual() { choose(1) }

    func zoomToFit() {
        fitting = true
        memory.set(nil, for: path)
        applyFit()
    }

    func toggleFitAndActual() {
        if fitting || abs(scale - fitScale) < 0.005 { zoomActual() } else { zoomToFit() }
    }
}

/// An image in a magnifying scroll view: fit by default, never enlarged past
/// 100% until asked; pinch, keys and the control zoom it.
struct ImageZoomPane: NSViewRepresentable {
    let file: URL
    let image: NSImage
    @Binding var scale: CGFloat
    let controllerBox: ControllerBox

    /// Lets the SwiftUI side reach the controller for the control's buttons.
    @MainActor final class ControllerBox { var controller: ImageZoomController? }

    func makeNSView(context: Context) -> ZoomScrollView {
        let controller = ImageZoomController()
        controller.slot = context.environment.viewerSlot
        controller.onChange = { value in DispatchQueue.main.async { scale = value } }
        controller.load(image, path: file.path)
        controllerBox.controller = controller
        context.coordinator.controller = controller
        ZoomHub.shared.register(controller, slot: controller.slot)
        return controller.scroll
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        guard let controller = context.coordinator.controller, controller.path != file.path else { return }
        controller.load(image, path: file.path)
    }

    static func dismantleNSView(_ view: ZoomScrollView, coordinator: Coordinator) {
        if let controller = coordinator.controller {
            MainActor.assumeIsolated { ZoomHub.shared.unregister(controller, slot: controller.slot) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var controller: ImageZoomController?
    }
}
