import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.16 §9.1, §9.6: the sidebar's top section (the conversation list
/// with its open card, History) fits the 260-pt sidebar at 100% and 150%
/// text, in Main and in a thread, and so does the toolbar. Laid out offscreen in a window: a view wider than
/// its column reports a width larger than the one it was given, which is
/// what pushed the sidebar's section off its left margin.
@MainActor
final class ThreadFitTests: XCTestCase {

    private static let created = "2026-11-02T12:00:00Z"

    /// A model whose window shows Thread 1, with Main and Thread 2 as rows.
    private func modelInThread() -> AppModel {
        let model = modelWithThreads()
        model.open(chat: 5)
        // Thread 2 finished while the window was in Thread 1: its row has
        // the widest status, the dot and New reply (§9.3).
        model.newThreadReplies = [6]
        return model
    }

    /// A model whose window shows Main (its card has Log session and New),
    /// with Thread 1 on New reply and Thread 2 on Needs you as rows.
    private func modelInMain() -> AppModel {
        let model = modelWithThreads()
        model.open(chat: 3)
        model.newThreadReplies = [5]
        model.apply(.chatList(ChatList(chats: [
            Self.main(), Self.thread(5, slot: 1), Self.thread(6, slot: 2, state: .waitingOnYou),
        ])))
        return model
    }

    private static func main() -> ChatSummary {
        var main = ChatSummary(chat: 3, folder: "/tmp/acme", alias: nil, state: .idle, created: created)
        main.title = "Mobile login screen UI and its notes page"
        main.lastReply = created
        main.contextPercent = 64
        return main
    }

    private func modelWithThreads() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: ["log"],
            capabilities: ["sessions", "files", "threads.v1"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [Self.main(), Self.thread(5, slot: 1), Self.thread(6, slot: 2)])))
        return model
    }

    private static func thread(_ chat: Int, slot: Int, state: ChatStateWord = .idle) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: state, created: created)
        summary.title = "Notes app login flow and the log-out panel"
        summary.parent = 3
        summary.lastReply = created
        summary.contextPercent = 7
        summary.thread = ThreadInfo(
            label: "Thread \(slot)", slot: slot, parent: 3, brief: "Build the notes page.", files: [], openedAt: created)
        return summary
    }

    /// Where the measured views report their laid-out widths.
    final class Widths {
        var byName: [String: CGFloat] = [:]
    }

    /// Lays `view` out at `width` in a borderless window and returns what
    /// the views marked with `measured(_:into:)` reported.
    private func layOut<V: View>(_ view: V, width: CGFloat, height: CGFloat = 600, widths: Widths) {
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        window.close()
    }

    func testTheConversationListFitsTheDefaultSidebarInAThreadAt100And150Percent() throws {
        let model = modelInThread()
        XCTAssertEqual(model.sidebarCard?.chat, 5, "the window shows Thread 1")
        XCTAssertEqual(model.sidebarThreads.rows(now: Date()).map(\.status).last, .newReply)
        try assertSectionFits(model)
    }

    func testTheConversationListFitsTheDefaultSidebarInMainAt100And150Percent() throws {
        let model = modelInMain()
        XCTAssertEqual(model.sidebarCard?.chat, 3, "the window shows Main")
        let rows = model.sidebarThreads.rows(now: Date())
        XCTAssertEqual(rows.map(\.isOpen), [true, false, false])
        XCTAssertEqual(rows.dropFirst().map(\.status), [.newReply, .needsYou])
        try assertSectionFits(model)
    }

    func testTheOpenCardFitsItsColumnInAThreadAndInMainAt100And150Percent() throws {
        for (place, model) in [("Thread 1", modelInThread()), ("Main", modelInMain())] {
            let card = try XCTUnwrap(model.sidebarCard)
            // The card sits 8 pt in from each side of the sidebar.
            let column = ColumnWidths.sidebarDefault - 16
            for scale in [CGFloat(1), 1.5] {
                let widths = Widths()
                layOut(
                    SessionCard(summary: card)
                        .measured("card", into: widths)
                        .environmentObject(model)
                        .environment(\.textScale, scale),
                    width: column, widths: widths)
                let measured = try XCTUnwrap(widths.byName["card"], "\(place) laid out at \(scale)")
                XCTAssertLessThanOrEqual(measured, column, "\(place)'s card and its two buttons fit at \(Int(scale * 100))%")
            }
        }
    }

    /// The section, laid out in the default sidebar, is no wider than it.
    private func assertSectionFits(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let sidebar = ColumnWidths.sidebarDefault
        XCTAssertEqual(sidebar, 260)
        for scale in [CGFloat(1), 1.5] {
            let widths = Widths()
            layOut(
                SessionSidebar()
                    .measured("section", into: widths)
                    .environmentObject(model)
                    .environment(\.textScale, scale),
                width: sidebar, widths: widths)
            let section = try XCTUnwrap(widths.byName["section"], "laid out at \(scale)", file: file, line: line)
            XCTAssertLessThanOrEqual(
                section, sidebar, "the top section fits the sidebar at \(Int(scale * 100))%", file: file, line: line)
        }
    }

    /// The toolbar in a thread at the narrowest conversation column: its
    /// ideal width (every item at its full size, the switcher's name
    /// whole) fits, so nothing squeezes the switcher to "…".
    func testTheToolbarInAThreadFitsTheNarrowestConversationAt100And150Percent() {
        let model = modelInThread()
        for scale in [CGFloat(1), 1.5] {
            let host = NSHostingView(rootView: MainToolbar()
                .fixedSize()
                .environmentObject(model)
                .environment(\.textScale, scale))
            let ideal = host.fittingSize.width
            XCTAssertGreaterThan(ideal, 100, "laid out at \(scale)")
            XCTAssertLessThanOrEqual(
                ideal, ColumnWidths.conversationMinimum,
                "the toolbar fits a \(Int(ColumnWidths.conversationMinimum))-pt column at \(Int(scale * 100))%")
        }
    }
}

extension View {
    /// Reports this view's laid-out width under `name`.
    fileprivate func measured(_ name: String, into widths: ThreadFitTests.Widths) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.byName[name] = $0 }
    }
}
