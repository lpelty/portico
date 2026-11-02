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

    /// §5 case 2 (v0.15 N2): at the end, inside a live scroll, SwiftUI
    /// puts its own offset back (the clip moves back 46 pt and forward
    /// again); that is not the person leaving the bottom, so the reply
    /// streaming next is still followed.
    func testSwiftUIsOwnOffsetRestoreAtTheEndIsNotScrolledUp() throws {
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

    /// §5 case 3 (v0.15 Task 2b round 4): a 4,000-word reply streamed in at
    /// the bottom, then the column narrowed 900 → 640: at the end, not short of it.
    func testALongStreamedReplyNarrowedAtTheBottomLandsAtTheEnd() throws {
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
}
