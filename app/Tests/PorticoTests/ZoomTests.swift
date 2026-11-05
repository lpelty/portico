import AppKit
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
}
