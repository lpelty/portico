import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// v0.15 task 7: the small waiting items.
@MainActor
final class SmallItemsV015Tests: XCTestCase {

    // MARK: - Obsidian file types

    func testObsidianOpensOnlyItsOwnFileTypes() {
        for path in ["/v/a.md", "/v/b.CANVAS", "/v/c.pdf", "/v/d.png", "/v/e.JPEG", "/v/f.svg", "/v/g.markdown", "/v/h.avif"] {
            XCTAssertTrue(Obsidian.opens(path: path), path)
        }
        for path in ["/v/e.html", "/v/f.htm", "/v/g.csv", "/v/noext", "/v/.md.bak"] {
            XCTAssertFalse(Obsidian.opens(path: path), path)
        }
    }

    // MARK: - CJK composition

    func testReturnWhileComposingSendsNothing() {
        var sends = 0
        XCTAssertEqual(InputBar.handleReturn(modifiers: [], composing: true, send: { sends += 1 }), .ignored)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(InputBar.handleReturn(modifiers: [], composing: false, send: { sends += 1 }), .handled)
        XCTAssertEqual(sends, 1)
    }

    // MARK: - 24-hour clock

    func testClockFollowsA24HourLocale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = SessionTime.parse("2026-10-28T16:12:00Z")!
        XCTAssertEqual(SessionTime.clock(date, calendar: calendar, locale: Locale(identifier: "en_GB")), "16:12")
        XCTAssertEqual(SessionTime.clock(date, calendar: calendar, locale: Locale(identifier: "de_DE")), "16:12")
        XCTAssertEqual(SessionTime.clock(date, calendar: calendar, locale: Locale(identifier: "en_US")), "4:12 PM")
    }

    // MARK: - Declined writes

    private func declinedWrite(_ id: String, _ path: String, seq: Int) -> [ServerMessage] {
        [
            .toolStarted(ToolStarted(chat: 1, turn: 1, toolUseId: id, tool: "Write", summary: path,
                                     input: ["file_path": .string(path)], seq: seq, ts: "2026-10-28T09:10:00Z")),
            .cardAnswered(CardAnswered(chat: 1, id: "card-\(id)", toolUseId: id, outcome: .declined, seq: seq + 1)),
            // The refusal comes back as the tool's result, which may read as ok.
            .toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: id, ok: true, summary: "", seq: seq + 2, ts: "2026-10-28T09:10:05Z")),
        ]
    }

    func testDeclinedWriteToAnExistingOrNewFileIsNotChanged() throws {
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("portico-small-\(UUID().uuidString).md")
        try "hello".write(to: existing, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: existing) }
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Portico.Settings(defaults: defaults))
        model.selected = 1
        for message in declinedWrite("a", existing.path, seq: 1) + declinedWrite("b", "/tmp/demo/test.csv", seq: 4) {
            model.apply(message)
        }
        let rows = (model.transcripts[1] ?? []).compactMap { item -> ToolRow? in
            if case .tool(let row) = item { return row } else { return nil }
        }
        XCTAssertEqual(rows.count, 2)
        for row in rows { XCTAssertFalse(AppModel.didWrite(row), row.summary) }
        XCTAssertEqual(model.changedFiles(chat: 1).map(\.path), [])
    }

    // MARK: - go(to:) giving up

    private func notices(_ model: AppModel) -> [String] {
        (model.transcripts[1] ?? []).compactMap { item in
            if case .notice(_, let text) = item { return text } else { return nil }
        }
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let due = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < due {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func newModel() -> AppModel {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Portico.Settings(defaults: defaults))
        model.outbound = { _ in }
        model.selected = 1
        return model
    }

    private func mark(on key: String) -> Mark {
        Mark(number: 1, page: MarkPage(key: key, name: "Elsewhere"), note: "", label: "x",
             locator: MarkLocator(path: "body", tag: "p", text: "x"), call: "c1")
    }

    func testGoToMarkGivesUpWithANoticeWhenNothingCanLoadThePage() async {
        let model = newModel()
        let agent = ViewerAgent(model: model)
        agent.markPageWait = .milliseconds(200)
        agent.goToMark(mark(on: "https://example.com/never"), chat: 1)
        let said = await waitFor { self.notices(model) == [ViewerAgent.markPageGaveUp] }
        XCTAssertTrue(said, "\(notices(model))")
        XCTAssertEqual(ViewerAgent.markPageGaveUp, "That page didn't load; the marks are kept for when it does.")
    }

    func testGoToMarkGivesUpWithANoticeWhenThePageNeverLoads() async {
        let model = newModel()
        let agent = ViewerAgent(model: model)
        agent.markPageWait = .milliseconds(300)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.close() }
        view.loadHTMLString("<p>here</p>", baseURL: URL(string: "https://example.com/here")!)
        _ = await waitFor { !view.isLoading }
        let load = WebPane.Load.url(URL(string: "https://example.com/here")!)
        agent.attach(view, showing: load, coordinator: coordinator, slot: .work)
        agent.goToMark(mark(on: "http://127.0.0.1:9/never"), chat: 1)
        let said = await waitFor { self.notices(model) == [ViewerAgent.markPageGaveUp] }
        XCTAssertTrue(said, "\(notices(model))")
    }
}
