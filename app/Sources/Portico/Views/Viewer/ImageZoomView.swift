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
        // The document point at the middle of the view, before the resize.
        let centre = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        super.setFrameSize(newSize)
        MainActor.assumeIsolated { controller?.viewportChanged(keeping: centre) }
    }
}

/// The image at its own size. Double-click toggles Fit and 100%; a drag
/// pans (hand cursor) when the image is larger than the view.
final class ZoomImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    weak var controller: ImageZoomController?
    private var lastDrag: NSPoint?
    private var pushedHand = false

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
        if overflows, !pushedHand { NSCursor.closedHand.push(); pushedHand = true }
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
        if pushedHand { NSCursor.pop(); pushedHand = false }
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
    func viewportChanged(keeping centre: NSPoint? = nil) {
        guard imageSize.width > 0 else { return }
        if fitting {
            applyFit()
        } else {
            scroll.minMagnification = min(Zoom.minimum, fitScale, scroll.magnification)
            if let centre { recentre(on: centre) }
        }
    }

    /// The clip origin that puts document point `centre` in the middle of a clip of `size`.
    static func origin(centre: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
    }

    private func recentre(on centre: NSPoint) {
        let clip = scroll.contentView
        let wanted = NSRect(origin: Self.origin(centre: centre, size: clip.bounds.size), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func magnified() {
        let value = scroll.magnification
        if abs(value - fitScale) <= fitScale * 0.005 {
            zoomToFit()
            return
        }
        fitting = false
        memory.set(value, for: path)
        onChange?(value)
    }

    private func choose(_ value: CGFloat) {
        fitting = false
        memory.set(value, for: path)
        apply(value)
    }

    func zoomIn() { choose(Zoom.next(after: scale)) }
    func zoomOut() { choose(Zoom.out(from: scale)) }
    func zoomActual() { choose(1) }

    func zoomToFit() {
        fitting = true
        memory.set(nil, for: path)
        applyFit()
    }

    /// Where a double-click goes: nil is Fit; at Fit, 100%, or 200% when
    /// Fit already is 100% (a small image).
    static func toggleTarget(atFit: Bool, fit: CGFloat) -> CGFloat? {
        guard atFit else { return nil }
        return fit >= 0.995 ? 2 : 1
    }

    func toggleFitAndActual() {
        let atFit = fitting || abs(scale - fitScale) < 0.005
        if let target = Self.toggleTarget(atFit: atFit, fit: fitScale) { choose(target) } else { zoomToFit() }
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
        Self.assemble(file: file, image: image, scale: $scale, box: controllerBox,
                      coordinator: context.coordinator, slot: context.environment.viewerSlot)
    }

    /// Builds the pane. The change callback holds only the binding: the
    /// controller must not be reachable from anything it holds.
    static func assemble(file: URL, image: NSImage, scale binding: Binding<CGFloat>, box: ControllerBox,
                         coordinator: Coordinator, slot: ViewerAgent.Slot?) -> ZoomScrollView {
        let controller = ImageZoomController()
        controller.slot = slot
        controller.onChange = { value in DispatchQueue.main.async { binding.wrappedValue = value } }
        controller.load(image, path: file.path)
        box.controller = controller
        coordinator.box = box
        coordinator.controller = controller
        ZoomHub.shared.register(controller, slot: slot)
        return controller.scroll
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        guard let controller = context.coordinator.controller, controller.path != file.path else { return }
        controller.load(image, path: file.path)
    }

    static func dismantleNSView(_ view: ZoomScrollView, coordinator: Coordinator) {
        MainActor.assumeIsolated { teardown(coordinator) }
    }

    @MainActor static func teardown(_ coordinator: Coordinator) {
        if let controller = coordinator.controller {
            ZoomHub.shared.unregister(controller, slot: controller.slot)
            controller.onChange = nil
        }
        coordinator.box?.controller = nil
        coordinator.controller = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var controller: ImageZoomController?
        var box: ControllerBox?
    }
}
