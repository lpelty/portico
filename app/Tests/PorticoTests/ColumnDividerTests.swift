import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Portico

/// The grips of the column dividers. The sidebar divider's is SwiftUI,
/// centred on its line. The viewer divider's (v0.28, PORT-78) is centred
/// too, as an AppKit view over the window, so the web view beside the line
/// can't take the half over it. (v0.14 kept the whole grip on the
/// conversation side for that reason, which left the line's right side dead.)
@MainActor
final class ColumnDividerTests: XCTestCase {
    /// The grip's span across the 1-point line, in the line's own
    /// coordinates (the line runs 0...1).
    func testCentredGripStraddlesTheLine() {
        let span = ColumnDivider.gripSpan(.centred)
        XCTAssertEqual(span.lowerBound, -6.5)
        XCTAssertEqual(span.upperBound, 7.5)
        XCTAssertEqual(span.upperBound - span.lowerBound, 14)
    }

    func testLeadingGripEndsAtTheLinesFarEdge() {
        let span = ColumnDivider.gripSpan(.leading)
        XCTAssertEqual(span.upperBound, 1)
        XCTAssertEqual(span.lowerBound, -13)
        XCTAssertEqual(span.upperBound - span.lowerBound, 14, "the same 14-point grip")
    }

    func testTrailingGripStartsAtTheLinesNearEdge() {
        let span = ColumnDivider.gripSpan(.trailing)
        XCTAssertEqual(span.lowerBound, 0)
        XCTAssertEqual(span.upperBound, 14)
    }

    func testDefaultIsCentredAndGrips() {
        let divider = ColumnDivider(onDrag: { _ in }, onEnd: {}, onReset: {})
        XCTAssertEqual(divider.gripSide, .centred, "the sidebar divider is unchanged")
        XCTAssertTrue(divider.grips)
    }

    func testTheViewerDividersGripIsCentredOnItsLine() {
        XCTAssertEqual(MainWindow.viewerDividerGripSide, .centred)
        // A 1000-point window with a 440-point viewer: the line is the point before the viewer.
        let leading = MainWindow.viewerGripLeading(window: 1000, viewer: 440)
        let line: CGFloat = 1000 - 440 - 1
        XCTAssertEqual(leading, line - 6.5)
        XCTAssertEqual(leading + ColumnDivider.grip, line + 7.5, "as far right of the line as left of it")
        XCTAssertEqual(
            ColumnDivider.gripSpan(MainWindow.viewerDividerGripSide), ColumnDivider.gripSpan(.centred),
            "no narrower than the sidebar divider's")
    }

    // MARK: - Hosted: who gets the mouse beside a real web view

    private struct Page: NSViewRepresentable {
        func makeNSView(context: Context) -> WKWebView {
            let view = WKWebView(frame: .zero)
            view.loadHTMLString("<body style='margin:0'><p>page</p></body>", baseURL: nil)
            return view
        }

        func updateNSView(_ view: WKWebView, context: Context) {}
    }

    private final class Drags {
        var moved: [CGFloat] = []
        var ended = 0
        var reset = 0
    }

    private static let window: CGFloat = 800
    private static let viewer: CGFloat = 300
    private static let toolbar: CGFloat = 52
    private static let height: CGFloat = 400
    /// The line's left edge, from the window's left.
    private static let line: CGFloat = window - viewer - 1

