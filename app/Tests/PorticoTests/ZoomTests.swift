import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Portico

@MainActor
final class ZoomTests: XCTestCase {
    func testStepsAndEnds() {
        XCTAssertEqual(Zoom.steps, [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8])
        XCTAssertEqual(Zoom.next(after: 1), 1.25)
        XCTAssertEqual(Zoom.next(after: 0.4), 0.5)
        XCTAssertEqual(Zoom.next(after: 8), 8)
        XCTAssertEqual(Zoom.previous(before: 1), 0.75)
        XCTAssertEqual(Zoom.previous(before: 0.6), 0.5)
        XCTAssertEqual(Zoom.previous(before: 0.25), 0.25)
        XCTAssertEqual(Zoom.previous(before: 0.1), 0.25)
    }

    func testFitNeverExceedsOne() {
        XCTAssertEqual(Zoom.fit(image: CGSize(width: 100, height: 50), in: CGSize(width: 1000, height: 1000)), 1)
        XCTAssertEqual(Zoom.fit(image: CGSize(width: 2000, height: 1000), in: CGSize(width: 1000, height: 1000)), 0.5)
        XCTAssertEqual(Zoom.fit(image: CGSize(width: 1000, height: 4000), in: CGSize(width: 1000, height: 1000)), 0.25)
        XCTAssertEqual(Zoom.fit(image: .zero, in: CGSize(width: 10, height: 10)), 1)
    }

    func testMemoryIsPerPathAndNewFileOpensAtFit() {
        let memory = ZoomMemory()
        XCTAssertNil(memory.scale(for: "/a.png"))
        memory.set(2, for: "/a.png")
        XCTAssertEqual(memory.scale(for: "/a.png"), 2)
        XCTAssertNil(memory.scale(for: "/b.png"))
        memory.set(nil, for: "/a.png")
        XCTAssertNil(memory.scale(for: "/a.png"))
    }

    func testControlPercentText() {
        XCTAssertEqual(ZoomControl.percentText(1), "100%")
        XCTAssertEqual(ZoomControl.percentText(0.67), "67%")
        XCTAssertEqual(ZoomControl.percentText(1.25), "125%")
    }

    func testMenuEnabledOnlyForImagesAndPDFs() {
        XCTAssertTrue(ZoomMenu.isEnabled(media: .image))
        XCTAssertTrue(ZoomMenu.isEnabled(media: .pdf))
        XCTAssertFalse(ZoomMenu.isEnabled(media: .markdown))
        XCTAssertFalse(ZoomMenu.isEnabled(media: .text))
        XCTAssertFalse(ZoomMenu.isEnabled(media: nil))
        XCTAssertFalse(ZoomMenu.isEnabled(media: .image, missing: true))
    }

    private func controller(image: CGSize) -> ImageZoomController {
        let c = ImageZoomController()
        c.memory = ZoomMemory()
        c.scroll.setFrameSize(NSSize(width: 500, height: 400))
        let img = NSImage(size: image)
        c.load(img, path: "/t.png")
        return c
    }

    func testSmallImageOpensAtOneHundredNotEnlarged() {
        let c = controller(image: CGSize(width: 100, height: 80))
        XCTAssertEqual(c.scale, 1, accuracy: 0.001)
        XCTAssertTrue(c.fitting)
    }

    func testLargeImageFitsAndFollowsResizeWhileFitting() {
        let c = controller(image: CGSize(width: 1000, height: 800))
        let first = c.scale
        XCTAssertLessThan(first, 1)
        c.scroll.setFrameSize(NSSize(width: 250, height: 200))
        XCTAssertLessThan(c.scale, first)
    }

    func testMagnificationSurvivesFrameResize() {
        let c = controller(image: CGSize(width: 1000, height: 800))
        c.zoomIn()
        let chosen = c.scale
        XCTAssertFalse(c.fitting)
        c.scroll.setFrameSize(NSSize(width: 900, height: 700))
        XCTAssertEqual(c.scale, chosen, accuracy: 0.001)
        c.scroll.setFrameSize(NSSize(width: 300, height: 300))
        XCTAssertEqual(c.scale, chosen, accuracy: 0.001)
    }

    func testToggleAndRemember() {
        let c = controller(image: CGSize(width: 1000, height: 800))
        c.toggleFitAndActual()
        XCTAssertEqual(c.scale, 1, accuracy: 0.001)
        XCTAssertEqual(c.memory.scale(for: "/t.png"), 1)
        c.toggleFitAndActual()
        XCTAssertTrue(c.fitting)
        XCTAssertNil(c.memory.scale(for: "/t.png"))
    }

    func testZoomOutNeverEnlargesAndInGoesToSmallestStepAbove() {
        XCTAssertEqual(Zoom.out(from: 0.1), 0.1)
        XCTAssertEqual(Zoom.out(from: 1), 0.75)
        XCTAssertEqual(Zoom.next(after: 0.1), 0.25)
        let c = controller(image: CGSize(width: 8000, height: 6000))
        let fit = c.scale
        XCTAssertLessThan(fit, 0.25)
        c.zoomOut()
        XCTAssertLessThanOrEqual(c.scale, fit + 0.001)
        c.zoomToFit()
        c.zoomIn()
        XCTAssertEqual(c.scale, 0.25, accuracy: 0.001)
    }

    func testDoubleClickTargets() {
        XCTAssertNil(ImageZoomController.toggleTarget(atFit: false, fit: 0.5))
        XCTAssertEqual(ImageZoomController.toggleTarget(atFit: true, fit: 0.5), 1)
        XCTAssertEqual(ImageZoomController.toggleTarget(atFit: true, fit: 1), 2)
        let c = controller(image: CGSize(width: 100, height: 80))
        c.toggleFitAndActual()
        XCTAssertEqual(c.scale, 2, accuracy: 0.001)
        c.toggleFitAndActual()
        XCTAssertTrue(c.fitting)
    }

