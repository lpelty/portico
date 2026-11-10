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

    func testSynthesizedPhasedWheelsReachOnScrollPhaseChange() throws {
        _ = NSApplication.shared
        let hosted = try host(try model(varied: true), width: 900)
        defer { hosted.window.close() }
        let clip = hosted.scroll.contentView
        let before = clip.bounds.origin.y
        let phased = PhaseProbe.phased(scroll: hosted.scroll, chat: 3)
        let moved = abs(clip.bounds.origin.y - before)
        let names = ConversationProbe.phaseNames[3] ?? []
        print("PHASE-SPIKE phased=\(phased) names=\(names) moved=\(moved)")
        print("PHASE-SPIKE macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        XCTAssertTrue(moved >= 40 || !names.isEmpty, "the probe ran: the view moved or reported a phase")
    }
}
