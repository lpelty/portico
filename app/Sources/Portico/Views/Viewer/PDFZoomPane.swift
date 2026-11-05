import AppKit
import PDFKit
import SwiftUI

/// Owns a PDF pane's zoom: Fit is PDFKit's auto-scaling, Actual is 100%,
/// the steps go through `Zoom`; the page shown is read from PDFKit.
@MainActor
final class PDFZoomController: NSObject, ZoomTarget {
    let view: PDFView
    private(set) var path = ""
    var slot: ViewerAgent.Slot?
    var memory: ZoomMemory = .shared
    /// The scale and the page label, after a change.
    var onChange: ((CGFloat, String) -> Void)?

    override init() {
        view = PDFView()
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.minScaleFactor = Zoom.minimum
        view.maxScaleFactor = Zoom.maximum
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// "Page 3 of 12".
    static func pageLabel(page: Int, of count: Int) -> String { "Page \(page) of \(count)" }

    var pageLabel: String {
        guard let document = view.document, document.pageCount > 0, let page = view.currentPage else { return "" }
        return Self.pageLabel(page: document.index(for: page) + 1, of: document.pageCount)
    }

    var scale: CGFloat { view.scaleFactor }
    var fitting: Bool { view.autoScales }

    func load(url: URL) {
        path = url.path
        view.document = PDFDocument(url: url)
        if let remembered = memory.scale(for: path) {
            view.autoScales = false
            view.scaleFactor = remembered
        } else {
            view.autoScales = true
        }
        report()
    }

    private func report() { onChange?(view.scaleFactor, pageLabel) }

    @objc private func scaleChanged() {
        // A pinch or a menu step turned auto-scaling off: remember where it stopped.
        memory.set(view.autoScales ? nil : view.scaleFactor, for: path)
        report()
    }

    @objc private func pageChanged() { report() }

    private func choose(_ value: CGFloat) {
        view.autoScales = false
        view.scaleFactor = min(max(value, Zoom.minimum), Zoom.maximum)
        memory.set(view.scaleFactor, for: path)
        report()
    }

    func zoomIn() { choose(Zoom.next(after: scale)) }
    func zoomOut() { choose(Zoom.out(from: scale)) }
    func zoomActual() { choose(1) }

    func zoomToFit() {
        view.autoScales = true
        memory.set(nil, for: path)
        report()
    }
}

/// A PDF in PDFKit's view, continuous pages, fit to width until zoomed.
struct PDFZoomPane: NSViewRepresentable {
    let file: URL
    @Binding var scale: CGFloat
    @Binding var page: String
    let controllerBox: ControllerBox

    @MainActor final class ControllerBox { var controller: PDFZoomController? }

    @MainActor final class Coordinator {
        var controller: PDFZoomController?
        var box: ControllerBox?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = Self.assemble(file: file, scale: $scale, page: $page, box: controllerBox,
                                 coordinator: context.coordinator, slot: context.environment.viewerSlot)
        // The agent reads and scrolls the viewer's PDF (v0.12).
        context.environment.viewerAgent?.attachNative(view, file: file, slot: context.environment.viewerSlot)
        return view
    }

    /// The change callback holds only the bindings, never the controller.
    static func assemble(file: URL, scale scaleBinding: Binding<CGFloat>, page pageBinding: Binding<String>,
                         box: ControllerBox, coordinator: Coordinator, slot: ViewerAgent.Slot?) -> PDFView {
        let controller = PDFZoomController()
        controller.slot = slot
        controller.onChange = { value, label in
            DispatchQueue.main.async {
                scaleBinding.wrappedValue = value
                pageBinding.wrappedValue = label
            }
        }
        controller.load(url: file)
        box.controller = controller
        coordinator.box = box
        coordinator.controller = controller
        ZoomHub.shared.register(controller, slot: slot)
        return controller.view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let controller = context.coordinator.controller, controller.path != file.path else { return }
        controller.load(url: file)
        // The same view, another file: the agent reads the new one.
        context.environment.viewerAgent?.attachNative(view, file: file, slot: context.environment.viewerSlot)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
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
}
