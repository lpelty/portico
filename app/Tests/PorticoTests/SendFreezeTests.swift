import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.26.1: Portico froze (main thread 100%, a layout loop in the
/// transcript's row frames) right after a send in a long conversation
/// with real times (field report, 2026-11-09). Hosted: the real
/// `ConversationView`, a long restored conversation, then a send and a
/// streamed reply. Done means the run loop keeps turning.
@MainActor
final class SendFreezeTests: XCTestCase {
    private var defaults: UserDefaults!

    private func model(turns: Int) throws -> AppModel {
        let suite = "portico-freeze-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions", ChatHistory.timesCapability], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        var events: [ServerMessage] = []
        let start = Date().addingTimeInterval(-Double(turns) * 120)
        for turn in 1...turns {
            let at = ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(turn) * 120))
            events.append(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan " + String(repeating: "pasted context line. ", count: 100), ts: at)))
            for k in 0..<3 {
                let id = "t\(turn)-\(k)"
                events.append(.toolStarted(ToolStarted(chat: 3, turn: turn, toolUseId: id, tool: "Bash", summary: "ls -la step \(k)", input: [:], ts: at)))
                events.append(.toolFinished(ToolFinished(chat: 3, turn: turn, toolUseId: id, ok: true, summary: "done", ts: at)))
            }
            events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). \(reply)", ts: at)))
            events.append(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done, ts: at)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3)))
        return model
    }

    private struct Selected: View {
        @EnvironmentObject var model: AppModel
        var body: some View {
            if let chat = model.selected { ConversationView(chat: chat).id(chat) }
        }
    }

    private func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The person scrolls up as a wheel does: a live scroll of the clip view.
    private static func wheel(_ scroll: NSScrollView, pixels: CGFloat) {
        let clip = scroll.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.origin.y - pixels)))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 2000 { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    func testSendInALongConversationDoesNotFreeze() throws {
        let turns = Int(ProcessInfo.processInfo.environment["FREEZE_TURNS"] ?? "400")!
        ConversationProbe.enabled = true
        defer { ConversationProbe.enabled = false }
        let model = try model(turns: turns)
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(1)
        var seq = 1000
        model.sendMessage(chat: 3, text: "Please log the session")
        seq += 1
        model.apply(.turnStarted(TurnStarted(chat: 3, turn: turns + 1, seq: seq)))
        seq += 1
        model.apply(.userText(UserText(chat: 3, turn: turns + 1, text: "Please log the session", seq: seq)))
        spin(0.3)
        let t0 = Date()
        for i in 0..<40 {
            seq += 1
            if i % 8 == 0 {
                model.apply(.toolStarted(ToolStarted(chat: 3, turn: turns + 1, toolUseId: "live\(i)", tool: "Bash", summary: "step \(i)", input: [:], seq: seq)))
                seq += 1
                model.apply(.toolFinished(ToolFinished(chat: 3, turn: turns + 1, toolUseId: "live\(i)", ok: true, summary: "ok", seq: seq)))
                seq += 1
            }
            model.apply(.textDelta(TextDelta(chat: 3, turn: turns + 1, text: "word\(i) " + (i % 5 == 0 ? "\n\nA new paragraph of the reply that keeps growing. " : ""), seq: seq)))
            if (10..<30).contains(i), let scroll = Self.transcriptScroll(in: host) {
                let before = scroll.contentView.bounds.origin.y
                Self.wheel(scroll, pixels: 60)
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                let after = scroll.contentView.bounds.origin.y
                let bottom = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
                print("FREEZE wheel i=\(i) before=\(Int(before)) after=\(Int(after)) bottom=\(Int(bottom))")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        print("FREEZE readings=\(ConversationProbe.geometryReadings[3] ?? 0) corrections=\(ConversationProbe.bottomCorrections[3] ?? 0)")
        print("FREEZE turns=\(turns) 40 updates took \(Date().timeIntervalSince(t0))s")
        let r0 = ConversationProbe.geometryReadings[3] ?? 0
        spin(2)
        print("FREEZE idle 2s readings=\((ConversationProbe.geometryReadings[3] ?? 0) - r0)")
        window.close()
    }
}
