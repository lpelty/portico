import AppKit
import XCTest

@testable import Portico

/// v0.15 task 2b fix round 2: the person's scroll keys and wheels over the
/// transcript, which may report no scroll phase.
@MainActor
final class TranscriptPersonInputTests: XCTestCase {
    private struct Fixture {
        let window: NSWindow
        let scroll: NSScrollView
        let reply: NSTextView
        let outside: NSTextView
    }

    private func fixture() -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let reply = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 2000))
        scroll.documentView = reply
        let outside = NSTextView(frame: NSRect(x: 0, y: 300, width: 600, height: 100))
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(outside)
        addTeardownBlock { window.close() }
        return Fixture(window: window, scroll: scroll, reply: reply, outside: outside)
    }

    private func key(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code))
    }

    func testAMarkCountsForAShortSpan() {
        let input = TranscriptPersonInput()
        var clock: TimeInterval = 10
        input.now = { clock }
        XCTAssertFalse(input.isRecent, "nothing yet")
        input.mark()
        clock = 10.2
        XCTAssertTrue(input.isRecent)
        clock = 10.4
        XCTAssertFalse(input.isRecent, "past the span")
    }

    func testTheScrollKeysCountWhileTheFocusIsInTheTranscript() throws {
        let f = fixture()
        let input = TranscriptPersonInput()
        input.scrollView = f.scroll
        XCTAssertTrue(f.window.makeFirstResponder(f.reply))
        for code: UInt16 in [116, 121, 115, 119, 126, 125, 49] {
            XCTAssertTrue(input.takes(try key(code, in: f.window)), "key \(code)")
        }
        XCTAssertFalse(input.takes(try key(0, in: f.window)), "a letter")
        XCTAssertTrue(f.window.makeFirstResponder(f.outside))
        XCTAssertFalse(input.takes(try key(116, in: f.window)), "the focus elsewhere (the composer)")
    }

    func testAWheelCountsOverTheTranscriptOnly() throws {
        let f = fixture()
        let input = TranscriptPersonInput()
        input.scrollView = f.scroll
        func wheel(at point: NSPoint) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
            let screen = f.window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        XCTAssertTrue(input.takes(try wheel(at: NSPoint(x: 300, y: 150))), "over the transcript")
        XCTAssertFalse(input.takes(try wheel(at: NSPoint(x: 300, y: 350))), "over the composer")
    }
}
