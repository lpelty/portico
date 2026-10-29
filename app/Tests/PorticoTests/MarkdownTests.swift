import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// v0.4 decision 1: the agent's Markdown, split into blocks by
/// `MarkdownParser` and its inline runs parsed by Foundation. Pure: no window.
final class MarkdownTests: XCTestCase {

    /// Larry's real answer from v0.3.0 (Session 1, "create a simple mobile
    /// UI as an html file"), which drew with its markers showing.
    static let larrysAnswer = """
        I made `mobile-ui.html` in the vault folder. It's a single file with no dependencies. I haven't opened it in a browser yet, so I haven't checked how it looks.

        **What's on the screen:**
        - **Header:** a "Discover" title at the top, with a round avatar showing "A".
        - **Search box:** narrows the list as you type.
        - **Category buttons:** a row you can scroll sideways (All, Food, Travel, Music, Fitness). Tapping one filters the list.
        - **Card list:** each card has an emoji picture, a title, a short description and a heart button you can tap to favorite it.
        - **Round "+" button:** floats above the bottom right. It's just for show and doesn't do anything when tapped.
        - **Bottom tab bar:** Home, Explore, Alerts and Profile. Tapping a tab highlights it but doesn't change the screen.

        **Layout and theme:**
        - It's at most 480px wide and centered, so it looks like a phone screen on a desktop browser too.
        - It leaves room for the notch and home bar on iPhones.
        - It switches to a dark theme when your device is set to dark mode.

        To see it, open the file in a browser. On a desktop, your browser's developer tools have a phone view that shows it at phone size.
        """

    /// The characters a reader sees once inline Markdown is applied.
    private func shown(_ text: String) -> String {
        String(MarkdownParser.inline(text).characters)
    }

    func testLarrysAnswerHasNoRawMarkers() {
        let blocks = MarkdownParser.parse(Self.larrysAnswer)
        XCTAssertEqual(blocks.count, 6, "\(blocks)")
        guard case .paragraph(let first) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertTrue(shown(first).hasPrefix("I made mobile-ui.html in the vault folder."))
        guard case .paragraph(let head) = blocks[1] else { return XCTFail("\(blocks[1])") }
        XCTAssertEqual(shown(head), "What's on the screen:")
        guard case .list(let items) = blocks[2] else { return XCTFail("\(blocks[2])") }
        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.allSatisfy { $0.level == 0 && $0.number == nil })
        XCTAssertEqual(shown(items[0].text), "Header: a \"Discover\" title at the top, with a round avatar showing \"A\".")
        guard case .list(let layout) = blocks[4] else { return XCTFail("\(blocks[4])") }
        XCTAssertEqual(layout.count, 3)
        guard case .paragraph(let last) = blocks[5] else { return XCTFail("\(blocks[5])") }
        XCTAssertTrue(last.hasPrefix("To see it"))

