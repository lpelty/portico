import Foundation
import XCTest

@testable import Portico

/// v0.23: comment actions in reading mode write the file through the
/// atomic, stamp-checked save; a change on disk meanwhile is re-read and
/// applied once more, never overwritten.
final class CommentWriterTests: XCTestCase {
    private func copy(_ fixture: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.md")
        try Data(contentsOf: CommentFormatTests.fixturesDir.appendingPathComponent(fixture)).write(to: url)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1762540706.176)  // 2025-11-07T18:38:26.176Z

    func testPostAddsAnchorsAndBlock() throws {
        let url = try copy("para.md")
        let sel = CommentAnchoring.Selection(text: "writes files", lines: 2...2, occurrence: 0)
        let made = CommentWriter.Made()
        try CommentWriter.apply(
            CommentWriter.edit(for: .add(sel, body: "Which files?"), author: "Sam Rivera", now: now, made: made, newID: { _ in "nw001" }),
            to: url)
        let want = try CommentFormatTests.read("para.add.after.md").replacingOccurrences(
            of: "2026-11-07T18:38:26.176Z", with: "2025-11-07T18:38:26.176Z")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), want)
        XCTAssertEqual(made.id, "nw001")
    }

    func testReplyAndResolveAndReopen() throws {
        let url = try copy("plugin-basic.md")
        try CommentWriter.apply(CommentWriter.edit(for: .reply(id: "k3x9a", body: "Yes, MCP tools too."), author: "Agent", now: now), to: url)
        var t = CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads[0]
        XCTAssertEqual(t.replies.last, .init(author: "Agent", at: "2025-11-07T18:38:26.176Z", text: "Yes, MCP tools too."))
        try CommentWriter.apply(CommentWriter.edit(for: .setStatus(id: "k3x9a", resolved: true), author: "Sam", now: now), to: url)
        t = CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads[0]
        XCTAssertEqual(t.status, .resolved)
        try CommentWriter.apply(CommentWriter.edit(for: .setStatus(id: "k3x9a", resolved: false), author: "Sam", now: now), to: url)
        t = CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads[0]
        XCTAssertEqual(t.status, .open)
    }

    func testPostRetriesOnceAfterDiskChange() throws {
        let url = try copy("para.md")
        var calls = 0
        let reply = CommentWriter.edit(for: .add(.init(text: "Second", lines: 4...4, occurrence: 0), body: "Hm."),
                                       author: "Sam", now: now, newID: { _ in "nw009" })
        try CommentWriter.apply({ text in
            calls += 1
            if calls == 1 {
                // Someone else writes the file meanwhile (another size, so the stamp differs).
                try (text + "Added meanwhile.\n").write(to: url, atomically: false, encoding: .utf8)
            }
            return try reply(text)
        }, to: url)
        XCTAssertEqual(calls, 2)
        let out = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(out.contains("Added meanwhile."), "the other write is kept")
        XCTAssertTrue(out.contains("<!--c:nw009-->Second<!--/c:nw009-->"))
    }

    func testSecondChangeFailsWithoutWriting() throws {
        let url = try copy("para.md")
        var n = 0
        XCTAssertThrowsError(try CommentWriter.apply({ text in
            n += 1
            try (text + String(repeating: "x", count: n) + "\n").write(to: url, atomically: false, encoding: .utf8)
            return text + "MINE\n"
        }, to: url)) { error in
            XCTAssertEqual(error as? FileEditing.Failure, .changedOnDisk)
        }
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("MINE"))
    }

    func testAuthorIsRealName() throws {
        let url = try copy("para.md")
        let sel = CommentAnchoring.Selection(text: "Second paragraph", lines: 4...4, occurrence: 0)
        try CommentWriter.apply(CommentWriter.edit(for: .add(sel, body: "Mine."), author: "Sam Rivera", now: now), to: url)
        let t = try XCTUnwrap(CommentFormat.parse(try String(contentsOf: url, encoding: .utf8)).threads.first)
        XCTAssertEqual(t.by, "Sam Rivera")
        XCTAssertNotEqual(t.replies.first?.author, "me")
    }
}