    func testCentreMaths() {
        let o = ImageZoomController.origin(centre: NSPoint(x: 500, y: 400), size: NSSize(width: 200, height: 100))
        XCTAssertEqual(o, NSPoint(x: 400, y: 350))
    }

    func testResizeKeepsTheVisibleCentre() {
        let c = controller(image: CGSize(width: 4000, height: 3000))
        c.zoomActual()
        c.scroll.contentView.scroll(to: NSPoint(x: 1500, y: 1200))
        c.scroll.reflectScrolledClipView(c.scroll.contentView)
        let before = NSPoint(x: c.scroll.contentView.bounds.midX, y: c.scroll.contentView.bounds.midY)
        c.scroll.setFrameSize(NSSize(width: 800, height: 600))
        let after = NSPoint(x: c.scroll.contentView.bounds.midX, y: c.scroll.contentView.bounds.midY)
        XCTAssertEqual(after.x, before.x, accuracy: 1)
        XCTAssertEqual(after.y, before.y, accuracy: 1)
    }

    func testDismantledPaneReleasesItsController() {
        weak var weakController: ImageZoomController?
        autoreleasepool {
            var value: CGFloat = 1
            let binding = Binding(get: { value }, set: { value = $0 })
            let box = ImageZoomPane.ControllerBox()
            let coordinator = ImageZoomPane.Coordinator()
            _ = ImageZoomPane.assemble(file: URL(fileURLWithPath: "/leak.png"), image: NSImage(size: CGSize(width: 50, height: 50)),
                                       scale: binding, box: box, coordinator: coordinator, slot: .work)
            weakController = coordinator.controller
            XCTAssertNotNil(weakController)
            ImageZoomPane.teardown(coordinator)
        }
        XCTAssertNil(weakController)
    }

    // MARK: PDF (§3.3)

    private func pdfFile() throws -> URL {
        let doc = PDFDocument()
        for n in 0..<3 {
            let img = NSImage(size: NSSize(width: 200, height: 300))
            img.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill(); img.unlockFocus()
            doc.insert(PDFPage(image: img)!, at: n)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-\(UUID().uuidString).pdf")
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func pdfController() throws -> PDFZoomController {
        let c = PDFZoomController()
        c.memory = ZoomMemory()
        c.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        c.load(url: try pdfFile())
        return c
    }

    func testPDFPageLabelFormat() throws {
        XCTAssertEqual(PDFZoomController.pageLabel(page: 3, of: 12), "Page 3 of 12")
        XCTAssertEqual(try pdfController().pageLabel, "Page 1 of 3")
    }

    func testPDFScaleGoesThroughStepsAndFitSetsAutoScales() throws {
        let c = try pdfController()
        XCTAssertTrue(c.fitting)
        c.zoomActual()
        XCTAssertFalse(c.fitting)
        XCTAssertEqual(c.scale, 1, accuracy: 0.001)
        c.zoomIn()
        XCTAssertEqual(c.scale, 1.25, accuracy: 0.001)
        c.zoomOut(); c.zoomOut()
        XCTAssertEqual(c.scale, 0.75, accuracy: 0.001)
        c.zoomToFit()
        XCTAssertTrue(c.fitting)
        XCTAssertNil(c.memory.scale(for: c.path))
    }

    func testPDFMemoryPerPath() throws {
        let c = try pdfController()
        c.zoomIn()
        let remembered = c.memory.scale(for: c.path)
        XCTAssertNotNil(remembered)
        let again = PDFZoomController()
        again.memory = c.memory
        again.load(url: URL(fileURLWithPath: c.path))
        XCTAssertFalse(again.fitting)
        XCTAssertEqual(again.scale, remembered ?? 0, accuracy: 0.001)
    }

    func testDismantledPDFPaneReleasesItsController() throws {
        let url = try pdfFile()
        weak var weakController: PDFZoomController?
        autoreleasepool {
            var scale: CGFloat = 1
            var page = ""
            let box = PDFZoomPane.ControllerBox()
            let coordinator = PDFZoomPane.Coordinator()
            _ = PDFZoomPane.assemble(file: url, scale: Binding(get: { scale }, set: { scale = $0 }),
                                     page: Binding(get: { page }, set: { page = $0 }),
                                     box: box, coordinator: coordinator, slot: .space)
            weakController = coordinator.controller
            XCTAssertNotNil(weakController)
            PDFZoomPane.teardown(coordinator)
        }
        XCTAssertNil(weakController)
    }

    func testPDFSwitchKeepsEachFilesLevel() throws {
        let a = try pdfFile(), b = try pdfFile()
        let memory = ZoomMemory()
        memory.set(1.5, for: b.path)
        let c = PDFZoomController()
        c.memory = memory
        c.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        c.load(url: a)
        c.view.autoScales = false; c.view.scaleFactor = 2.0
        XCTAssertEqual(memory.scale(for: a.path), 2.0)
        c.load(url: b)
        XCTAssertEqual(c.scale, 1.5, accuracy: 0.001)
        XCTAssertEqual(memory.scale(for: b.path) ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(memory.scale(for: a.path) ?? 0, 2.0, accuracy: 0.001)

        // A at Fit, then B (remembered 1.5): still 1.5.
        let c2 = PDFZoomController()
        c2.memory = memory
        c2.view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        c2.load(url: try pdfFile())
        XCTAssertTrue(c2.fitting)
        c2.load(url: b)
        XCTAssertEqual(c2.scale, 1.5, accuracy: 0.001)
        XCTAssertEqual(memory.scale(for: b.path) ?? 0, 1.5, accuracy: 0.001)
    }
}