        for block in blocks {
            let text: String
            switch block {
            case .paragraph(let t), .quote(let t): text = shown(t)
            case .list(let items): text = items.map { shown($0.text) }.joined(separator: "\n")
            default: continue
            }
            XCTAssertFalse(text.contains("**"), text)
            XCTAssertFalse(text.contains("`"), text)
        }
    }

    func testInlineRunsCarryTheirIntents() {
        let attributed = MarkdownParser.inline("a **bold** *it* `code` ~~gone~~ [site](https://example.com)", codeBackground: .gray)
        var intents: [String: InlinePresentationIntent] = [:]
        var link: URL?
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            if let intent = run.inlinePresentationIntent { intents[text] = intent }
            if let url = run.link { link = url }
        }
        XCTAssertEqual(intents["bold"], .stronglyEmphasized)
        XCTAssertEqual(intents["it"], .emphasized)
        XCTAssertEqual(intents["code"], .code)
        XCTAssertEqual(intents["gone"], .strikethrough)
        XCTAssertEqual(link, URL(string: "https://example.com"))
        let code = attributed.runs.first { $0.inlinePresentationIntent == .code }
        XCTAssertNotNil(code?.backgroundColor, "inline code sits on a background")
        XCTAssertEqual(String(attributed.characters), "a bold it code gone site")
    }

    func testLineBreaksInsideAParagraphAreKept() {
        XCTAssertEqual(MarkdownParser.parse("one\ntwo"), [.paragraph("one\ntwo")])
        XCTAssertEqual(shown("one\ntwo"), "one\ntwo")
    }

    func testHeadingsListsQuotesRulesAndCode() {
        let source = """
            # Plan
            ## Steps
            #### Deep
            1. First
            2. Second
               - nested *one*
               - nested two
            3) Third

            > quoted **line**
            > second line

            ---
            ```swift
            let x = 1
                indented()
            ```
            after
            """
        XCTAssertEqual(MarkdownParser.parse(source), [
            .heading(level: 1, text: "Plan"),
            .heading(level: 2, text: "Steps"),
            .heading(level: 3, text: "Deep"),
            .list([
                MarkdownListItem(level: 0, number: "1.", text: "First"),
                MarkdownListItem(level: 0, number: "2.", text: "Second"),
                MarkdownListItem(level: 1, number: nil, text: "nested *one*"),
                MarkdownListItem(level: 1, number: nil, text: "nested two"),
                MarkdownListItem(level: 0, number: "3.", text: "Third"),
            ]),
            .quote("quoted **line**\nsecond line"),
            .rule,
            .code(language: "swift", text: "let x = 1\n    indented()", closed: true),
            .paragraph("after"),
        ])
    }

    func testAnUnclosedFenceRendersAsCodeSoFar() {
        // Mid-stream: the fence is open, so what has come is code, not text.
        XCTAssertEqual(MarkdownParser.parse("Here:\n```\nline one\nline t"), [
            .paragraph("Here:"),
            .code(language: nil, text: "line one\nline t", closed: false),
        ])
        XCTAssertEqual(MarkdownParser.parse("```"), [.code(language: nil, text: "", closed: false)])
    }

    func testPartialMarkdownNeverFails() {
        // Every prefix of a rich answer parses, and its inline runs too.
        let source = Self.larrysAnswer + "\n\n| a | b |\n|---|---|\n| 1 | 22 |\n\n```js\nx()\n```\n> q **b"
        var prefix = ""
        for character in source {
            prefix.append(character)
            for block in MarkdownParser.parse(prefix) {
                if case .paragraph(let text) = block { _ = MarkdownParser.inline(text) }
            }
        }
        XCTAssertEqual(shown("**unclosed"), "**unclosed", "an unclosed marker is shown as typed")
    }

    func testTablesAreAMonospacedBlockWithColumnsLinedUp() {
        let source = """
            | Name | Size |
            |:-----|-----:|
            | a.md | 12 |
            | longer.md | 3 |
            """
        XCTAssertEqual(MarkdownParser.parse(source), [.table("""
            Name       Size
            ─────────  ────
            a.md       12
            longer.md  3
            """)])
        // Pipes without a delimiter row are just text.
        XCTAssertEqual(MarkdownParser.parse("a | b"), [.paragraph("a | b")])
    }

    func testListsThatAreNotLists() {
        XCTAssertEqual(MarkdownParser.parse("**bold** start"), [.paragraph("**bold** start")])
        XCTAssertEqual(MarkdownParser.parse("1.5 million"), [.paragraph("1.5 million")])
        XCTAssertEqual(MarkdownParser.parse("#tag"), [.paragraph("#tag")])
        // A blank line then text ends the list; a blank line then an item continues it.
        XCTAssertEqual(MarkdownParser.parse("- a\n\n- b\n\nafter"), [
            .list([MarkdownListItem(level: 0, number: nil, text: "a"), MarkdownListItem(level: 0, number: nil, text: "b")]),
            .paragraph("after"),
        ])
        XCTAssertEqual(MarkdownParser.parse("- a\n  more of a"), [
            .list([MarkdownListItem(level: 0, number: nil, text: "a\nmore of a")]),
        ])
    }
}
