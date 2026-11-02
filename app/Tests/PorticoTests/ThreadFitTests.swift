import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.16 §9.1: inside a thread, the sidebar's top section (the thread's
/// card, the rows under it, History) and the toolbar fit their width at
/// 100% and 150% text. Laid out offscreen in a window: a view wider than
/// its column reports a width larger than the one it was given, which is
/// what pushed the sidebar's section off its left margin.
@MainActor
final class ThreadFitTests: XCTestCase {

    private static let created = "2026-11-02T12:00:00Z"

    /// A model whose window shows Thread 1, with Main and Thread 2 as rows.
    private func modelInThread() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: ["log"],
            capabilities: ["sessions", "files", "threads.v1"], presentation: "single", canLog: true)))
        var main = ChatSummary(chat: 3, folder: "/tmp/acme", alias: nil, state: .idle, created: Self.created)
        main.title = "Mobile login screen UI and its notes page"
        main.lastReply = Self.created
        model.apply(.chatList(ChatList(chats: [main, Self.thread(5, slot: 1), Self.thread(6, slot: 2)])))
        model.open(chat: 5)
        return model
    }

    private static func thread(_ chat: Int, slot: Int) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: .idle, created: created)
        summary.title = "Notes app login flow and the log-out panel"
        summary.parent = 3
        summary.lastReply = created
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

    func testTheThreadsSidebarSectionFitsTheDefaultSidebarAt100And150Percent() throws {
        let model = modelInThread()
        XCTAssertEqual(model.sidebarCard?.chat, 5, "the window shows Thread 1")
        let sidebar = ColumnWidths.sidebarDefault
        for scale in [CGFloat(1), 1.5] {
            let widths = Widths()
            layOut(
                SessionSidebar()
                    .measured("section", into: widths)
                    .environmentObject(model)
                    .environment(\.textScale, scale),
                width: sidebar, widths: widths)
            let section = try XCTUnwrap(widths.byName["section"], "laid out at \(scale)")
            XCTAssertLessThanOrEqual(section, sidebar, "the top section fits the sidebar at \(Int(scale * 100))%")
        }
    }

    func testTheThreadCardFitsItsColumnAt100And150Percent() throws {
        let model = modelInThread()
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
            let measured = try XCTUnwrap(widths.byName["card"], "laid out at \(scale)")
            XCTAssertLessThanOrEqual(measured, column, "Log session and Close thread fit the card at \(Int(scale * 100))%")
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
