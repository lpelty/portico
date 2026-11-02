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
        input.mark(direction: .up)
        clock = 10.2
        XCTAssertTrue(input.isRecent)
        XCTAssertEqual(input.recent, .up)
        clock = 10.4
        XCTAssertFalse(input.isRecent, "past the span")
    }

    /// Fix round 4: a mark carries its direction for the whole span (no
    /// longer spent by the first reading); the next input replaces it.
    /// VoiceOver's cursor marks `.either`.
    func testAMarkKeepsItsDirectionForItsSpan() {
        let input = TranscriptPersonInput()
        var clock: TimeInterval = 10
        input.now = { clock }
        input.mark(direction: .down)
        clock = 10.1
        XCTAssertEqual(input.recent, .down)
        clock = 10.25
        XCTAssertEqual(input.recent, .down, "still marked late in the span")
        input.mark(direction: .either)
        XCTAssertEqual(input.recent, .either, "the next input replaces it")
    }

    func testTheScrollKeysCountWhileTheFocusIsInTheTranscript() throws {
        let f = fixture()
        let input = TranscriptPersonInput()
        input.scrollView = f.scroll
        XCTAssertTrue(f.window.makeFirstResponder(f.reply))
        for code: UInt16 in [116, 121, 115, 119, 126, 125, 49] {
            XCTAssertTrue(input.takes(try key(code, in: f.window)), "key \(code)")
        }
        // Fix round 4: each key's direction.
        for (code, direction): (UInt16, TranscriptPersonInput.Direction) in [
            (116, .up), (115, .up), (126, .up), (121, .down), (119, .down), (125, .down), (49, .down),
        ] {
            XCTAssertEqual(input.direction(of: try key(code, in: f.window)), direction, "key \(code)")
        }
        let shiftSpace = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: f.window.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertEqual(input.direction(of: shiftSpace), .up, "Shift-Space")
        XCTAssertFalse(input.takes(try key(0, in: f.window)), "a letter")
        XCTAssertTrue(f.window.makeFirstResponder(f.outside))
        XCTAssertFalse(input.takes(try key(116, in: f.window)), "the focus elsewhere (the composer)")
    }

    func testAWheelCountsOverTheTranscriptOnly() throws {
        let f = fixture()
        let input = TranscriptPersonInput()
        input.scrollView = f.scroll
        func wheel(at point: NSPoint, delta: Int32 = 10) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            let screen = f.window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        XCTAssertTrue(input.takes(try wheel(at: NSPoint(x: 300, y: 150))), "over the transcript")
        XCTAssertFalse(input.takes(try wheel(at: NSPoint(x: 300, y: 350))), "over the composer")
        // Fix round 4: a positive wheel delta is toward the top, as the
        // hosted tests and `page(toward:)` post it.
        XCTAssertEqual(input.direction(of: try wheel(at: NSPoint(x: 300, y: 150), delta: 10)), .up)
        XCTAssertEqual(input.direction(of: try wheel(at: NSPoint(x: 300, y: 150), delta: -10)), .down)
    }
}
