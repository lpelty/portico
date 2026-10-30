import Foundation
import XCTest

@testable import Portico

/// A Markdown file's YAML front matter (v0.11, item 68): found only
/// between leading `---` lines, read into keys and values, summed up for
/// the folded line, and drawn as the quiet Properties block instead of the
/// setext heading the closing `---` used to make. Pure: no web view.
final class FrontMatterTests: XCTestCase {

    private let note = """
        ---
        title: Trail Detail — Usability Round 2
        date: 2026-10-28
        status: draft
        tags: [research, usability, round-2]
        ---
        # Trail Detail — Usability Round 2

        People could find a trail.
        """

    // MARK: - finding it

    func testSplitsTheBlockFromTheBody() throws {
        let split = FrontMatter.split(note)
        let matter = try XCTUnwrap(split.frontMatter)
        XCTAssertEqual(matter.properties.map(\.key), ["title", "date", "status", "tags"])
        XCTAssertEqual(split.body, "# Trail Detail — Usability Round 2\n\nPeople could find a trail.")
    }

    func testOnlyALeadingBlockCounts() {
        let late = "# Heading\n\n---\ntitle: no\n---\n"
        XCTAssertNil(FrontMatter.split(late).frontMatter)
        XCTAssertEqual(FrontMatter.split(late).body, late, "a rule later in the file is left alone")

        let unclosed = "---\ntitle: never closed\n\nBody text."
        XCTAssertNil(FrontMatter.split(unclosed).frontMatter)
        XCTAssertEqual(FrontMatter.split(unclosed).body, unclosed)

        let plain = "Just text."
        XCTAssertNil(FrontMatter.split(plain).frontMatter)
    }

    func testAcceptsCRLFAByteOrderMarkAndTheDotsCloser() throws {
        let crlf = "\u{FEFF}---\r\ntitle: Notes\r\n...\r\nBody\r\n"
        let split = FrontMatter.split(crlf)
        XCTAssertEqual(try XCTUnwrap(split.frontMatter).properties.first?.value, .text("Notes"))
        XCTAssertEqual(split.body, "Body\r\n")
    }

    func testAnEmptyBlockIsStillTakenOut() {
        let split = FrontMatter.split("---\n---\n# Title\n")
        XCTAssertEqual(split.frontMatter?.properties, [])
        XCTAssertEqual(split.body, "# Title\n", "never a setext heading")
    }

    // MARK: - reading values

    func testReadsScalarsQuotesListsAndDates() throws {
        let source = """
            ---
            title: "Quoted: with colon"
            single: 'it''s'
            count: 4
            empty:
            created: 2026-10-28T09:30
            aliases:
              - First
              - "Second"
            # a comment
            tags: []
            nested:
              owner: Sam
              team: Research
            url: https://example.com/a#b
            note: kept # trailing comment
            ---
            """
        let props = try XCTUnwrap(FrontMatter.split(source).frontMatter).properties
        let values = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0.value) })
        XCTAssertEqual(values["title"], .text("Quoted: with colon"))
        XCTAssertEqual(values["single"], .text("it's"))
        XCTAssertEqual(values["count"], .text("4"))
        XCTAssertEqual(values["empty"], .text(""))
        XCTAssertEqual(values["created"], .date("2026-10-28T09:30"))
        XCTAssertEqual(values["aliases"], .list(["First", "Second"]))
        XCTAssertEqual(values["tags"], .list([]))
        XCTAssertEqual(values["nested"], .text("owner: Sam, team: Research"), "a nested map reads as one line")
        XCTAssertEqual(values["url"], .text("https://example.com/a#b"), "a # inside a word is not a comment")
        XCTAssertEqual(values["note"], .text("kept"))
        XCTAssertEqual(props.map(\.key), ["title", "single", "count", "empty", "created", "aliases", "tags", "nested", "url", "note"])
    }

    // MARK: - the folded line

    func testSummaryCountsThenNamesAFewValues() throws {
        let matter = try XCTUnwrap(FrontMatter.split(note).frontMatter)
        XCTAssertEqual(matter.summary(now: date("2026-10-30"), calendar: utc, locale: posix), "4 — draft, Oct 28, 3 tags")
    }

    func testSummaryYearsSingularsAndShortStrings() throws {
        let source = """
            ---
            title: A very long title that would never fit on one line
            date: 2025-03-02
            aliases: [one]
            kind: memo
            author: Sam
            ---
            """
        let matter = try XCTUnwrap(FrontMatter.split(source).frontMatter)
        XCTAssertEqual(
            matter.summary(now: date("2026-10-30"), calendar: utc, locale: posix),
            "5 — Mar 2, 2025, 1 alias, memo", "another year shows it; the long title is left out; three at most")
        XCTAssertEqual(FrontMatter(properties: []).summary(), "0")
    }

    func testStatusLikeValuesGetATone() {
        XCTAssertTrue(FrontMatter.isStatusKey("status"))
        XCTAssertTrue(FrontMatter.isStatusKey("Stage"))
        XCTAssertFalse(FrontMatter.isStatusKey("title"))
        XCTAssertEqual(FrontMatter.tone(forStatus: "draft"), .wait)
        XCTAssertEqual(FrontMatter.tone(forStatus: "In Progress"), .wait)
        XCTAssertEqual(FrontMatter.tone(forStatus: "Done"), .done)
        XCTAssertEqual(FrontMatter.tone(forStatus: "archived"), .stopped)
        XCTAssertEqual(FrontMatter.tone(forStatus: "whatever"), .neutral)
    }

    // MARK: - the block's HTML

    func testHTMLIsAFoldableQuietBlockWithEscapedValues() throws {
        let source = "---\ntitle: <b>Q3</b> & more\nstatus: draft\ntags: [a, b]\n---\nBody"
        let matter = try XCTUnwrap(FrontMatter.split(source).frontMatter)
        let html = matter.html(now: date("2026-10-30"), calendar: utc, locale: posix)
        XCTAssertTrue(html.hasPrefix("<details class=\"fm\" open>"), html)
        XCTAssertTrue(html.contains("<span class=\"fm-label\">Properties</span>"))
        XCTAssertTrue(html.contains("<span class=\"fm-summary\">· 3 — draft, 2 tags</span>"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;Q3&lt;/b&gt; &amp; more"))
        XCTAssertFalse(html.contains("<b>Q3"))
        XCTAssertTrue(html.contains("<span class=\"fm-dot fm-wait\"></span>draft"))
        XCTAssertTrue(html.contains("<span class=\"fm-tag\">a</span><span class=\"fm-tag\">b</span>"))
        XCTAssertFalse(html.contains("<h"), "never a heading")
    }

    func testMarkdownPageCarriesTheBlockAndOnlyTheBody() throws {
        let page = try MarkdownPage.html(source: note, title: "usability-synthesis.md")
        XCTAssertTrue(page.contains("<details class=\"fm\" open>"))
        XCTAssertFalse(page.contains("status: draft"), "the raw block is not handed to the renderer")
        XCTAssertTrue(page.contains("# Trail Detail"))
        XCTAssertFalse(page.contains("{{"))

        let plain = try MarkdownPage.html(source: "# Just a note", title: "n.md")
        XCTAssertFalse(plain.contains("<details class=\"fm\""), "no block without front matter")
    }

    // MARK: - helpers

    private let utc = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = posix
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }
}
