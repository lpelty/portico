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

    private func model(chats: [Int] = [3]) throws -> AppModel {
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
        model.apply(.chatList(ChatList(chats: chats.map { ChatSummary(
            chat: $0, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z") })))
        model.selected = chats[0]
        // Forty turns of a question and a long reply: far taller than the view.
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        for chat in chats {
            var events: [ServerMessage] = []
            var seq = 0
            for turn in 1...40 {
                seq += 1
                events.append(.userText(UserText(chat: chat, turn: turn, text: "Question \(turn) from Jordan", seq: seq)))
                seq += 1
                events.append(.textDelta(TextDelta(chat: chat, turn: turn, text: "Answer \(turn). \(reply)", seq: seq)))
            }
            model.apply(.chatHistory(ChatHistory(chat: chat, events: events, truncated: false)))
            model.apply(.chatLive(ChatLive(chat: chat)))
        }
        return model
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let scroll: NSScrollView
    }

    /// The conversation the model has selected, drawn as the main window
    /// draws it: a new view for each chat (`.id`).
    private struct Selected: View {
        @EnvironmentObject var model: AppModel

        var body: some View {
            if let chat = model.selected {
                ConversationView(chat: chat).id(chat)
            }
        }
    }

    private func host(_ model: AppModel, width: CGFloat) throws -> Hosted {
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
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
            // Review M2: a text view under a hidden ancestor is one the lazy stack keeps
            // for reuse (here, another conversation's), not one on screen.
            if let text = view as? NSTextView, !text.isHiddenOrHasHiddenAncestor {
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

    /// The person scrolls by `pixels` (positive: up the transcript): the
    /// clip view moves inside a live scroll, as a wheel or trackpad scroll
    /// does, so SwiftUI tracks the message at the top. (Fix round 1: posted
    /// wheel events were dropped or not depending on the machine's own
    /// pointer and input state, so the test came and went with it.)
    private static func wheel(_ scroll: NSScrollView, pixels: Int32) {
        let clip = scroll.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let y = max(0, clip.bounds.origin.y - CGFloat(pixels))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
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

    /// v0.15 task 2b fix round 1 (Important 1): scrolled up, the person
    /// sends; the app follows to the newest message, and a space opening
    /// next keeps it there.
    func testScrolledUpThenSendingThenASpaceLeavesItAtItsBottom() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        XCTAssertFalse(atBottom(), "scrolled up")
        model.apply(.userText(UserText(chat: 3, turn: 41, text: "Question 41 from Jordan", seq: 81)))
        spin()
        XCTAssertTrue(atBottom(), "the person's message goes to the bottom")
        resize(hosted, from: 900, to: 640)
        XCTAssertTrue(atBottom(), "still at the newest message beside the space")
        resize(hosted, from: 640, to: 900)
        XCTAssertTrue(atBottom(), "still at the newest message back in Work")
    }

    /// v0.15 task 2b fix round 1 (Important 2): scrolled up while a reply
    /// streams in, the conversation stays where the person is.
    func testScrolledUpWhileAReplyStreamsStaysPut() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        for step in 1...8 {
            model.apply(.textDelta(TextDelta(chat: 3, turn: 40, text: " More of the reply, part \(step).", seq: 80 + step)))
            spin(0.05)
        }
        spin()
        let after = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        XCTAssertEqual(after.text, before.text, "the same reply at the top")
        XCTAssertEqual(after.dy, before.dy, accuracy: 4, "at the same point in it")
    }

    /// A wheel event as the app dispatches it, without gesture phases (a
    /// plain wheel mouse): `NSApp.sendEvent` runs the app's event monitors
    /// (the window is off screen, so it is not routed further), then the
    /// scroll view scrolls by it.
    private static func phaselessWheel(_ hosted: Hosted, pixels: Int32) throws {
        let scroll = hosted.scroll
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = hosted.window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: top - screen.y)  // CG: top-left origin
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.phase, [], "no gesture phase")
        NSApp.sendEvent(event)
        scroll.scrollWheel(with: event)
    }

    /// v0.15 task 2b fix round 2 (C1): a plain wheel mouse, at the bottom,
    /// scrolls up and stays up. A guard: SwiftUI reports a scroll phase for
    /// a wheel without gesture phases too, so this passed before the fix.
    func testAtTheBottomAPlainWheelScrollUpStaysUp() throws {
        _ = NSApplication.shared
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        XCTAssertTrue(atBottom())
        for _ in 0..<4 {
            try Self.phaselessWheel(hosted, pixels: 150)
            spin(0.05)
        }
        spin(0.6)
        XCTAssertFalse(atBottom(), "still scrolled up")
        resize(hosted, from: 900, to: 640)
        XCTAssertFalse(atBottom(), "and a space keeps that place")
    }

    /// Fix round 2 (C1): Page Up from inside the transcript (its rows are
    /// selectable, so the scroll keys reach it) stays up; before, the app
    /// snapped it back to the end. Pressed twice: SwiftUI puts the first
    /// scroll after the app's scroll to the bottom back once, whatever the
    /// input (v0.14.0 alike; not the app's memory).
    func testAtTheBottomPageUpStaysUp() throws {
        _ = NSApplication.shared
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        XCTAssertTrue(atBottom())
        let reply = try XCTUnwrap(Self.firstTextView(in: try XCTUnwrap(hosted.scroll.documentView)))
        XCTAssertTrue(hosted.window.makeFirstResponder(reply))
        let before = clip.bounds.origin.y
        for _ in 0..<2 {
            let pageUp = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber, context: nil, characters: "\u{F72C}",
                charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116))
            NSApp.sendEvent(pageUp)  // as the app dispatches it: its event monitors see it
            hosted.window.sendEvent(pageUp)  // the window is not key: hand it to the first responder
            spin(0.3)
        }
        spin(0.6)
        XCTAssertLessThan(clip.bounds.origin.y, before - 100, "paged up")
        XCTAssertFalse(atBottom(), "still scrolled up")
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }

    /// Fix round 3 (I2): at the bottom while a reply streams, the person
    /// scrolls up and back down to the end; following resumes (the reading
    /// after their scroll, off the end only because the reply grew, is not
    /// taken for them leaving the bottom).
    func testScrollingBackToTheEndWhileAReplyStreamsResumesFollowing() throws {
        _ = NSApplication.shared
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        var seq = 80
        func stream(_ count: Int) {
            for _ in 0..<count {
                seq += 1
                model.apply(.textDelta(TextDelta(
                    chat: 3, turn: 40, text: " Another long line of the reply, streamed in as it is written, part \(seq).",
                    seq: seq)))
                spin(0.05)
            }
        }
        stream(2)
        for _ in 0..<3 {
            Self.wheel(hosted.scroll, pixels: 200)
            stream(1)
        }
        XCTAssertFalse(atBottom(), "scrolled up")
        // Down to the end by a wheel, as the app dispatches it (marked as
        // the person's for a moment), the reply still streaming in.
        for _ in 0..<12 where !atBottom() {
            try Self.phaselessWheel(hosted, pixels: -300)
            stream(1)
        }
        stream(6)
        spin()
        XCTAssertTrue(atBottom(), "following again")
    }

    /// A scroll key pressed in the transcript, as the app dispatches it
    /// (its event monitors see it), then handed to the first responder
    /// (the window is not key).
    private static func press(_ code: UInt16, _ character: Character, in hosted: Hosted) throws {
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: String(character),
            charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code))
        NSApp.sendEvent(key)
        hosted.window.sendEvent(key)
    }

    private func streaming(_ model: AppModel) -> (Int) -> Void {
        var seq = 80
        return { count in
            for _ in 0..<count {
                seq += 1
                model.apply(.textDelta(TextDelta(
                    chat: 3, turn: 40, text: " Another long line of the reply, streamed in as it is written, part \(seq).",
                    seq: seq)))
                self.spin(0.05)
            }
        }
    }

    /// Fix round 4 (N1): at the bottom while a reply streams, Page Up
    /// leaves the end and stays up; a reply delta landing between the key
    /// and its scroll is not taken for the person going back down.
    func testPageUpWhileAReplyStreamsStaysUp() throws {
        _ = NSApplication.shared
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        let stream = streaming(model)
        stream(2)
        XCTAssertTrue(atBottom(), "following the reply")
        let reply = try XCTUnwrap(Self.firstTextView(in: try XCTUnwrap(hosted.scroll.documentView)))
        XCTAssertTrue(hosted.window.makeFirstResponder(reply))
        // Twice: SwiftUI puts the first scroll after the app's scroll to the
        // bottom back once (round 2). A delta right after each key.
        for _ in 0..<2 {
            try Self.press(116, "\u{F72C}", in: hosted)
            stream(1)
            spin(0.3)
        }
        stream(6)
        spin(0.6)
        XCTAssertFalse(atBottom(), "still scrolled up")
    }

    private static func visibleTextView(in scroll: NSScrollView) -> NSTextView? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        func walk(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, !text.isHidden, text.convert(text.bounds, to: document).intersects(visible) {
                return text
            }
            for sub in view.subviews { if let found = walk(sub) { return found } }
            return nil
        }
        return walk(document)
    }

    /// A scroll key AppKit animates (on screen, smooth scrolling): the app
    /// dispatches it (its event monitors mark it), then the clip view moves
    /// over a few frames to `y`, no scroll phase; `before` runs between the
    /// key and its first frame. Off screen, AppKit does not animate it (it lands in one
    /// jump), so the frames are made here.
    private func animatedKey(
        _ code: UInt16, _ character: Character, in hosted: Hosted, to y: CGFloat, frames: Int = 4,
        before: () -> Void = {}
    ) throws {
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: String(character),
            charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code))
        // The focus in a reply on screen (the lazy stack drops rows scrolled away).
        let reply = try XCTUnwrap(Self.visibleTextView(in: hosted.scroll), "a reply on screen")
        XCTAssertTrue(hosted.window.makeFirstResponder(reply))
        NSApp.sendEvent(key)  // the monitor; off screen, it goes no further
        before()
        let clip = hosted.scroll.contentView
        let from = clip.bounds.origin.y
        for frame in 1...frames {
            let next = from + (y - from) * CGFloat(frame) / CGFloat(frames)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next.rounded()))
            hosted.scroll.reflectScrolledClipView(clip)
            spin(0.02)
        }
    }

    /// Fix round 4 (N1): at the bottom while a reply streams, Page Up and
    /// then Page Down back to the end, each animated over several frames:
    /// following resumes. Before, the first frame spent the mark, the
    /// frames reaching the end were not the person's, and the memory
    /// stayed scrolled up.
    func testAnimatedPageUpThenPageDownWhileAReplyStreamsResumesFollowing() throws {
        _ = NSApplication.shared
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        let stream = streaming(model)
        stream(2)
        spin()
        // Twice: SwiftUI puts the first scroll after the app's scroll to the
        // bottom back once (round 2).
        for _ in 0..<2 {
            try animatedKey(116, "\u{F72C}", in: hosted, to: clip.bounds.origin.y - 450)
            spin(0.4)
        }
        XCTAssertFalse(atBottom(), "paged up")
        for _ in 0..<4 where !atBottom() {
            let end = (hosted.scroll.documentView?.frame.height ?? 0) - clip.bounds.height
            try animatedKey(121, "\u{F72D}", in: hosted, to: min(end, clip.bounds.origin.y + 450))
            spin(0.4)
        }
        XCTAssertTrue(atBottom(), "back at the end")
        stream(8)
        spin()
        XCTAssertTrue(atBottom(), "following again")
    }

    /// Fix round 4 (N1): at the bottom while a reply streams, a delta lands
    /// between Page Up and its first animated frame. Before, its reading
    /// spent the mark and went back to the bottom, swallowing the key.
    func testAnimatedPageUpWithADeltaBeforeItsFirstFrameStaysUp() throws {
        _ = NSApplication.shared
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        func atBottom() -> Bool {
            let height = hosted.scroll.documentView?.frame.height ?? 0
            return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
        }
        let stream = streaming(model)
        stream(2)
        spin()
        // Once: before, this one press was swallowed (a second one held).
        try animatedKey(116, "\u{F72C}", in: hosted, to: clip.bounds.origin.y - 450, before: { stream(1) })
        spin(0.4)
        XCTAssertFalse(atBottom(), "paged up")
        stream(4)
        spin()
        XCTAssertFalse(atBottom(), "still up as the reply streams")
    }

    // MARK: - v0.16 §5: the scroll on ScrollPosition

    private func atBottom(_ hosted: Hosted) -> Bool {
        let clip = hosted.scroll.contentView
        let height = hosted.scroll.documentView?.frame.height ?? 0
        return clip.bounds.maxY >= height - ConversationScrollMemory.bottomSlack
    }

    /// The transcript's person-input marks, as the view holds them.
    private static func personInput(in view: NSView) -> TranscriptPersonInput? {
        if let probe = view as? TranscriptScrollViewProbe.Probe { return probe.input }
        for sub in view.subviews { if let found = personInput(in: sub) { return found } }
        return nil
    }

    /// §5 case 1 (v0.15 R10): the person's first scroll after a
    /// conversation opens at its bottom is not put back.
    func testTheFirstScrollAfterOpeningAtTheBottomHolds() throws {
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        XCTAssertTrue(atBottom(hosted), "a conversation opens at its newest message")
        Self.wheel(hosted.scroll, pixels: 600)
        spin(0.05)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        spin(1.0)
        XCTAssertFalse(atBottom(hosted), "still scrolled up")
        let after = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        XCTAssertEqual(after.text, before.text, "the same reply at the top")
    }

    /// §5 case 2 (v0.15 N2), a GUARD, not a proof: at the end, inside a
    /// live scroll, the clip moves back 46 pt and forward again; the reply
    /// streaming next is still followed. It cannot fail under the kept
    /// phase rule (phase readings stay the person's, and the forward move
    /// lands at the end), and it passed on v0.15. Case 2 stays open in
    /// logic pending the on-screen check.
    func testGuardAnOffsetPutBackInsideALiveScrollAtTheEndStillFollows() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let stream = streaming(model)
        stream(2)
        spin()
        XCTAssertTrue(atBottom(hosted), "following the reply")
        let scroll = hosted.scroll
        let clip = scroll.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let end = clip.bounds.origin.y
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end - 46))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        spin(0.05)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        spin(0.05)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        spin()
        stream(1)
        spin()
        XCTAssertTrue(atBottom(hosted), "the next delta still lands at the bottom")
    }

    /// §5 case 3 (v0.15 Task 2b round 4), a GUARD, not a proof: a
    /// 4,000-word reply streamed in at the bottom, then the column narrowed
    /// 900 → 640: at the end. It passed on v0.15 too; the original repro
    /// (the document's height and SwiftUI's content height disagreeing) was
    /// not reproduced here. Unproven pending the on-screen check.
    func testGuardALongStreamedReplyNarrowedAtTheBottomLandsAtTheEnd() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        model.apply(.userText(UserText(chat: 3, turn: 41, text: "Question 41 from Jordan", seq: 81)))
        spin(0.1)
        let words = Array(repeating: "Priya", count: 100).joined(separator: " ")
        for part in 1...40 {
            model.apply(.textDelta(TextDelta(chat: 3, turn: 41, text: (part == 1 ? "" : " ") + words, seq: 81 + part)))
            spin(0.03)
        }
        spin()
        XCTAssertTrue(atBottom(hosted), "following the reply at 900")
        resize(hosted, from: 900, to: 640)
        XCTAssertTrue(atBottom(hosted), "at the end at 640")
    }

    /// §5 case 5: VoiceOver moves its cursor up from the bottom (a mark
    /// either way, the clip 300 pt up, no scroll phase); the next delta
    /// does not snap it back.
    func testVoiceOverMovingUpFromTheBottomDoesNotSnapBack() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let stream = streaming(model)
        stream(1)
        spin()
        XCTAssertTrue(atBottom(hosted))
        let input = try XCTUnwrap(Self.personInput(in: hosted.host), "the transcript's input marks")
        input.mark(direction: .either)
        let clip = hosted.scroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y - 300))
        hosted.scroll.reflectScrolledClipView(clip)
        spin(0.1)
        stream(1)
        spin()
        XCTAssertFalse(atBottom(hosted), "still up")
    }

    /// v0.16 §5: each conversation keeps its own place. Chat 3 scrolled up,
    /// chat 5 shown in its place (a new view), back to 3: the same reply at
    /// the top, at the same point; chat 5, left at its bottom, is at its bottom.
    /// Review M2: every person bubble now reserves its hover row's height
    /// (`UserBubble.hoverRowHeight`), so the rows are taller than when this
    /// was written; the place is still kept, read through visible text only.
    func testEachConversationKeepsItsPlace() throws {
        let model = try model(chats: [3, 5])
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        model.selected = 5
        spin()
        let five = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let fiveHosted = Hosted(window: hosted.window, host: hosted.host, scroll: five)
        XCTAssertTrue(atBottom(fiveHosted), "chat 5 opens at its bottom")
        model.selected = 3
        spin()
        let three = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let after = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(after.text, before.text, "the same reply at the top")
        XCTAssertEqual(after.dy, before.dy, accuracy: 2, "at the same point in it")
        model.selected = 5
        spin()
        let fiveAgain = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        XCTAssertTrue(
            atBottom(Hosted(window: hosted.window, host: hosted.host, scroll: fiveAgain)), "chat 5 still at its bottom")
    }

    /// v0.16 §5: a place put back holds like any other. Back in chat 3, a
    /// reply streams below, the person scrolls on (the first scroll after
    /// the restore is not undone), and a space and back keeps the reply.
    func testAPlacePutBackHoldsThroughADeltaAScrollAndASpace() throws {
        let model = try model(chats: [3, 5])
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        let left = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        model.selected = 5
        spin()
        model.selected = 3
        spin()
        let three = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let back = Hosted(window: hosted.window, host: hosted.host, scroll: three)
        let stream = streaming(model)
        stream(3)
        spin()
        let streamed = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(streamed.text, left.text, "a reply streaming below leaves it")
        XCTAssertEqual(streamed.dy, left.dy, accuracy: 2)
        Self.wheel(three, pixels: 200)
        spin(0.05)
        let scrolled = try XCTUnwrap(Self.topReply(in: three))
        spin(1.0)
        let held = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(held.text, scrolled.text, "the person's scroll holds")
        XCTAssertEqual(held.dy, scrolled.dy, accuracy: 2)
        resize(back, from: 900, to: 640)
        resize(back, from: 640, to: 900)
        let after = try XCTUnwrap(Self.topReply(in: three))
        // The reply only: with a question's bubble at the top, SwiftUI's own
        // anchoring moves the reply by up to a bubble's height across the
        // reflow, the same with no restore (23 pt seen without the switch).
        XCTAssertEqual(after.text, scrolled.text, "a space and back keeps it")
    }

    /// v0.16 §5 with the dock (AO1): at the bottom, a card docking over the
    /// composer shortens the transcript, and its leaving lengthens it; the
    /// conversation stays at its newest message through both.
    func testAtTheBottomACardDockingAndLeavingKeepsTheBottom() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        XCTAssertTrue(atBottom(hosted))
        model.apply(.cardAsk(CardAsk(
            chat: 3, id: "card-p", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/acme/a.md", input: [:]), questions: nil, form: nil, seq: 81)))
        spin()
        XCTAssertNotNil(model.dockedCard(for: 3))
        XCTAssertLessThan(hosted.scroll.frame.height, 500, "the dock took room from the transcript")
        XCTAssertTrue(atBottom(hosted), "at the bottom with the card docked")
        model.apply(.cardCancel(CardCancel(chat: 3, id: "card-p", reason: "turn stopped", seq: 82)))
        spin()
        XCTAssertNil(model.dockedCard(for: 3))
        XCTAssertTrue(atBottom(hosted), "at the bottom when it leaves")
    }

    /// Fix round 1 (review I1): after a place is put back, the person pages
    /// up by key (no scroll phase: the position does not move); a reply
    /// streaming next and a space and back leave the paged-to reply at the
    /// top, not the row the restore scrolled to.
    func testAfterAPlaceIsPutBackAKeyScrollHoldsThroughAStreamAndASpace() throws {
        _ = NSApplication.shared
        let model = try model(chats: [3, 5])
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        model.selected = 5
        spin()
        model.selected = 3
        spin()
        let three = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let back = Hosted(window: hosted.window, host: hosted.host, scroll: three)
        let restored = try XCTUnwrap(Self.topReply(in: three))
        // Far enough that the row the restore scrolled to leaves the screen.
        for _ in 0..<2 {
            try animatedKey(116, "\u{F72C}", in: back, to: three.contentView.bounds.origin.y - 450)
            spin(0.4)
        }
        let paged = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertNotEqual(paged.text, restored.text, "paged up")
        let stream = streaming(model)
        stream(2)
        spin()
        let streamed = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(streamed.text, paged.text, "a reply streaming below leaves the paged-to reply at the top")
        XCTAssertEqual(streamed.dy, paged.dy, accuracy: 2)
        resize(back, from: 900, to: 640)
        resize(back, from: 640, to: 900)
        let after = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(after.text, paged.text, "and a space and back keeps it")
    }

    /// Fix round 1: scrolled up, a card docking over the composer (the
    /// transcript shortened from below) leaves the person's place.
    func testScrolledUpACardDockingHoldsThePlace() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let height = try XCTUnwrap(hosted.scroll.documentView).frame.height
        for _ in 0..<60 where clip.bounds.origin.y > height / 3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        model.apply(.cardAsk(CardAsk(
            chat: 3, id: "card-p", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/acme/a.md", input: [:]), questions: nil, form: nil, seq: 81)))
        spin()
        XCTAssertNotNil(model.dockedCard(for: 3))
        let after = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        XCTAssertFalse(atBottom(hosted), "not pulled to the end")
        XCTAssertEqual(after.text, before.text, "the same reply at the top")
        XCTAssertEqual(after.dy, before.dy, accuracy: 4, "at the same point in it")
    }

    // MARK: - v0.16 Task 10b: the content or the view changing size at a turn's end
    //
    // GUARDS, not proofs. The field report (v0.15.0, 11-02 item 11): the
    // pane suddenly shows a large empty space, a small scroll up brings the
    // conversation back. Each shape below (the workflow box, the tray, a
    // docked card and the working line leaving at a turn's end, a
    // background workflow finishing later, the tray folding itself, a
    // transcript read again shorter, mixed rows that throw off the lazy
    // stack's estimate, the turn ending mid-scroll, at the bottom by the
    // app's edge target and after the person's own scroll back) passed on
    // v0.15.0 and on v0.16 alike, hosted: AppKit clamps the view to the
    // content when the view grows or the content shrinks. The field
    // trigger is not reproduced here; these hold the end in view if a
    // change to the scroll ever stops doing so.

    /// Negative control for `assertTheEndIsInView`: scrolled up, it fails.
    func testGuardTheEndInViewCheckFailsWhenScrolledUp() throws {
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        Self.wheel(hosted.scroll, pixels: 600)
        spin(0.3)
        XCTExpectFailure("scrolled up, the last reply is below the view") {
            assertTheEndIsInView(hosted, "scrolled up")
        }
    }

    /// How far the visible area runs past the transcript's end (0 when it
    /// does not): the "large empty space" of the field report (11-02, item 11).
    private static func emptyBelow(_ scroll: NSScrollView) -> CGFloat {
        let height = scroll.documentView?.frame.height ?? 0
        return max(0, scroll.contentView.bounds.maxY - height)
    }

    /// How far below the last drawn reply the visible area ends: the last
    /// row is a reply, so a big gap here is an empty view under the
    /// conversation even when the document view is taller than its rows.
    private static func gapBelowLastReply(_ scroll: NSScrollView) -> CGFloat? {
        guard let document = scroll.documentView else { return nil }
        var lowest: CGFloat?
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, !text.isHidden, !text.string.isEmpty {
                let frame = text.convert(text.bounds, to: document)
                lowest = max(lowest ?? frame.maxY, frame.maxY)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(document)
        return lowest.map { scroll.contentView.bounds.maxY - $0 }
    }

    /// The last row in view and no empty space under it.
    private func assertTheEndIsInView(_ hosted: Hosted, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let scroll = try? XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let view = scroll ?? hosted.scroll
        XCTAssertLessThanOrEqual(Self.emptyBelow(view), 1, "\(what): no empty space past the end", file: file, line: line)
        let gap = Self.gapBelowLastReply(view)
        XCTAssertNotNil(gap, "\(what): a reply drawn", file: file, line: line)
        // The bottom spacer, the stack's padding and the working line's gap.
        XCTAssertLessThan(gap ?? .infinity, 120, "\(what): the last reply at the bottom of the view", file: file, line: line)
        XCTAssertGreaterThan(gap ?? -.infinity, -40, "\(what): the last reply not cut off below", file: file, line: line)
    }

    /// A turn as the gateway sends it, the seqs after the history's.
    @MainActor
    private final class Turn {
        let model: AppModel
        let turn: Int
        var seq: Int
        private let spin: (Double) -> Void

        init(_ model: AppModel, turn: Int = 41, seq: Int = 200, spin: @escaping (Double) -> Void) {
            self.model = model
            self.turn = turn
            self.seq = seq
            self.spin = spin
        }

        private func next() -> Int { seq += 1; return seq }

        func start() {
            model.apply(.turnStarted(TurnStarted(chat: 3, turn: turn, seq: next())))
            model.apply(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan", seq: next())))
            model.apply(.chatState(ChatState(chat: 3, state: .working, seq: next())))
            spin(0.2)
        }

        func text(_ text: String, times: Int = 1) {
            for _ in 0..<times {
                model.apply(.textDelta(TextDelta(chat: 3, turn: turn, text: text, seq: next())))
                spin(0.05)
            }
        }

        func tool(_ id: String, finished: Bool) {
            model.apply(.toolStarted(ToolStarted(
                chat: 3, turn: turn, toolUseId: id, tool: "Read", summary: "/tmp/demo/notes-\(id).md", input: [:], seq: next())))
            if finished {
                model.apply(.toolFinished(ToolFinished(chat: 3, turn: turn, toolUseId: id, ok: true, summary: "read", seq: next())))
            }
            spin(0.05)
        }

        func agents(_ ids: [String], workflow: String? = nil) {
            for (index, id) in ids.enumerated() {
                model.apply(.toolStarted(ToolStarted(
                    chat: 3, turn: turn, toolUseId: "t-\(id)", tool: "Task", summary: "Agent \(id)", input: [:], seq: next())))
                model.apply(.agentStarted(AgentStarted(
                    chat: 3, turn: turn, id: id, toolUseId: "t-\(id)", description: "Checking the Acme notes, part \(index + 1)",
                    kind: "subagent", workflowId: workflow, phase: workflow == nil ? nil : .index(index % 3),
                    background: workflow == nil ? nil : true, seq: next())))
            }
            spin(0.1)
        }

        func workflow(_ id: String) {
            model.apply(.workflowStarted(WorkflowStarted(
                chat: 3, turn: turn, id: id, name: "Acme review", phases: ["Review", "Verify", "Report"], seq: next())))
            model.apply(.workflowPhase(WorkflowPhase(chat: 3, id: id, index: 0, state: .running, seq: next())))
            spin(0.1)
        }

        func finishAgents(_ ids: [String]) {
            for id in ids {
                model.apply(.agentFinished(AgentFinished(chat: 3, id: id, outcome: .done, summary: "Done.", seq: next())))
            }
        }

        func finishWorkflow(_ id: String) {
            for index in 0..<3 {
                model.apply(.workflowPhase(WorkflowPhase(chat: 3, id: id, index: index, state: .done, seq: next())))
            }
            model.apply(.workflowFinished(WorkflowFinished(chat: 3, id: id, outcome: .done, summary: "Reviewed.", seq: next())))
        }

        /// The turn ends with nothing from the person: its marker, then idle.
        func end() {
            model.apply(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done, seq: next())))
            model.apply(.chatState(ChatState(chat: 3, state: .idle, seq: next())))
        }
    }

    private static let line = " Another long line of the reply, streamed in as it is written for Sam and Priya."

    /// Task 10b: at the bottom, a workflow runs (its box, 290 pt, on the
    /// composer) while the reply streams; the turn ends with the person
    /// doing nothing, the box leaves, and the view grows by its height.
    func testGuardAtTheBottomAWorkflowBoxLeavingAtATurnsEndLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.workflow("w")
        turn.agents(["a", "b", "c"], workflow: "w")
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        spin()
        XCTAssertNotNil(model.agentActivity[3]?.liveWorkflow, "the workflow box is up")
        XCTAssertTrue(atBottom(hosted), "following the reply")
        let before = hosted.scroll.frame.height
        turn.finishAgents(["a", "b", "c"])
        turn.finishWorkflow("w")
        turn.text(Self.line)
        turn.end()
        spin()
        XCTAssertNil(model.agentActivity[3]?.liveWorkflow, "the box left")
        XCTAssertGreaterThan(hosted.scroll.frame.height, before + 100, "the view grew by the box")
        assertTheEndIsInView(hosted, "after the turn ended")
    }

    /// Task 10b: the same with the tray (three agents, open) on the composer.
    func testGuardAtTheBottomTheAgentTrayLeavingAtATurnsEndLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.agents(["a", "b", "c"])
        model.setTrayCollapsed(false, chat: 3)
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        spin()
        XCTAssertTrue(model.agentActivity[3]?.showsTray ?? false, "the tray is up")
        XCTAssertTrue(atBottom(hosted), "following the reply")
        turn.finishAgents(["a", "b", "c"])
        turn.text(Self.line)
        turn.end()
        spin()
        assertTheEndIsInView(hosted, "after the turn ended")
    }

    /// Task 10b: tool rows and a docked permission card at the bottom; the
    /// turn ends (the card cancelled, the working line gone) at once.
    func testGuardAtTheBottomADockedCardAndTheWorkingLineLeavingAtATurnsEndLeaveTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        for index in 0..<6 { turn.tool("r\(index)", finished: true) }
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 4)
        turn.tool("w0", finished: false)
        model.apply(.cardAsk(CardAsk(
            chat: 3, id: "card-p", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/acme/a.md", input: [:]), questions: nil, form: nil,
            seq: turn.seq + 1)))
        turn.seq += 1
        spin()
        XCTAssertNotNil(model.dockedCard(for: 3))
        XCTAssertTrue(atBottom(hosted), "at the bottom with the card docked")
        model.apply(.cardCancel(CardCancel(chat: 3, id: "card-p", reason: "turn stopped", seq: turn.seq + 1)))
        turn.seq += 1
        turn.text(" The end.")
        turn.end()
        spin()
        XCTAssertNil(model.dockedCard(for: 3))
        assertTheEndIsInView(hosted, "after the turn ended")
    }

    /// Task 10b: a long streamed reply read again shorter (the transcript
    /// re-sent, as on a reconnect): the content drops by thousands of points
    /// while the view sits at its old end.
    func testGuardAtTheBottomATranscriptReadAgainShorterLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(String(repeating: Self.line, count: 8), times: 10)
        spin()
        XCTAssertTrue(atBottom(hosted), "following the reply")
        let tall = try XCTUnwrap(hosted.scroll.documentView).frame.height
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        var events: [ServerMessage] = []
        var seq = 0
        for number in 1...41 {
            seq += 1
            events.append(.userText(UserText(chat: 3, turn: number, text: "Question \(number) from Jordan", seq: seq)))
            seq += 1
            events.append(.textDelta(TextDelta(chat: 3, turn: number, text: "Answer \(number). \(reply)", seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        model.apply(.chatState(ChatState(chat: 3, state: .idle, seq: 400)))
        spin()
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        XCTAssertLessThan(try XCTUnwrap(scroll.documentView).frame.height, tall - 300, "the content got shorter")
        assertTheEndIsInView(hosted, "after the shorter transcript")
    }

    /// Task 10b: scrolled up a little (past the bottom's slack) while the
    /// workflow box is up; the turn ends and the box leaves. The view grows
    /// below the person's place: no empty space past the end.
    func testGuardScrolledSlightlyUpAWorkflowBoxLeavingAtATurnsEndLeavesNoEmptySpace() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.workflow("w")
        turn.agents(["a", "b", "c"], workflow: "w")
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        spin()
        XCTAssertTrue(atBottom(hosted))
        // Twice: SwiftUI puts the first scroll after the app's scroll to the bottom back once.
        Self.wheel(hosted.scroll, pixels: 40)
        spin(0.1)
        Self.wheel(hosted.scroll, pixels: 40)
        spin(0.4)
        XCTAssertFalse(atBottom(hosted), "scrolled up a little")
        turn.finishAgents(["a", "b", "c"])
        turn.finishWorkflow("w")
        turn.end()
        spin()
        // The view grows by more than the person was above the end: the end
        // comes into view, with no empty space below it.
        assertTheEndIsInView(hosted, "after the turn ended")
    }

    /// The person scrolls up, then back down to the end by wheel: the
    /// position is the row at the top now, not the bottom edge (spike 2).
    private func scrollUpAndBack(_ hosted: Hosted) {
        for _ in 0..<3 {
            Self.wheel(hosted.scroll, pixels: 300)
            spin(0.05)
        }
        spin(0.3)
        XCTAssertFalse(atBottom(hosted), "scrolled up")
        for _ in 0..<12 where !atBottom(hosted) {
            Self.wheel(hosted.scroll, pixels: -300)
            spin(0.05)
        }
        spin(0.3)
        XCTAssertTrue(atBottom(hosted), "back at the end by wheel")
    }

    /// Task 10b: the turn ends while its workflow runs on in the background
    /// (its agents are background ones), so the box stays; the person
    /// scrolled up and back to the end meanwhile. Later the workflow
    /// finishes, with nothing from the person and no new transcript item:
    /// the box leaves and the view grows by its height.
    func testGuardABackgroundWorkflowFinishingAfterTheTurnAtTheBottomLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.workflow("w")
        turn.agents(["a", "b", "c"], workflow: "w")
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        turn.end()
        spin()
        XCTAssertNotNil(model.agentActivity[3]?.liveWorkflow, "the box stays while the workflow runs")
        XCTAssertTrue(atBottom(hosted))
        scrollUpAndBack(hosted)
        let before = hosted.scroll.frame.height
        turn.finishAgents(["a", "b", "c"])
        turn.finishWorkflow("w")
        spin()
        XCTAssertNil(model.agentActivity[3]?.liveWorkflow, "the box left")
        XCTAssertGreaterThan(hosted.scroll.frame.height, before + 100, "the view grew by the box")
        assertTheEndIsInView(hosted, "after the workflow finished")
    }

    /// Task 10b: the same, the app having kept the bottom itself (no scroll
    /// by the person since the turn began).
    func testGuardABackgroundWorkflowFinishingAfterTheTurnLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.workflow("w")
        turn.agents(["a", "b", "c"], workflow: "w")
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        turn.end()
        spin()
        XCTAssertTrue(atBottom(hosted))
        turn.finishAgents(["a", "b", "c"])
        turn.finishWorkflow("w")
        spin()
        XCTAssertNil(model.agentActivity[3]?.liveWorkflow, "the box left")
        assertTheEndIsInView(hosted, "after the workflow finished")
    }

    /// Task 10b: the tray, open, at the bottom after the person scrolled up
    /// and back; its agents finish before the turn does, so it folds itself
    /// to one line (no new transcript item) and the view grows.
    func testGuardTheAgentTrayFoldingItselfAtTheBottomLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.agents(["a", "b", "c", "d", "e"])
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        spin()
        XCTAssertFalse(model.agentActivity[3]?.isTrayCollapsed ?? true, "the tray is open")
        scrollUpAndBack(hosted)
        let before = hosted.scroll.frame.height
        turn.finishAgents(["a", "b", "c", "d", "e"])
        spin()
        XCTAssertTrue(model.agentActivity[3]?.isTrayCollapsed ?? false, "the tray folded itself")
        XCTAssertGreaterThan(hosted.scroll.frame.height, before + 40, "the view grew")
        assertTheEndIsInView(hosted, "after the tray folded")
    }

    /// Task 10b: a transcript of mixed rows, as a working session has: per
    /// turn a dozen tool rows (30 pt each) and a reply of very different
    /// length, so the lazy stack's estimate for rows not yet laid out is
    /// far off. At the bottom (scrolled up and back first), a turn of tool
    /// rows ends, then the column narrows and widens.
    func testGuardWithMixedRowsATurnOfToolRowsEndingAtTheBottomLeavesTheEndInView() throws {
        let model = try model()
        var events: [ServerMessage] = []
        var seq = 0
        let long = String(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long. ", count: 60)
        for number in 1...40 {
            seq += 1
            events.append(.userText(UserText(chat: 3, turn: number, text: "Question \(number) from Jordan", seq: seq)))
            for index in 0..<12 {
                seq += 1
                events.append(.toolStarted(ToolStarted(
                    chat: 3, turn: number, toolUseId: "h\(number)-\(index)", tool: "Read",
                    summary: "/tmp/demo/notes-\(index).md", input: [:], seq: seq)))
                seq += 1
                events.append(.toolFinished(ToolFinished(
                    chat: 3, turn: number, toolUseId: "h\(number)-\(index)", ok: true, summary: "read", seq: seq)))
            }
            seq += 1
            events.append(.textDelta(TextDelta(
                chat: 3, turn: number, text: "Answer \(number). " + (number % 3 == 0 ? long : "Short."), seq: seq)))
            seq += 1
            events.append(.turnFinished(TurnFinished(chat: 3, turn: number, outcome: .done, seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        XCTAssertTrue(atBottom(hosted), "opens at the end")
        scrollUpAndBack(hosted)
        let turn = Turn(model, seq: 2000, spin: { self.spin($0) })
        turn.start()
        for index in 0..<10 { turn.tool("n\(index)", finished: false) }
        turn.text("Answer 41." + Self.line, times: 1)
        for index in 0..<10 {
            model.apply(.toolFinished(ToolFinished(chat: 3, turn: 41, toolUseId: "n\(index)", ok: true, summary: "read", seq: turn.seq + 1)))
            turn.seq += 1
        }
        turn.text(" Done.")
        turn.end()
        spin()
        assertTheEndIsInView(hosted, "after the turn ended")
        resize(hosted, from: 900, to: 640)
        assertTheEndIsInView(hosted, "beside a space")
        resize(hosted, from: 640, to: 900)
        assertTheEndIsInView(hosted, "back in Work")
    }

    /// Task 10b: at the bottom after the person scrolled up and back (the
    /// position a row, not the edge), the transcript is read again shorter.
    func testGuardAfterAScrollBackToTheEndATranscriptReadAgainShorterLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(String(repeating: Self.line, count: 8), times: 10)
        turn.end()
        spin()
        scrollUpAndBack(hosted)
        let reply = "Answer 41. Short now."
        var events: [ServerMessage] = []
        var seq = 0
        for number in 1...41 {
            seq += 1
            events.append(.userText(UserText(chat: 3, turn: number, text: "Question \(number) from Jordan", seq: seq)))
            seq += 1
            events.append(.textDelta(TextDelta(chat: 3, turn: number, text: number == 41 ? reply : "Answer \(number). Short.", seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        spin()
        assertTheEndIsInView(hosted, "after the shorter transcript")
    }

    /// Task 10b: the turn ends (the working line goes, the marker comes)
    /// while the person's trackpad scroll is still under way at the end (a
    /// live scroll: the app does not follow, the readings are the person's).
    func testGuardATurnEndingDuringTheLastOfAScrollToTheEndLeavesTheEndInView() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let turn = Turn(model, spin: { self.spin($0) })
        turn.start()
        turn.workflow("w")
        turn.agents(["a", "b"], workflow: "w")
        for index in 0..<6 { turn.tool("r\(index)", finished: true) }
        turn.text("Answer 41." + Self.line, times: 1)
        turn.text(Self.line, times: 6)
        spin()
        for _ in 0..<3 { Self.wheel(hosted.scroll, pixels: 300); spin(0.05) }
        spin(0.3)
        let scroll = hosted.scroll
        let clip = scroll.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for _ in 0..<12 where !atBottom(hosted) {
            let end = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(end, clip.bounds.origin.y + 200)))
            scroll.reflectScrolledClipView(clip)
            center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            spin(0.03)
        }
        // Still in the scroll: the turn ends, its box leaves.
        turn.finishAgents(["a", "b"])
        turn.finishWorkflow("w")
        turn.end()
        spin(0.1)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        spin()
        assertTheEndIsInView(hosted, "after the turn ended mid-scroll")
    }
}

// MARK: - v0.26 (PORT-12, ZG3): conversation markers, hosted

extension ConversationRoundTripTests {
    private func probe() {
        ConversationProbe.enabled = true
        ConversationProbe.rows = [:]
        ConversationProbe.railShown = [:]
        addTeardownBlock { @MainActor in
            ConversationProbe.enabled = false
            ConversationProbe.rows = [:]
            ConversationProbe.railShown = [:]
        }
    }

    /// The id of the `n`th (1-based) person message in `chat`'s transcript.
    private func personMessage(_ n: Int, in model: AppModel, chat: Int = 3) throws -> String {
        let users = (model.transcripts[chat] ?? []).filter { if case .userText = $0 { true } else { false } }
        return try XCTUnwrap(users.dropFirst(n - 1).first).id
    }

    private func frame(_ id: String, chat: Int = 3) -> CGRect? { ConversationProbe.rows[chat]?.frames[id] }

    func testClickingAMarkerScrollsToTheMessageAndHighlightsIt() throws {
        probe()
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        XCTAssertTrue(atBottom(hosted))
        XCTAssertEqual(ConversationProbe.railShown[3], true)
        let third = try personMessage(3, in: model)
        model.jumpToMessage(third, chat: 3)
        spin(0.5)
        let row = try XCTUnwrap(frame(third), "the message's row is laid out")
        XCTAssertEqual(row.minY, ConversationView.topInset, accuracy: 1)
        XCTAssertEqual(model.highlightedMessage[3], third)
        XCTAssertTrue(ConversationProbe.inView[3]?.contains(third) == true, "its mark reads as in view")
        XCTAssertFalse(ConversationProbe.inView[3]?.contains(try personMessage(40, in: model)) == true)
        spin(1.0)
        XCTAssertNil(model.highlightedMessage[3], "the highlight is brief")
        XCTAssertEqual(try XCTUnwrap(frame(third)).minY, ConversationView.topInset, accuracy: 1, "and the place holds")
    }

    func testAfterAJumpAStreamingReplyDoesNotPullDown() throws {
        probe()
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let third = try personMessage(3, in: model)
        model.jumpToMessage(third, chat: 3)
        spin(0.5)
        for step in 1...8 {
            model.apply(.textDelta(TextDelta(chat: 3, turn: 40, text: " More of the reply, part \(step).", seq: 80 + step)))
            spin(0.05)
        }
        spin()
        XCTAssertFalse(atBottom(hosted))
        XCTAssertEqual(try XCTUnwrap(frame(third)).minY, ConversationView.topInset, accuracy: 2)
    }

    func testEachConversationKeepsItsPlaceAfterAJump() throws {
        probe()
        let model = try model(chats: [3, 5])
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        let third = try personMessage(3, in: model)
        model.jumpToMessage(third, chat: 3)
        spin(0.5)
        let before = try XCTUnwrap(Self.topReply(in: hosted.scroll))
        model.selected = 5
        spin()
        model.selected = 3
        spin()
        let three = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        let after = try XCTUnwrap(Self.topReply(in: three))
        XCTAssertEqual(after.text, before.text, "the same reply at the top")
        XCTAssertEqual(after.dy, before.dy, accuracy: 2, "at the same point in it")
    }

    func testAJumpInAnotherChatDoesNothingHere() throws {
        probe()
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        model.jumpToMessage(try personMessage(3, in: model), chat: 9)
        spin(0.4)
        XCTAssertTrue(atBottom(hosted))
    }

    /// Review M2: the rail takes the pointer only over its stack; elsewhere in the margin a
    /// point lands in the transcript's scroll view (wheel, drag-select and clicks reach it).
    func testOutsideTheStackTheMarginIsTheTranscripts() throws {
        let model = try model()
        let hosted = try host(model, width: 900)
        defer { hosted.window.close() }
        func landsInTranscript(_ y: CGFloat) -> Bool {
            guard let hit = hosted.host.hitTest(NSPoint(x: 20, y: y)) else { return false }
            return hit === hosted.scroll || hit.isDescendant(of: hosted.scroll)
        }
        // The transcript's frame in the window (the point `hitTest` takes is in the host's superview's).
        let area = hosted.scroll.convert(hosted.scroll.bounds, to: nil)
        XCTAssertTrue(landsInTranscript(area.maxY - 20), "an end of the margin, far from the stack")
        XCTAssertTrue(landsInTranscript(area.minY + 20), "the other end")
        XCTAssertFalse(landsInTranscript(area.midY), "on the stack, the rail takes it")
        let beside = hosted.host.hitTest(NSPoint(x: 120, y: area.midY))
        XCTAssertTrue(beside.map { $0 === hosted.scroll || $0.isDescendant(of: hosted.scroll) } == true, "beside the rail")
    }

    /// At the minimum window width the rail's frame lies inside the side inset.
    func testTheRailStaysInsideTheSideInsetAtTheMinimumWidth() throws {
        let model = try model()
        let settings = Settings(defaults: defaults)
        final class Box { var frame = CGRect.zero }
        let box = Box()
        let width = min(ColumnWidths.focusConversationMinimum, ColumnWidths.conversationMinimum)  // the narrowest chat pane
        let rail = MarkerRail(
            markers: (1...5).map { ConversationMarker(id: "m\($0)", text: "Message \($0)", at: nil) },
            inView: MarkersInView(), onJump: { _ in })
            .padding(.leading, ConversationView.railLeading)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
            .frame(width: width, height: 600, alignment: .topLeading)
        let host = NSHostingView(rootView: rail.environmentObject(model).environmentObject(settings))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        spin(0.2)
        XCTAssertGreaterThan(box.frame.width, 0)
        XCTAssertGreaterThanOrEqual(box.frame.minX, 0)
        XCTAssertLessThanOrEqual(box.frame.maxX, ConversationView.sideInset, "the rail stays in the margin")
    }

    func testNoRailBelowThreePersonMessages() throws {
        probe()
        let model = try model()
        model.apply(.chatList(ChatList(chats: [3, 7].map { ChatSummary(
            chat: $0, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z") })))
        var events: [ServerMessage] = []
        for turn in 1...2 {
            events.append(.userText(UserText(chat: 7, turn: turn, text: "Question \(turn)", seq: turn * 2 - 1)))
            events.append(.textDelta(TextDelta(chat: 7, turn: turn, text: "Answer \(turn).", seq: turn * 2)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 7, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 7)))
        model.selected = 7
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView: ConversationView(chat: 7)
            .environmentObject(model).environmentObject(settings)
            .environmentObject(ReadAloud(settings: settings)).environmentObject(Dictation(settings: settings)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        spin()
        XCTAssertEqual(ConversationProbe.railShown[7], false)
    }

    /// v0.26.1 (found live): the marker rail's hover area sat under the
    /// transcript's scroll view and never saw the pointer. The pointer over a
    /// mark must reach the rail, and a hover there must show its tip.
    func testThePointerOverTheMarkerRailReachesIt() throws {
        _ = NSApplication.shared
        let hosted = try host(try model(), width: 900)
        defer { hosted.window.close() }
        spin(0.3)
        func find(_ view: NSView) -> RailPointerView? {
            if let rail = view as? RailPointerView { return rail }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let rail = try XCTUnwrap(find(hosted.host), "the rail's pointer area")
        XCTAssertGreaterThan(rail.bounds.height, 0)
        let middle = NSPoint(x: rail.bounds.midX, y: rail.bounds.midY)
        let inWindow = rail.convert(middle, to: nil)
        let content = try XCTUnwrap(hosted.window.contentView)
        let hit = try XCTUnwrap(content.hitTest(try XCTUnwrap(content.superview).convert(inWindow, from: nil)))
        XCTAssertTrue(hit === rail, "the pointer over the rail reaches it, not \(type(of: hit))")
    }
}