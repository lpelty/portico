import Foundation
import XCTest

@testable import Portico

/// v0.23: the viewer's comments controller, its per-file memory, the
/// relative times, and the Show comments toggle.
@MainActor
final class ViewerCommentsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "comments-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    final class FakeFocus: CommentsFocus {
        var focused = false
        var toggles = 0
        func isFocused(chat: Int) -> Bool { focused }
        func toggleFocus(chat: Int) { toggles += 1; focused.toggle() }
    }

    private func file(_ fixture: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.md")
        try Data(contentsOf: CommentFormatTests.fixturesDir.appendingPathComponent(fixture)).write(to: url)
        return url
    }

    func testMemoryKeepsOnlyOnPaths() {
        let d = defaults()
        CommentsMemory.set("/a.md", true, defaults: d)
        CommentsMemory.set("/b.md", true, defaults: d)
        CommentsMemory.set("/a.md", false, defaults: d)
        XCTAssertEqual(d.stringArray(forKey: CommentsMemory.key), ["/b.md"])
        XCTAssertFalse(CommentsMemory.isOn("/a.md", defaults: d))
        XCTAssertTrue(CommentsMemory.isOn("/b.md", defaults: d))
    }

    func testFileOpensOffUnlessLeftOn() throws {
        let d = defaults()
        let url = try file("list-after.md")
        let c = ViewerComments(defaults: d)
        c.show(file: url)
        XCTAssertFalse(c.shown)
        CommentsMemory.set(url.path, true, defaults: d)
        c.show(file: nil)
        c.show(file: url)
        XCTAssertTrue(c.shown)
    }

    func testTurningOnWidensTurningOffDoesNot() throws {
        let d = defaults()
        let c = ViewerComments(defaults: d)
        c.show(file: try file("para.md"))
        let focus = FakeFocus()
        c.setShown(true, chat: 1, focus: focus)
        XCTAssertTrue(c.shown)
        XCTAssertEqual(focus.toggles, 1)
        XCTAssertTrue(focus.focused)
        c.setShown(false, chat: 1, focus: focus)
        XCTAssertEqual(focus.toggles, 1, "off never narrows")
        focus.focused = true
        c.setShown(true, chat: 1, focus: focus)
        XCTAssertEqual(focus.toggles, 1, "already wide: no toggle")
        XCTAssertTrue(CommentsMemory.isOn(c.file!.path, defaults: d))
    }

    func testOpenCountExcludesResolvedIncludesOrphans() throws {
        let c = ViewerComments(defaults: defaults())
        c.show(file: try file("list-after.md"))
        XCTAssertEqual(c.openCount, 2, "ab12c and the orphan gh56i; de34f is resolved")
    }

    func testRelativeTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-11-07T18:00:00Z")!
        func rel(_ s: String?) -> String { CommentTime.relative(s, now: now, calendar: cal, locale: locale) }
        XCTAssertEqual(rel("2026-11-07T17:59:30.000Z"), "just now")
        XCTAssertEqual(rel("2026-11-07T17:20:00.000Z"), "40 min ago")
        XCTAssertEqual(rel("2026-11-07T15:30:00.000Z"), "2 h ago")
        XCTAssertEqual(rel("2026-11-04T10:00:00.000Z"), "Nov 4")
        XCTAssertEqual(rel("2025-12-30T10:00:00.000Z"), "Dec 30, 2025")
        XCTAssertEqual(rel("2026-10-17"), "Oct 17")
        XCTAssertEqual(rel(nil), "")
        XCTAssertEqual(rel("soon"), "")
    }

    func testAgentMatchIsCaseInsensitive() throws {
        let c = ViewerComments(defaults: defaults())
        c.agentName = "Bill"
        XCTAssertTrue(c.isAgent("bill"))
        XCTAssertTrue(c.isAgent("Bill"))
        XCTAssertFalse(c.isAgent("Sam"))
    }

    func testPersonNameFallsBackToFullUserName() {
        let c = ViewerComments(defaults: defaults())
        c.helloPersonName = nil
        XCTAssertEqual(c.personName, NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
        c.helloPersonName = "Sam Rivera"
        XCTAssertEqual(c.personName, "Sam Rivera")
        c.helloPersonName = ""
        XCTAssertNotEqual(c.personName, "")
    }

    func testToggleTips() {
        XCTAssertEqual(ViewerCommentsToggle.tip(on: true, focused: false), "Hide comments")
        XCTAssertEqual(ViewerCommentsToggle.tip(on: false, focused: false), "Show comments: widens the viewer")
        XCTAssertEqual(ViewerCommentsToggle.tip(on: false, focused: true), "Show comments")
    }

    func testToggleHiddenForNonMarkdownAndSpaces() {
        XCTAssertTrue(ViewerCommentsToggle.shows(media: .markdown, isSpace: false))
        XCTAssertFalse(ViewerCommentsToggle.shows(media: .html, isSpace: false))
        XCTAssertFalse(ViewerCommentsToggle.shows(media: .text, isSpace: false))
        XCTAssertFalse(ViewerCommentsToggle.shows(media: .markdown, isSpace: true))
    }

    func testPageStateCarriesThreadsAndAuthors() throws {
        let c = ViewerComments(defaults: defaults())
        c.agentName = "Agent"
        c.show(file: try file("list-after.md"))
        let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        let state = c.pageState(now: now)
        let threads = try XCTUnwrap(state["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.map { $0["id"] as? String }, ["ab12c", "de34f", "gh56i"])
        XCTAssertEqual(threads[2]["orphan"] as? Bool, true)
        let replies = try XCTUnwrap(threads[0]["replies"] as? [[String: Any]])
        XCTAssertEqual(replies[1]["agent"] as? Bool, true)
        XCTAssertEqual(replies[1]["initial"] as? String, "A")
        XCTAssertEqual(replies[0]["agent"] as? Bool, false)
        XCTAssertEqual(state["on"] as? Bool, false)
    }

    // MARK: - writing in reading mode (Task 6)

    func testMenuContextRefusesUnanchorable() throws {
        let c = ViewerComments(defaults: defaults())
        c.show(file: try file("para.md"))
        let ok = c.menuContext(selection: ["text": "writes files", "lines": [2, 2], "occurrence": 0], editMode: false)
        XCTAssertTrue(ok.hasSelection)
        XCTAssertNil(ok.refusal)
        let across = c.menuContext(selection: ["text": "endings. Second", "lines": [2, 2], "occurrence": 0], editMode: false)
        XCTAssertEqual(across.refusal, "Select text within one paragraph, outside links and formatting.")
        let code = c.menuContext(selection: ["text": "x", "lines": NSNull(), "occurrence": 0, "refusal": "ignored"], editMode: false)
        XCTAssertEqual(code.refusal, "Comments can't go in code, tables or front matter.")
        let none = c.menuContext(selection: nil, editMode: false)
        XCTAssertFalse(none.hasSelection)
    }

    func testDraftPostWritesTheFile() throws {
        let d = defaults()
        let c = ViewerComments(defaults: d)
        let url = try file("para.md")
        c.show(file: url)
        c.helloPersonName = "Sam Rivera"
        let focus = FakeFocus()
        c.beginDraft(.init(text: "writes files", lines: 2...2, occurrence: 0), chat: 1, focus: focus)
        XCTAssertTrue(c.shown)
        XCTAssertNotNil(c.draft)
        XCTAssertEqual(focus.toggles, 1, "comment widens the viewer")
        c.received(["type": "post", "text": "Which files?"], chat: 1, focus: focus)
        XCTAssertNil(c.draft)
        XCTAssertNil(c.error)
        let t = try XCTUnwrap(CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads.first)
        XCTAssertEqual(t.by, "Sam Rivera")
        XCTAssertEqual(c.activeID, t.id)
        c.received(["type": "reply", "id": t.id, "text": "Also these."], chat: 1, focus: focus)
        c.received(["type": "resolve", "id": t.id], chat: 1, focus: focus)
        let after = try XCTUnwrap(CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads.first)
        XCTAssertEqual(after.replies.count, 2)
        XCTAssertEqual(after.status, .resolved)
        XCTAssertNil(c.activeID)
    }

    func testWriteFailureKeepsDraftAndSaysWhy() throws {
        let c = ViewerComments(defaults: defaults())
        let url = try file("para.md")
        c.show(file: url)
        c.beginDraft(.init(text: "writes files", lines: 2...2, occurrence: 0), chat: 1, focus: FakeFocus())
        try FileManager.default.removeItem(at: url)
        c.received(["type": "post", "text": "Still here?"], chat: 1, focus: FakeFocus())
        XCTAssertEqual(c.draft?.text, "Still here?")
        XCTAssertEqual(c.error, "Not saved — the file is gone")
    }

    func testReadOnlyWritesNothing() throws {
        let c = ViewerComments(defaults: defaults())
        let url = try file("plugin-basic.md")
        c.show(file: url)
        c.readOnly = "Read-only."
        let before = try Data(contentsOf: url)
        c.received(["type": "resolve", "id": "k3x9a"], chat: 1, focus: FakeFocus())
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
