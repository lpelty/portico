import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.18 §4.2 (ruling 39): Portico's own tooltip, centred under its control,
/// 6 pt below its bottom edge, kept 8 pt inside the window, after 0.8 s of
/// hover, hidden on a click, and still read by VoiceOver.
@MainActor
final class TipTests: XCTestCase {
    // MARK: - placement (AppKit coordinates: y grows upward)

    private let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let size = CGSize(width: 120, height: 24)

    func testCentredSixPointsBelow() {
        let control = CGRect(x: 100, y: 500, width: 40, height: 20)
        let frame = TipPlacement.frame(for: control, size: size, in: window)
        XCTAssertEqual(frame.minX, 60, "centred: 120 - 120 / 2")
        XCTAssertEqual(frame.midX, control.midX)
        XCTAssertEqual(frame.maxY, control.minY - 6, "its top 6 pt below the control's bottom edge")
        XCTAssertEqual(frame.size, size)
    }

    func testClampedAtTheWindowEdges() {
        let left = TipPlacement.frame(for: CGRect(x: 2, y: 300, width: 20, height: 20), size: size, in: window)
        XCTAssertEqual(left.minX, 8)
        let right = TipPlacement.frame(for: CGRect(x: 780, y: 300, width: 20, height: 20), size: size, in: window)
        XCTAssertEqual(right.maxX, 792)
        let low = CGRect(x: 300, y: 10, width: 40, height: 20)
        let above = TipPlacement.frame(for: low, size: size, in: window)
        XCTAssertEqual(above.minY, low.maxY + 6, "near the bottom it goes above the control")
        // A window that does not start at the origin (screen coordinates).
        let offset = CGRect(x: 1000, y: 200, width: 800, height: 600)
        let shifted = TipPlacement.frame(for: CGRect(x: 1002, y: 500, width: 20, height: 20), size: size, in: offset)
        XCTAssertEqual(shifted.minX, 1008)
        XCTAssertEqual(shifted.maxY, 494)
    }

    func testDelayIsEightTenths() {
        XCTAssertEqual(Tip.delay, 0.8)
    }

    func testStyleIsAR7() {
        XCTAssertEqual(Tip.fontSize, 11.5)
        XCTAssertEqual(Tip.cornerRadius, 5)
        XCTAssertEqual(Tip.padding, EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        XCTAssertEqual(Tip.fillHex, "#2B2B2E")
        XCTAssertEqual(Tip.textHex, "#E6E6E8")
        XCTAssertEqual(Tip.strokeHex, "#FFFFFF1F")
    }

    // MARK: - hosted: delay, hide on click

    private struct Probe: View {
        var body: some View {
            VStack {
                Button("Widen") {}.tip("Widen the viewer (⌘⇧↩)")
            }
            .frame(width: 400, height: 300)
        }
    }

    private func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func hostedWindow<V: View>(_ view: V) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 200, y: 200, width: 400, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        spin(0.3)
        return window
    }

    private static func anchor(in view: NSView) -> TipAnchorView? {
        if let found = view as? TipAnchorView { return found }
        for sub in view.subviews { if let found = anchor(in: sub) { return found } }
        return nil
    }

    private static func shownTip(_ window: NSWindow) -> TipPanel? {
        (window.childWindows ?? []).compactMap { $0 as? TipPanel }.first { $0.isVisible }
    }

    func testDelayAndHide() throws {
        let window = hostedWindow(Probe())
        defer { window.close() }
        let anchor = try XCTUnwrap(Self.anchor(in: try XCTUnwrap(window.contentView)), "the tip's anchor view")
        anchor.mouseEntered(with: try XCTUnwrap(Self.event(.mouseEntered, in: window, at: anchor)))
        spin(0.5)
        XCTAssertNil(Self.shownTip(window), "nothing at 0.5 s")
        spin(0.4)
        let panel = try XCTUnwrap(Self.shownTip(window), "shown at 0.9 s")
        XCTAssertEqual(panel.tipText, "Widen the viewer (⌘⇧↩)")
        XCTAssertTrue(panel.ignoresMouseEvents)
        // Centred under the control, 6 pt below it, in screen coordinates.
        let control = anchor.window!.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        XCTAssertEqual(panel.bubbleFrame.midX, control.midX, accuracy: 0.5)
        XCTAssertEqual(panel.bubbleFrame.maxY, control.minY - 6, accuracy: 0.5)

        let down = try XCTUnwrap(Self.event(.leftMouseDown, in: window, at: anchor))
        let up = try XCTUnwrap(Self.event(.leftMouseUp, in: window, at: anchor))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        Self.deliverEvents()
        spin(0.2)
        XCTAssertNil(Self.shownTip(window), "a mouse-down hides it")
        spin(1.0)
        XCTAssertNil(Self.shownTip(window), "and it stays hidden while the pointer is still there")
    }