    /// The window's three right-hand pieces as `MainWindow` lays them out: the conversation, the
    /// line alone, the viewer (a toolbar row over a web view), and the grip over them all.
    private func hosted(_ drags: Drags) -> (window: NSWindow, host: NSView) {
        let root = HStack(spacing: 0) {
            Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity)
            ColumnDivider(grips: false, onDrag: { _ in }, onEnd: {}, onReset: {})
            VStack(spacing: 0) {
                Color.blue.frame(height: Self.toolbar)
                Page()
            }
            .frame(width: Self.viewer)
        }
        .overlay(alignment: .leading) {
            DividerGrip(onDrag: { drags.moved.append($0) }, onEnd: { drags.ended += 1 }, onReset: { drags.reset += 1 })
                .frame(width: ColumnDivider.grip)
                .padding(.leading, MainWindow.viewerGripLeading(window: Self.window, viewer: Self.viewer))
        }
        .frame(width: Self.window, height: Self.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: Self.window, height: Self.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// The view the mouse reaches `dx` points from the line's left edge, `down` points below the window's top.
    private func hit(_ host: NSView, dx: CGFloat, down: CGFloat) -> NSView? {
        // AppKit's y runs up from the bottom unless the view is flipped.
        let y = host.isFlipped ? down : Self.height - down
        return host.hitTest(NSPoint(x: Self.line + dx, y: y))
    }

    func testTheGripAnswersOnTheLineAndOnBothSidesAlongItsWholeHeight() throws {
        let (window, host) = hosted(Drags())
        defer { window.close() }
        let grip = try XCTUnwrap(Self.find(DividerGripView.self, in: host))
        let lineInGrip = Self.line - grip.convert(grip.bounds, to: nil).minX
        XCTAssertEqual(lineInGrip, 6.5, accuracy: 0.01, "the grip is centred on the line")
        XCTAssertEqual(grip.frame.width, ColumnDivider.grip)
        XCTAssertEqual(grip.frame.height, Self.height, "the window's whole height")
        // In the toolbar row, just below it, mid-way down and near the bottom.
        for down in [CGFloat(20), Self.toolbar + 4, 200, Self.height - 4] {
            for dx in [CGFloat(-6), -3, 0.5, 4, 7] {
                XCTAssertTrue(hit(host, dx: dx, down: down) === grip, "\(dx) pt from the line, \(down) pt down")
            }
            XCTAssertFalse(hit(host, dx: -9, down: down) === grip, "the conversation, \(down) pt down")
            XCTAssertFalse(hit(host, dx: 10, down: down) === grip, "the viewer, \(down) pt down")
        }
        let page = try XCTUnwrap(Self.find(WKWebView.self, in: host))
        let below = try XCTUnwrap(hit(host, dx: 10, down: 200))
        XCTAssertTrue(below === page || below.isDescendant(of: page), "past the grip the page has the mouse")
    }

    func testTheGripSitsAboveTheWebViewItOverlaps() throws {
        let (window, host) = hosted(Drags())
        defer { window.close() }
        let grip = try XCTUnwrap(Self.find(DividerGripView.self, in: host))
        let page = try XCTUnwrap(Self.find(WKWebView.self, in: host))
        let gripFrame = grip.convert(grip.bounds, to: nil)
        let pageFrame = page.convert(page.bounds, to: nil)
        XCTAssertEqual(pageFrame.minX, Self.line + 1, accuracy: 0.01, "the page starts right after the line")
        XCTAssertEqual(gripFrame.intersection(pageFrame).width, 6.5, accuracy: 0.01, "the grip's right half lies over the page")
    }

    func testADragResizesAndADoubleClickResets() throws {
        let drags = Drags()
        let (window, host) = hosted(drags)
        defer { window.close() }
        let grip = try XCTUnwrap(Self.find(DividerGripView.self, in: host))
        func event(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        // From the right half of the grip, over the page.
        grip.mouseDown(with: try event(.leftMouseDown, x: Self.line + 5))
        grip.mouseDragged(with: try event(.leftMouseDragged, x: Self.line - 35))
        grip.mouseDragged(with: try event(.leftMouseDragged, x: Self.line + 25))
        grip.mouseUp(with: try event(.leftMouseUp, x: Self.line + 25))
        XCTAssertEqual(drags.moved, [-40, 20], "the drag so far, from where it began")
        XCTAssertEqual(drags.ended, 1)
        XCTAssertEqual(drags.reset, 0)
        grip.mouseDown(with: try event(.leftMouseDown, x: Self.line, clicks: 2))
        grip.mouseDragged(with: try event(.leftMouseDragged, x: Self.line + 30))
        grip.mouseUp(with: try event(.leftMouseUp, x: Self.line + 30, clicks: 2))
        XCTAssertEqual(drags.reset, 1)
        XCTAssertEqual(drags.moved, [-40, 20], "a double click drags nothing")
        XCTAssertEqual(drags.ended, 1)
        XCTAssertFalse(grip.mouseDownCanMoveWindow, "a drag on the grip in the toolbar row never moves the window")
    }

    private static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let found = view as? V { return found }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}
