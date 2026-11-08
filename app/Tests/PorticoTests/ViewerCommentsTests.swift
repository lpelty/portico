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
        XCTAssertEqual(code.refusal, "Comments can't go in code or front matter.")
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

    // MARK: - Edit mode (Task 7)

    final class FakeBuffer: CommentsBuffer {
        var text: String
        var changes: [(Int, Int, String, Int)] = []
        var refuseFirst = false
        init(_ text: String) { self.text = text }
        var draft: Range<Int>?
        func currentText() async -> String? { text }
        func draftRange() async -> Range<Int>? { draft }
        func applyChange(from: Int, to: Int, insert: String, expectedLength: Int) async -> Bool {
            changes.append((from, to, insert, expectedLength))
            if refuseFirst { refuseFirst = false; text += "typed\n"; return false }
            guard expectedLength == text.utf16.count else { return false }
            var units = Array(text.utf16)
            units.replaceSubrange(from..<to, with: Array(insert.utf16))
            text = String(decoding: units, as: UTF16.self)
            return true
        }
    }

    func testEditModeReplyGoesThroughBuffer() async throws {
        let url = try file("plugin-basic.md")
        let before = try Data(contentsOf: url)
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        let buffer = FakeBuffer(try String(contentsOf: url, encoding: .utf8))
        buffer.refuseFirst = true
        c.editBuffer = buffer
        let ok = await c.applyInBuffer(.reply(id: "k3x9a", body: "Through the buffer."))
        XCTAssertTrue(ok)
        XCTAssertEqual(buffer.changes.count, 2, "refused once (the text moved), fetched again, applied")
        XCTAssertTrue(buffer.text.contains("): Through the buffer.\n-->"))
        XCTAssertTrue(buffer.text.hasSuffix("typed\n"), "the person's typing is kept")
        XCTAssertEqual(try Data(contentsOf: url), before, "the file underneath is never written")
        let change = try XCTUnwrap(buffer.changes.last)
        XCTAssertEqual(change.0, change.1, "a pure insertion: the minimal splice")
    }

    func testEditModeAddByRange() async throws {
        let url = try file("para.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.helloPersonName = "Sam"
        let buffer = FakeBuffer(text)
        c.editBuffer = buffer
        let start = Array(text.utf16).count - "Second paragraph.\n".utf16.count
        let made = CommentWriter.Made()
        let ok = await c.applyInBuffer(.addRange(start..<(start + 6), body: "Edit mode."), made: made)
        XCTAssertTrue(ok)
        XCTAssertTrue(buffer.text.contains("<!--c:\(made.id!)-->Second<!--/c:\(made.id!)-->"))
        let refused = await c.applyInBuffer(.addRange(0..<0, body: "x"))
        XCTAssertFalse(refused)
    }

    func testTextSpliceMinimalUTF16() {
        let s = TextSplice.minimal("a🙂b\nend", "a🙂XYb\nend")
        XCTAssertEqual(s.from, 3)
        XCTAssertEqual(s.to, 3)
        XCTAssertEqual(s.insert, "XY")
        let d = TextSplice.minimal("abcdef", "abef")
        XCTAssertEqual(d.from, 2)
        XCTAssertEqual(d.to, 4)
        XCTAssertEqual(d.insert, "")
        let same = TextSplice.minimal("x", "x")
        XCTAssertEqual(same.from, same.to)
        XCTAssertEqual(same.insert, "")
        // Never splits a surrogate pair.
        let e = TextSplice.minimal("🙂", "🙃")
        XCTAssertEqual(e.from, 0)
        XCTAssertEqual(e.to, 2)
    }

    // MARK: - fix round: stale drafts, non-UTF-8 (review items 6, 10b)

    func testStaleDraftFindsItsTextAgainByQuote() throws {
        let c = ViewerComments(defaults: defaults())
        let url = try file("para.md")
        c.show(file: url)
        c.beginDraft(.init(text: "writes files", lines: 2...2, occurrence: 0), chat: 1, focus: FakeFocus())
        let moved = "New intro paragraph.\n\n" + (try String(contentsOf: url, encoding: .utf8))
        try moved.write(to: url, atomically: false, encoding: .utf8)
        c.received(["type": "post", "text": "Still mine."], chat: 1, focus: FakeFocus())
        XCTAssertNil(c.error)
        let out = try String(contentsOf: url, encoding: .utf8)
        let t = try XCTUnwrap(CommentFormat.parse(out).threads.first)
        XCTAssertEqual(CommentFormat.anchoredText(out, t), "writes files")
        XCTAssertTrue(out.hasPrefix("New intro paragraph.\n\n"))
    }

    func testStaleDraftWithItsTextGoneOrDoubledRefusesAndKeepsTheText() throws {
        for change in ["gone", "doubled"] {
            let c = ViewerComments(defaults: defaults())
            let url = try file("para.md")
            c.show(file: url)
            c.beginDraft(.init(text: "writes files", lines: 2...2, occurrence: 0), chat: 1, focus: FakeFocus())
            var text = try String(contentsOf: url, encoding: .utf8)
            text = change == "gone"
                ? text.replacingOccurrences(of: "writes files", with: "saves documents")
                : "It writes files too.\n\n" + text
            try text.write(to: url, atomically: false, encoding: .utf8)
            let before = try Data(contentsOf: url)
            c.received(["type": "post", "text": "Mine."], chat: 1, focus: FakeFocus())
            XCTAssertEqual(c.error, ViewerComments.staleWords, change)
            XCTAssertEqual(c.draft?.text, "Mine.", change)
            XCTAssertEqual(try Data(contentsOf: url), before, change)
        }
    }

    func testNonUTF8FileSaysSo() throws {
        let c = ViewerComments(defaults: defaults())
        let url = try file("plugin-basic.md")
        c.show(file: url)
        try Data("caf\u{e9} word\n".utf8).write(to: url)
        var latin = try Data(contentsOf: url)
        latin[3] = 0xE9
        latin.remove(at: 4)
        try latin.write(to: url)
        c.received(["type": "reply", "id": "k3x9a", "text": "x"], chat: 1, focus: FakeFocus())
        XCTAssertEqual(c.error, "This file isn't UTF-8 text; comments can't be added.")
    }

    func testEditModePostUsesTheEditorsMappedDraftRange() async throws {
        let url = try file("para.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        let text = "Moved down.\n\n" + (try String(contentsOf: url, encoding: .utf8))
        let buffer = FakeBuffer(text)
        c.editBuffer = buffer
        let at = Array(text.utf16).count - "Second paragraph.\n".utf16.count
        buffer.draft = at..<(at + 6)
        c.beginDraft(nil, range: 0..<4, chat: 1, focus: FakeFocus())  // stale: where the selection was
        let made = CommentWriter.Made()
        let ok = await c.applyInBuffer(.addRange(0..<4, body: "Mapped."), made: made)
        XCTAssertTrue(ok)
        XCTAssertTrue(buffer.text.contains("<!--c:\(made.id!)-->Second<!--/c:\(made.id!)-->"), buffer.text)
    }

    func testEditModeCJKSelectionIsAnchoredExactly() async throws {
        let url = try file("para.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        let text = "日本語の文章です\n"
        let buffer = FakeBuffer(text)
        c.editBuffer = buffer
        let made = CommentWriter.Made()
        let ok = await c.applyInBuffer(.addRange(4..<6, body: "Exact."), made: made)
        XCTAssertTrue(ok)
        XCTAssertTrue(buffer.text.hasPrefix("日本語の<!--c:\(made.id!)-->文章<!--/c:\(made.id!)-->です"), buffer.text)
    }

    func testCellRefusalAndCellSelectionInTheMenu() throws {
        let c = ViewerComments(defaults: defaults())
        c.show(file: try file("table.md"))
        let across = c.menuContext(selection: ["text": "x", "lines": [4, 4], "occurrence": 0, "refusal": "cell"], editMode: false)
        XCTAssertEqual(across.refusal, "Select text within one cell.")
        let ok = c.menuContext(selection: ["text": "10", "lines": [2, 5], "occurrence": 0, "cell": 2, "row": 1, "table": 0], editMode: false)
        XCTAssertNil(ok.refusal)
        let sel = ViewerComments.selection(["text": "10", "lines": [2, 5], "occurrence": 0, "cell": 2, "row": 1, "table": 0])
        XCTAssertEqual(sel?.cell, 2)
        XCTAssertEqual(sel?.row, 1)
        let widget = c.menuContext(selection: ["text": "selection", "lines": [0, 0], "occurrence": 0, "refusal": "widget"], editMode: true, trustSelection: true)
        XCTAssertEqual(widget.refusal, "Click into the table to comment.")
    }

    // MARK: - card actions (spec §13.2)

    func testEditingYourOwnCommentKeepsItsTimeAndTheOthers() throws {
        let url = try file("list-after.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.helloPersonName = "Sam"
        c.received(["type": "edit", "id": "ab12c", "index": 0, "text": "Changed.",
                    "fp": ["author": "Sam", "at": "2026-10-17", "text": "Byte for byte?"]], chat: 1, focus: FakeFocus())
        XCTAssertNil(c.error)
        let t = try XCTUnwrap(CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads.first)
        XCTAssertEqual(t.replies.map(\.text), ["Changed.", "Yes, every fixture."])
        XCTAssertEqual(t.replies[0].at, "2026-10-17")
    }

    func testOnlyYourOwnCommentsCanBeEdited() throws {
        let url = try file("list-after.md")
        let before = try Data(contentsOf: url)
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.helloPersonName = "Sam"
        c.received(["type": "edit", "id": "ab12c", "index": 1, "text": "Not mine.",
                    "fp": ["author": "Agent", "at": "2026-10-18", "text": "Yes, every fixture."]], chat: 1, focus: FakeFocus())
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testDeletingAReplyThenTheThread() throws {
        let url = try file("list-after.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.activeID = "ab12c"
        c.received(["type": "delete", "id": "ab12c", "index": 1,
                    "fp": ["author": "Agent", "at": "2026-10-18", "text": "Yes, every fixture."]], chat: 1, focus: FakeFocus())
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(CommentFormat.parse(text).threads.first?.replies.count, 1)
        c.received(["type": "delete", "id": "ab12c", "index": 0,
                    "fp": ["author": "Sam", "at": "2026-10-17", "text": "Byte for byte?"]], chat: 1, focus: FakeFocus())
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("ab12c"))
        XCTAssertNil(c.activeID)
    }

    func testPageStateSaysWhichCommentsAreYoursAndCountsResolved() throws {
        let c = ViewerComments(defaults: defaults())
        c.show(file: try file("list-after.md"))
        c.helloPersonName = "sam"
        let state = c.pageState()
        let threads = try XCTUnwrap(state["threads"] as? [[String: Any]])
        let replies = try XCTUnwrap(threads[0]["replies"] as? [[String: Any]])
        XCTAssertEqual(replies.map { $0["own"] as? Bool }, [true, false])
        XCTAssertEqual(replies.map { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(replies.map { $0["at"] as? String }, ["2026-10-17", "2026-10-18"])
        XCTAssertEqual(state["resolvedCount"] as? Int, 1)
        XCTAssertEqual(state["showResolved"] as? Bool, false)
    }

    func testShowResolvedIsRememberedPerFile() throws {
        let d = defaults()
        let url = try file("list-after.md")
        let c = ViewerComments(defaults: d)
        c.show(file: url)
        c.received(["type": "showResolved", "on": true], chat: 1, focus: FakeFocus())
        XCTAssertTrue(c.showResolved)
        let again = ViewerComments(defaults: d)
        again.show(file: url)
        XCTAssertTrue(again.showResolved)
        let other = ViewerComments(defaults: d)
        other.show(file: try file("para.md"))
        XCTAssertFalse(other.showResolved)
    }

    func testEditModeDeleteGoesThroughTheBuffer() async throws {
        let url = try file("plugin-basic.md")
        let before = try Data(contentsOf: url)
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        let buffer = FakeBuffer(try String(contentsOf: url, encoding: .utf8))
        c.editBuffer = buffer
        let ok = await c.applyInBuffer(.delete(id: "k3x9a", index: 0, fingerprint: .init(
            author: "me", at: "2026-11-02T10:15:00.000Z", text: "Is this still true for MCP tools?")))
        XCTAssertTrue(ok)
        XCTAssertFalse(buffer.text.contains("k3x9a"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAnActionOnACommentThatChangedMeanwhileIsRefused() throws {
        let url = try file("list-after.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.helloPersonName = "Sam"
        // Another writer replaced the first comment after the card was drawn.
        let changed = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Byte for byte?", with: "Rewritten elsewhere.")
        try changed.write(to: url, atomically: false, encoding: .utf8)
        for message: [String: Any] in [
            ["type": "edit", "id": "ab12c", "index": 0, "text": "Mine.", "fp": ["author": "Sam", "at": "2026-10-17", "text": "Byte for byte?"]],
            ["type": "delete", "id": "ab12c", "index": 0, "fp": ["author": "Sam", "at": "2026-10-17", "text": "Byte for byte?"]],
        ] {
            c.error = nil
            c.received(message, chat: 1, focus: FakeFocus())
            XCTAssertEqual(c.error, "This comment changed since you opened it; try again.")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
        }
        XCTAssertEqual(c.threads.first?.replies.first?.text, "Rewritten elsewhere.", "re-read so the card shows what's there now")
    }

    // MARK: - v0.25 sweep fixes

    func testADraftThatLostItsPlaceSaysSo() throws {
        // #12 (ruling 24): an Edit-mode draft posted after Edit went off keeps its text and says why.
        let url = try file("para.md")
        let before = try Data(contentsOf: url)
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        let buffer = FakeBuffer(try String(contentsOf: url, encoding: .utf8))
        c.editBuffer = buffer
        c.beginDraft(nil, range: 0..<5, chat: 1, focus: FakeFocus())
        c.editBuffer = nil  // Edit off (EditorPane.tearDown)
        c.received(["type": "post", "text": "My comment"], chat: 1, focus: FakeFocus())
        XCTAssertEqual(c.error, "Select the text again to post this comment.")
        XCTAssertEqual(c.draft?.text, "My comment")
        XCTAssertEqual(try Data(contentsOf: url), before)
        withExtendedLifetime(buffer) {}
    }

    func testAReadModeDraftPostedInEditModeSaysSo() async throws {
        // #12, the other way: a reading-mode draft, then Edit on: no range-0 write is attempted.
        let url = try file("para.md")
        let c = ViewerComments(defaults: defaults())
        c.show(file: url)
        c.beginDraft(.init(text: "writes files", lines: 2...2, occurrence: 0), chat: 1, focus: FakeFocus())
        let buffer = FakeBuffer(try String(contentsOf: url, encoding: .utf8))
        c.editBuffer = buffer
        c.received(["type": "post", "text": "Which files?"], chat: 1, focus: FakeFocus())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(c.error, "Select the text again to post this comment.")
        XCTAssertEqual(c.draft?.text, "Which files?")
        XCTAssertTrue(buffer.changes.isEmpty, "nothing was written to the buffer")
    }
}
