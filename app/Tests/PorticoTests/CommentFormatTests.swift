import Foundation
import XCTest

@testable import Portico

/// v0.23: comment format v1 in Swift, against the same fixtures the gateway
/// reads (`protocol/examples/comments/cases.json`).
final class CommentFormatTests: XCTestCase {

    static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PorticoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol/examples/comments", isDirectory: true)
    }

    static func read(_ name: String) throws -> String {
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent(name))
        return String(decoding: data, as: UTF8.self)
    }

    static func cases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixturesDir.appendingPathComponent("cases.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["cases"] as! [[String: Any]]
    }

    private func json(_ text: String, _ t: CommentFormat.Thread) -> [String: Any] {
        [
            "id": t.id, "by": t.by, "at": t.at, "status": t.status.rawValue, "quote": t.quote,
            "anchored_text": CommentFormat.anchoredText(text, t) as Any? ?? NSNull(),
            "replies": t.replies.map { ["author": $0.author, "at": $0.at as Any? ?? NSNull(), "text": $0.text] },
            "reactions": t.reactions,
        ]
    }

    private func same(_ a: Any, _ b: Any) -> Bool {
        let x = try! JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let y = try! JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return x == y
    }

    static func fingerprint(_ a: [String: Any]) -> CommentFormat.Fingerprint? {
        guard let f = a["fingerprint"] as? [String: Any] else { return nil }
        return .init(author: f["author"] as! String, at: f["at"] as? String, text: f["text"] as! String)
    }

    static func apply(_ c: [String: Any], to text: String) throws -> String {
        let a = c["args"] as! [String: Any]
        switch c["op"] as! String {
        case "add":
            let found = CommentFormat.findQuote(text, a["quote"] as! String, occurrence: a["occurrence"] as? Int ?? 1)
            let range = try found.get()
            return CommentFormat.addThread(
                text, range: range, id: a["id"] as! String, author: a["author"] as! String,
                at: a["at"] as! String, body: a["body"] as! String)
        case "reply":
            return try CommentFormat.addReply(
                text, threadID: a["id"] as! String, author: a["author"] as! String, at: a["at"] as! String,
                body: a["body"] as! String)
        case "resolve": return try CommentFormat.setStatus(text, threadID: a["id"] as! String, .resolved)
        case "reopen": return try CommentFormat.setStatus(text, threadID: a["id"] as! String, .open)
        case "edit":
            return try CommentFormat.editComment(
                text, threadID: a["id"] as! String, index: a["index"] as! Int, body: a["body"] as! String,
                fingerprint: fingerprint(a))
        case "delete":
            return try CommentFormat.deleteComment(
                text, threadID: a["id"] as! String, index: a["index"] as! Int, fingerprint: fingerprint(a))
        default: XCTFail("unknown op"); return text
        }
    }

    func testFixturesParse() throws {
        let parseCases = try Self.cases().filter { $0["parse"] != nil }
        XCTAssertGreaterThan(parseCases.count, 10)
        for c in parseCases {
            let text = try Self.read(c["file"] as! String)
            let parsed = CommentFormat.parse(text)
            let want = c["parse"] as! [String: Any]
            let got = parsed.threads.map { json(text, $0) }
            XCTAssertTrue(same(got, want["threads"]!), "\(c["name"]!): \(got)")
            XCTAssertEqual(parsed.orphanAnchors, want["orphan_anchors"] as! [String], "\(c["name"]!)")
        }
    }

    func testFixtureOps() throws {
        let ops = try Self.cases().filter { $0["op"] != nil && $0["expect"] != nil }
        XCTAssertGreaterThan(ops.count, 10)
        for c in ops {
            let text = try Self.read(c["file"] as! String)
            let out = try Self.apply(c, to: text)
            XCTAssertEqual(Array(out.utf8), Array(try Self.read(c["expect"] as! String).utf8), "\(c["name"]!)")
        }
    }

    func testRoundTripByteIdentical() throws {
        for c in try Self.cases() where c["parse"] != nil {
            let text = try Self.read(c["file"] as! String)
            let parsed = CommentFormat.parse(text)
            if !parsed.orphanAnchors.isEmpty { continue }
            for t in parsed.threads {
                let out = try CommentFormat.setStatus(text, threadID: t.id, t.status)
                XCTAssertEqual(Array(out.utf8), Array(text.utf8), "\(c["name"]!) \(t.id)")
            }
        }
    }

    func testEmojiOffsetsAreUTF16() throws {
        let text = try Self.read("emoji.md")
        let t = CommentFormat.parse(text).threads[0]
        let anchor = try XCTUnwrap(t.anchor)
        let units = Array(text.utf16)
        XCTAssertEqual(String(decoding: units[anchor], as: UTF16.self), "first draft")
        let found = try CommentFormat.findQuote(text, "is ready").get()
        XCTAssertEqual(String(decoding: units[found], as: UTF16.self), "is ready")
    }

    func testTimestampFormat() {
        XCTAssertEqual(
            CommentFormat.timestamp(Date(timeIntervalSince1970: 1762540706.176)), "2025-11-07T18:38:26.176Z")
    }

    func testRefusals() throws {
        let code = try Self.read("code-ignored.md")
        XCTAssertEqual(CommentFormat.findQuote(code, "nowhere in it"), .failure(.notFound))
        XCTAssertEqual(CommentFormat.findQuote(code, "not a comment"), .failure(.insideIgnored))
        let para = try Self.read("para.md")
        XCTAssertEqual(CommentFormat.findQuote(para, "line endings. Second"), .failure(.crossesBlocks))
        XCTAssertEqual(CommentFormat.findQuote("one word, one more\n", "one", occurrence: 3), .failure(.occurs(2)))
        XCTAssertEqual(CommentFormat.findQuote("one word, one more\n", "one", occurrence: 2), .success(10..<13))
    }

    func testSnapToWords() {
        let text = "the permission prompt stays"
        XCTAssertEqual(CommentFormat.snapToWords(text, 5..<18), 4..<21)
        XCTAssertEqual(CommentFormat.snapToWords(text, 3..<22), 3..<22)
        XCTAssertEqual(CommentFormat.snapToWords("don't stop", 1..<3), 0..<5)
    }

    func testNewIDFallsBackTo8() {
        // 1, not 0: Swift's bounded random rejects a draw of 0 forever; 1 always picks the first element ("a").
        struct AlwaysFirst: RandomNumberGenerator { mutating func next() -> UInt64 { 1 } }
        var rng = AlwaysFirst()
        XCTAssertEqual(CommentFormat.newID(in: "`<!--c:aaaaa-->`", using: &rng), "aaaaaaaa")
        var rng2 = SystemRandomNumberGenerator()
        XCTAssertEqual(CommentFormat.newID(in: "", using: &rng2).count, 5)
    }

    func testEscapedTextReadsBack() throws {
        let text = try Self.read("para.md")
        let r = try CommentFormat.findQuote(text, "writes files").get()
        let body = "See a --> b\nNote: one\n\n+1\n\\leading"
        var out = CommentFormat.addThread(text, range: r, id: "zz001", author: "Sam", at: "2026-11-07T00:00:00.000Z", body: body)
        out = try CommentFormat.addReply(out, threadID: "zz001", author: "Agent", at: "2026-11-07T00:00:01.000Z", body: "x: --> y")
        XCTAssertEqual(CommentFormat.parse(out).threads[0].replies.map(\.text), [body, "x: --> y"])
    }

    // MARK: - fix round: visible text, block ends, escaping (shared fixtures)

    func testFixtureFinds() throws {
        let finds = try Self.cases().filter { $0["find"] != nil }
        XCTAssertGreaterThan(finds.count, 8)
        for c in finds {
            let text = c["text"] as! String
            let f = c["find"] as! [String: Any]
            let got = CommentFormat.findQuote(text, f["quote"] as! String, occurrence: f["occurrence"] as? Int ?? 1)
            if let refusal = c["expect_refusal"] as? String {
                let want: CommentFormat.Refusal
                switch refusal {
                case "not found": want = .notFound
                case "inside code or front matter": want = .insideIgnored
                case "crosses paragraphs": want = .crossesBlocks
                case "not shown in the table": want = .notShown
                default: want = .occurs(Int(refusal.split(separator: " ")[1])!)
                }
                XCTAssertEqual(got, .failure(want), "\(c["name"]!)")
            } else {
                XCTAssertEqual(try got.get().lowerBound, (c["expect_prefix"] as! String).utf16.count, "\(c["name"]!)")
                if let want = c["expect_text"] as? String {
                    let r = try got.get()
                    XCTAssertEqual(String(decoding: Array(text.utf16)[r], as: UTF16.self), want, "\(c["name"]!)")
                }
            }
        }
    }

    func testEscapingRoundTrips() throws {
        let values = try Self.cases().compactMap { $0["roundtrip"] as? [String] }.flatMap { $0 }
        XCTAssertGreaterThan(values.count, 5)
        for v in values {
            let line = v.replacingOccurrences(of: "\n", with: " ")
            XCTAssertEqual(CommentFormat.unescapeQuoted(CommentFormat.escapeQuoted(line)), line, v)
            var out = CommentFormat.addThread("Word here.\n", range: 0..<4, id: "rt001", author: "Sam", at: "2026-11-07T00:00:00.000Z", body: v)
            out = try CommentFormat.addReply(out, threadID: "rt001", author: "Agent", at: "2026-11-07T00:00:01.000Z", body: v)
            XCTAssertEqual(CommentFormat.parse(out).threads[0].replies.map(\.text), [v, v], v)
        }
    }

    func testFixtureRefusals() throws {
        let cases = try Self.cases().filter { $0["expect_error"] != nil }
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for c in cases {
            let text = try Self.read(c["file"] as! String)
            XCTAssertThrowsError(try Self.apply(c, to: text), "\(c["name"]!)") { error in
                switch c["expect_error"] as! String {
                case "changed": XCTAssertEqual(error as? CommentFormat.EditError, .changed, "\(c["name"]!)")
                default: XCTAssertEqual(error as? CommentFormat.EditError, .blank, "\(c["name"]!)")
                }
            }
        }
    }
}
