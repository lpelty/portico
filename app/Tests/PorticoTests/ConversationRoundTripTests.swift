import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.14 test fix (issue 1): opening a space narrows the conversation and
/// going back to Work widens it again. The conversation must stay where the
/// person left it, scroll position included. Found live: it jumped to
/// another place, as if a stored location were put back.
///
/// Hosted: the real `ConversationView` in a borderless window, scrolled by
/// wheel events as a person scrolls, its width eased in steps as the
/// viewer's slide animates it. Where it is is read as the person sees it:
/// the reply at the top of the view and how far its top sits from the
/// view's top (the lazy stack re-estimates rows off screen at each width,
/// so the raw offset is no measure of it).
@MainActor
final class ConversationRoundTripTests: XCTestCase {
    private var defaults: UserDefaults!

    private func model() throws -> AppModel {
        let suite = "portico-roundtrip-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.14.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        // Forty turns of a question and a long reply: far taller than the view.
        var events: [ServerMessage] = []
        var seq = 0
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        for turn in 1...40 {
            seq += 1
            events.append(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan", seq: seq)))
            seq += 1
            events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). \(reply)", seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3)))
        return model
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let scroll: NSScrollView
    }

    private func host(_ model: AppModel, width: CGFloat) throws -> Hosted {
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            ConversationView(chat: 3)
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin()
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: host), "the transcript's scroll view")
        return Hosted(window: window, host: host, scroll: scroll)
    }

    private func spin(_ seconds: Double = 0.4) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The tall scroll view: the transcript (the composer's editor scrolls too).
    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 2000 { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    /// The reply at the top of the visible area (replies are text views)
    /// and where its top sits against the visible top.
    private static func topReply(in scroll: NSScrollView) -> (text: String, dy: CGFloat)? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        var best: (text: String, top: CGFloat)?
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, !text.isHidden {
                let frame = text.convert(text.bounds, to: document)
                if frame.maxY > visible.minY, frame.minY < visible.maxY, best == nil || frame.minY < best!.top {
                    best = (String(text.string.prefix(10)), frame.minY)
                }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(document)
        return best.map { ($0.text, $0.top - visible.minY) }
    }

    /// One scroll-wheel event over the scroll view (positive: up the transcript).
    private static func wheel(_ scroll: NSScrollView, pixels: Int32) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        scroll.scrollWheel(with: event)
    }

    /// The column's width eased over a few frames, as the viewer's slide animates it.
    private func resize(_ hosted: Hosted, from: CGFloat, to: CGFloat) {
        for step in 1...8 {
            let width = (from + (to - from) * CGFloat(step) / 8).rounded()
            hosted.host.setFrameSize(NSSize(width: width, height: 600))
            hosted.window.setContentSize(NSSize(width: width, height: 600))
            spin(0.03)
        }
        spin()
    }

    func testASpaceAndBackLeavesAScrolledUpConversationWhereThePersonLeftIt() throws {
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        // The person scrolls up to about a third of the way down: mid-transcript.
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))

        resize(hosted, from: 900, to: 640)  // a space opens beside it
        let inSpace = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        XCTAssertEqual(inSpace.text, before.text, "the same reply stays at the top while the space is open")
        resize(hosted, from: 640, to: 900)  // Work again
        let after = try XCTUnwrap(Self.topReply(in: hosted.scroll))

        XCTAssertEqual(after.text, before.text, "the same reply at the top")
        XCTAssertEqual(after.dy, before.dy, accuracy: 4, "at the same point in it")
    }

    /// Fix round 1 (Important 2): scrolled up about one screen from the
    /// end, a step of the reflow can read as the bottom; it must not be
    /// taken for the person's place and snap the conversation to its end.
    /// A guard: hosted, the reflow did not produce such a reading, so this
    /// passed before the fix too (`ConversationScrollTests` holds the RED).
    /// Only the snap is checked here: near the end SwiftUI's own anchoring
    /// moves the reply by up to a bubble's height (22 pt seen), before and
    /// after this fix alike.
    func testASpaceAndBackLeavesAConversationScrolledUpNearTheEndInPlace() throws {
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        let screen = clip.bounds.height
        for _ in 0..<20 where clip.bounds.maxY > height - screen {
            Self.wheel(hosted.scroll, pixels: 120)
            spin(0.05)
        }
        spin(0.3)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))

        resize(hosted, from: 900, to: 640)
        resize(hosted, from: 640, to: 900)
        let after = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        XCTAssertEqual(after.text, before.text, "the same reply at the top, not the end")
        let end = try XCTUnwrap(hosted.scroll.documentView).frame.height
        XCTAssertLessThan(clip.bounds.maxY, end - ConversationScrollMemory.bottomSlack, "not snapped to the end")
    }

    func testASpaceAndBackLeavesAConversationAtItsBottomAtItsBottom() throws {
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        XCTAssertTrue(atBottom(), "a conversation opens at its newest message")
        resize(hosted, from: 900, to: 640)
        XCTAssertTrue(atBottom(), "still at the newest message beside the space")
        resize(hosted, from: 640, to: 900)
        XCTAssertTrue(atBottom(), "still at the newest message back in Work")
    }
}
