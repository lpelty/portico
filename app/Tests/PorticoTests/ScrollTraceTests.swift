import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// 0.43.3: the scroll trace's row, width, open and paint lines, for the
/// transcript that sticks while scrolling and the one blank until scrolled.
@MainActor
final class ScrollTraceTests: XCTestCase {
    func testARowLineSaysInAndHeightButNotAMove() {
        let frame = CGRect(x: 0, y: 100, width: 600, height: 80)
        XCTAssertEqual(
            ScrollTrace.rowLine(chat: 3, id: "assistant:1", old: nil, new: frame),
            "row chat=3 in id=assistant:1 h=80 y=100")
        XCTAssertNil(
            ScrollTrace.rowLine(chat: 3, id: "assistant:1", old: frame, new: frame.offsetBy(dx: 0, dy: -40)),
            "a scroll moves every row; only a height change is a line")
        XCTAssertEqual(
            ScrollTrace.rowLine(chat: 3, id: "assistant:1", old: frame, new: CGRect(x: 0, y: 60, width: 600, height: 950)),
            "row chat=3 height id=assistant:1 from=80 to=950 y=60")
    }

    private var defaults: UserDefaults!

    private func model() throws -> AppModel {
        let suite = "portico-trace-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        var events: [ServerMessage] = []
        for turn in 1...30 {
            events.append(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan about the Acme plan.")))
            events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). " + String(repeating: "Priya replied at length. ", count: 30))))
            events.append(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done)))
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

    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1000 { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    /// Hosts the conversation, scrolls it up once, and returns the trace's lines.
    private func traced(enabled: Bool) throws -> [String] {
        _ = NSApplication.shared
        var lines: [String] = []
        let wasEnabled = ScrollTrace.enabled
        ScrollTrace.enabled = enabled
        ScrollTrace.sink = { lines.append($0) }
        defer {
            ScrollTrace.enabled = wasEnabled
            ScrollTrace.sink = nil
        }
        let model = try model()
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        spin(1.2)
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: host))
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 1500)))
        scroll.reflectScrolledClipView(clip)
        spin(1.2)
        return lines
    }

    func testTracedTheRowsWidthAndWhatIsOnScreenAreWritten() throws {
        let lines = try traced(enabled: true)
        XCTAssertTrue(lines.contains { $0.contains(" open chat=3 rows=") }, "the open line")
        XCTAssertTrue(lines.contains { $0.contains(" width chat=3 from=") }, "the width line")
        XCTAssertTrue(lines.contains { $0.contains(" row chat=3 in id=") }, "rows laid out")
        XCTAssertTrue(lines.contains { $0.contains(" row chat=3 out id=") }, "rows dropped after the scroll")
        let paint = try XCTUnwrap(lines.last { $0.contains(" paint chat=3 ") }, "a paint line")
        XCTAssertFalse(paint.contains("rowsInView=0 "), paint)
        XCTAssertFalse(paint.contains("textViews=0 "), "the replies' text views are counted: \(paint)")
        XCTAssertFalse(lines.contains { $0.contains("Priya") || $0.contains("Jordan") }, "no message text in the trace")
    }

    func testUntracedNothingIsWritten() throws {
        XCTAssertEqual(try traced(enabled: false), [])
    }
}
