import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// D12: does SwiftUI's `onScrollPhaseChange` fire when a test feeds CGEvent
/// wheels with scroll-phase fields set? Passes on either answer; prints one
/// `PHASE-SPIKE` line recording it for this machine.
@MainActor
final class ScrollPhaseSpikeTests: XCTestCase {
    private var defaults: UserDefaults!

    private func model(chats: [Int] = [3], varied: Bool = false) throws -> AppModel {
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
                // `varied`: rows very unlike each other, as in the field (a
                // one-line answer, then one forty times as long), so the lazy
                // stack's estimate for rows not laid out is far off.
                let text = !varied ? reply
                    : turn % 3 == 0 ? Array(repeating: reply, count: 8).joined(separator: "\n\n") : "Done."
                events.append(.textDelta(TextDelta(chat: chat, turn: turn, text: "Answer \(turn). \(text)", seq: seq)))
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
        PhaseProbe.spin()
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: host), "the transcript's scroll view")
        return Hosted(window: window, host: host, scroll: scroll)
    }

    /// The tall scroll view: the transcript (the composer's editor scrolls too).
    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 2000 { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    func testSynthesizedPhasedWheelsReachOnScrollPhaseChange() throws {
        _ = NSApplication.shared
        let hosted = try host(try model(varied: true), width: 900)
        defer { hosted.window.close() }
        let result = PhaseProbe.run(scroll: hosted.scroll, chat: 3)
        let names = ConversationProbe.phaseNames[3] ?? []
        let offsets = result.offsets.map { Int($0.rounded()) }
        print("PHASE-SPIKE phased=\(result.phased) names=\(names) moved=\(result.moved) atBottomBefore=\(result.atBottomBefore) offsets=\(offsets)")
        print("PHASE-SPIKE macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        XCTAssertTrue(abs(result.moved) >= 40 || !names.isEmpty, "the probe ran: the view moved or reported a phase")
    }

    /// I3b (Ruling 16): the replay's envelope. A zero-delta wheel with scroll phase began,
    /// before a gesture run, and one with ended after it (momentum 0) put SwiftUI's phase
    /// into a non-idle one, so the view's `personScrolling` path runs (the `.sizeChanges`
    /// anchor off) while content streams mid-gesture, and the scrolled-up view holds.
    func testAZeroDeltaPhasedEnvelopeKeepsThePersonScrollingThroughADelta() throws {
        let shapes = (1...20).flatMap { turn in [
            EntryShape(id: "user:\(turn)", kind: .person, paragraphs: [48]),
            EntryShape(id: "assistant:\(turn)", kind: .reply, paragraphs: [300, 240, 180]),
        ] }
        let images = FileManager.default.temporaryDirectory.appendingPathComponent("portico-envelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: images) }
        let suite = "portico-envelope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try SyntheticConversation.model(chat: 9, shapes: shapes, images: images, defaults: defaults)
        let wasEnabled = ConversationProbe.enabled
        ConversationProbe.enabled = true
        defer { ConversationProbe.enabled = wasEnabled; ConversationProbe.phaseNames[9] = nil; ConversationProbe.rows[9] = nil }
        let hosted = try ReplayRunner.host(model, defaults: defaults, size: NSSize(width: 800, height: 600))
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        // Scrolled up (a key moves the view on every Mac; a synthesized wheel may not).
        ReplayRunner.key(hosted, .pageUp)
        ReplayRunner.spin(0.4)
        ReplayRunner.key(hosted, .pageUp)
        ReplayRunner.spin(0.6)
        let height = Double(hosted.scroll.documentView?.frame.height ?? 0)
        XCTAssertLessThan(Double(clip.bounds.maxY), height - 100, "scrolled up")

        var lines: [String] = []
        ScrollTrace.override = true
        ScrollTrace.sink = { lines.append($0) }
        defer { ScrollTrace.sink = nil; ScrollTrace.override = nil }
        ConversationProbe.phaseNames[9] = nil
        let before = Double(clip.bounds.origin.y)
        XCTAssertTrue(ReplayRunner.wheel(hosted, pixels: 0, phase: .began))
        ReplayRunner.spin(0.1)
        let began = ConversationProbe.phaseNames[9] ?? []
        for _ in 0..<6 {
            model.apply(.textDelta(TextDelta(chat: 9, turn: 40, text: String(repeating: " word", count: 120))))
            ReplayRunner.spin(0.05)
        }
        let mid = Double(clip.bounds.origin.y)
        let duringReads = lines.filter { $0.contains(" read chat=9 ") }
        XCTAssertTrue(ReplayRunner.wheel(hosted, pixels: 0, phase: .ended))
        ReplayRunner.spin(0.4)
        let names = ConversationProbe.phaseNames[9] ?? []
        print("ENVELOPE-SPIKE began=\(began) names=\(names) before=\(Int(before)) mid=\(Int(mid)) reads=\(duringReads.count) scrollingTrue=\(duringReads.filter { $0.contains("scrolling=true") }.count)")
        XCTAssertTrue(began.contains { $0 != "idle" }, "began put the phase out of idle: \(began)")
        XCTAssertFalse(duringReads.isEmpty, "the view read its geometry while the reply streamed")
        XCTAssertTrue(duringReads.allSatisfy { $0.contains("scrolling=true") }, "personScrolling all through the delta: \(duringReads)")
        XCTAssertEqual(mid, before, accuracy: 8, "the scrolled-up view held through the delta")
        XCTAssertEqual(names.last, "idle", "ended put the phase back to idle")
    }
}