    func testHoverEndCancelsAndHides() throws {
        let window = hostedWindow(Probe())
        defer { window.close() }
        let anchor = try XCTUnwrap(Self.anchor(in: try XCTUnwrap(window.contentView)))
        anchor.mouseEntered(with: try XCTUnwrap(Self.event(.mouseEntered, in: window, at: anchor)))
        spin(0.3)
        anchor.mouseExited(with: try XCTUnwrap(Self.event(.mouseExited, in: window, at: anchor)))
        spin(0.8)
        XCTAssertNil(Self.shownTip(window), "left before 0.8 s: never shown")
        anchor.mouseEntered(with: try XCTUnwrap(Self.event(.mouseEntered, in: window, at: anchor)))
        spin(0.9)
        XCTAssertNotNil(Self.shownTip(window))
        anchor.mouseExited(with: try XCTUnwrap(Self.event(.mouseExited, in: window, at: anchor)))
        spin(0.1)
        XCTAssertNil(Self.shownTip(window), "hover end hides it")
    }

    func testWindowResigningKeyHides() throws {
        let window = hostedWindow(Probe())
        defer { window.close() }
        let anchor = try XCTUnwrap(Self.anchor(in: try XCTUnwrap(window.contentView)))
        anchor.mouseEntered(with: try XCTUnwrap(Self.event(.mouseEntered, in: window, at: anchor)))
        spin(0.9)
        XCTAssertNotNil(Self.shownTip(window))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        spin(0.1)
        XCTAssertNil(Self.shownTip(window), "the window stopped being key")
    }

    /// Hands the queued events to the app, as its event loop would (local
    /// monitors run there).
    private static func deliverEvents() {
        let until = Date().addingTimeInterval(0.3)
        while Date() < until {
            guard let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func event(_ type: NSEvent.EventType, in window: NSWindow, at view: NSView) -> NSEvent? {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        switch type {
        case .mouseEntered, .mouseExited:
            return NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        default:
            return NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
    }

    // MARK: - VoiceOver
    //
    // SwiftUI builds no accessibility tree for an in-process query from the
    // test runner (the window's children stay empty), so these read the hint
    // the modifier applies off the view itself.

    func testVoiceOverHint() throws {
        let view = Button("Widen") {}.tip("Widen the viewer (⌘⇧↩)")
        let tipped = try XCTUnwrap(view as? ModifiedContent<Button<Text>, TipModifier>)
        XCTAssertEqual(tipped.modifier.hint, "Widen the viewer (⌘⇧↩)")
        XCTAssertEqual(tipped.modifier.text, "Widen the viewer (⌘⇧↩)")
    }

    func testAViewsOwnHintWins() throws {
        let view = Button("Model") {}.tip("Change the model after this reply", keepsOwnHint: true)
        let tipped = try XCTUnwrap(view as? ModifiedContent<Button<Text>, TipModifier>)
        XCTAssertNil(tipped.modifier.hint, "the view's own .accessibilityHint stays the only one")
        XCTAssertEqual(tipped.modifier.text, "Change the model after this reply")
    }

    func testAnEmptyTipSetsNoHint() throws {
        let view = Button("Model") {}.tip("")
        let tipped = try XCTUnwrap(view as? ModifiedContent<Button<Text>, TipModifier>)
        XCTAssertNil(tipped.modifier.hint)
    }

    /// Every view in the app that sets its own hint keeps it.
    func testViewsWithTheirOwnHintKeepIt() throws {
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "Tip.swift" {
            let lines = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(".accessibilityHint(") {
                // The hint's own modifier chain: the lines up to it, back to the view.
                let window = lines[max(0, index - 6)..<index]
                if let tip = window.last(where: { $0.contains(".tip(") }), !tip.contains("keepsOwnHint: true") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "a .tip next to the view's own .accessibilityHint must keep it: \(offenders)")
    }
}
