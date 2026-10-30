import AppKit
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
            case .paragraph(let t): text = shown(t)
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
            .quote([.paragraph("quoted **line**\nsecond line")]),
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

    func testTablesAreRowsOfCells() {
        let source = """
            | Name | Size |
            |:-----|-----:|
            | a.md | 12 |
            | longer.md |
            """
        XCTAssertEqual(MarkdownParser.parse(source), [.table(
            header: ["Name", "Size"],
            rows: [["a.md", "12"], ["longer.md", ""]])])
        // Pipes without a delimiter row are just text.
        XCTAssertEqual(MarkdownParser.parse("a | b"), [.paragraph("a | b")])
    }

    func testTableCellsAreInlineMarkdown() {
        guard case .table(let header, let rows) = MarkdownParser.parse("| **Key** | `v` |\n|---|---|\n| *a* | **b** `c` |").first
        else { return XCTFail() }
        XCTAssertEqual(header.map(shown), ["Key", "v"])
        XCTAssertEqual(rows[0].map(shown), ["a", "b c"], "no raw markers in a cell")
    }

    func testATableNeedsARealDelimiterRow() {
        // `---` under text with a pipe is a setext heading, not a table
        // that eats the pipe.
        XCTAssertEqual(MarkdownParser.parse("Use a | b here\n---"), [.heading(level: 2, text: "Use a | b here")])
        XCTAssertEqual(MarkdownParser.parse("Title\n==="), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownParser.parse("a | b\n|-x-|"), [.paragraph("a | b\n|-x-|")])
        // A delimiter row needs a pipe; with one, a lone column is a table.
        XCTAssertEqual(MarkdownParser.parse("| a |\n| :-: |"), [.table(header: ["a"], rows: [])])
        // A rule after a blank line stays a rule.
        XCTAssertEqual(MarkdownParser.parse("text\n\n---"), [.paragraph("text"), .rule])
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

    func testAClosingHashRunNeedsASpaceBeforeIt() {
        XCTAssertEqual(MarkdownParser.parse("## Why C#"), [.heading(level: 2, text: "Why C#")])
        XCTAssertEqual(MarkdownParser.parse("## Title ##"), [.heading(level: 2, text: "Title")])
        XCTAssertEqual(MarkdownParser.parse("# F# and C# #"), [.heading(level: 1, text: "F# and C#")])
        XCTAssertEqual(MarkdownParser.parse("### ###"), [.heading(level: 3, text: "")])
    }

    func testAFenceUnderAListItemBelongsToIt() {
        let source = """
            1. Build it:
               ```sh
               swift build
                 --verbose
               ```
               Then run it.
            2. Next
            - bullet
              ```
              x
              ```
            """
        XCTAssertEqual(MarkdownParser.parse(source), [
            .list([
                MarkdownListItem(level: 0, number: "1.", text: "Build it:", blocks: [
                    .code(language: "sh", text: "swift build\n  --verbose", closed: true),
                    .paragraph("Then run it."),
                ]),
                MarkdownListItem(level: 0, number: "2.", text: "Next"),
                MarkdownListItem(level: 0, number: nil, text: "bullet", blocks: [.code(language: nil, text: "x", closed: true)]),
            ]),
        ])
    }

    func testAFenceIndentedFourUnderANumberedItemAfterABlankLine() {
        // `10. ` puts the item's text at column 4; a fence at 4 or more
        // (up to 7) is still the item's, not indented code, and the list
        // is not split by it.
        let source = "10. Step\n\n    ```\n    a\n      b\n    ```\n\n11. After\n\n    more of 11"
        XCTAssertEqual(MarkdownParser.parse(source), [
            .list([
                MarkdownListItem(level: 0, number: "10.", text: "Step", blocks: [.code(language: nil, text: "a\n  b", closed: true)]),
                MarkdownListItem(level: 0, number: "11.", text: "After", blocks: [.paragraph("more of 11")]),
            ]),
        ])
        // Streaming: the item's fence is still open.
        XCTAssertEqual(MarkdownParser.parse("- a\n  ```\n  x"), [
            .list([MarkdownListItem(level: 0, number: nil, text: "a", blocks: [.code(language: nil, text: "x", closed: false)])]),
        ])
        // A fence at the margin ends the list.
        XCTAssertEqual(MarkdownParser.parse("- a\n```\nx\n```"), [
            .list([MarkdownListItem(level: 0, number: nil, text: "a")]),
            .code(language: nil, text: "x", closed: true),
        ])
    }

    func testAFenceDropsItsOwnIndentFromItsLines() {
        XCTAssertEqual(MarkdownParser.parse("  ```\n  a\n    b\nc\n  ```"), [
            .code(language: nil, text: "a\n  b\nc", closed: true),
        ])
    }

    func testOnlyAListStartingAtOneInterruptsAParagraph() {
        XCTAssertEqual(MarkdownParser.parse("Released in\n2024. It was good"), [.paragraph("Released in\n2024. It was good")])
        XCTAssertEqual(MarkdownParser.parse("Steps:\n1. one\n2. two"), [
            .paragraph("Steps:"),
            .list([MarkdownListItem(level: 0, number: "1.", text: "one"), MarkdownListItem(level: 0, number: "2.", text: "two")]),
        ])
        XCTAssertEqual(MarkdownParser.parse("Items:\n- one"), [
            .paragraph("Items:"), .list([MarkdownListItem(level: 0, number: nil, text: "one")]),
        ])
        // Not after a paragraph, any number starts a list.
        XCTAssertEqual(MarkdownParser.parse("3. three"), [.list([MarkdownListItem(level: 0, number: "3.", text: "three")])])
    }

    func testAQuoteHoldsBlocks() {
        XCTAssertEqual(MarkdownParser.parse("> - one\n> - two\n>\n> ## Head\n> ```\n> code\n> ```"), [
            .quote([
                .list([MarkdownListItem(level: 0, number: nil, text: "one"), MarkdownListItem(level: 0, number: nil, text: "two")]),
                .heading(level: 2, text: "Head"),
                .code(language: nil, text: "code", closed: true),
            ]),
        ])
        XCTAssertEqual(MarkdownParser.parse("> > nested"), [.quote([.quote([.paragraph("nested")])])])
    }

    @MainActor
    func testParsedBlocksAreCachedByText() {
        let text = "cached \(UUID().uuidString)\n- a\n- b"
        let before = MarkdownCache.parses
        let first = MarkdownCache.blocks(for: text)
        let second = MarkdownCache.blocks(for: text)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, MarkdownParser.parse(text))
        XCTAssertEqual(MarkdownCache.parses - before, 1, "the same text is parsed once")
        _ = MarkdownCache.blocks(for: text + "c")
        XCTAssertEqual(MarkdownCache.parses - before, 2, "a streamed delta is new text")
    }

    // MARK: Copy

    func testCodeCopiesAsFencedWithoutFenceOrTrailingBlankLines() {
        let blocks = MarkdownParser.parse("Example install:\n\n```bash\npip install portico\nportico --help\n\n```\n")
        guard case .code(let language, let text, _) = blocks.last else { return XCTFail("\(blocks)") }
        XCTAssertEqual(language, "bash")
        XCTAssertEqual(MarkdownCopy.code(text), "pip install portico\nportico --help")
    }

    func testCodeInAListItemCopiesWithoutTheItemsIndent() {
        let blocks = MarkdownParser.parse("1. Install it:\n   ```bash\n   pip install portico\n     --upgrade\n   ```\n2. Run it.")
        guard case .list(let items) = blocks.first,
              case .code(_, let text, _) = items.first?.blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(MarkdownCopy.code(text), "pip install portico\n  --upgrade")
    }

    func testMessageCopiesItsMarkdownAsWritten() {
        XCTAssertEqual(MarkdownCopy.message("\n**Done.** See `a.md`:\n\n- one\n\n"), "**Done.** See `a.md`:\n\n- one")
    }

    // MARK: Selectable prose

    func testProseRunsGatherParagraphsHeadsAndPlainListsAroundCode() {
        let blocks = MarkdownParser.parse("## Head\n\nOne.\n\n- a\n- b\n\n```\nx\n```\n\nTwo.")
        let runs = MarkdownRun.split(blocks)
        XCTAssertEqual(runs.count, 3, "\(runs)")
        guard case .prose(let first, true) = runs[0] else { return XCTFail("\(runs[0])") }
        XCTAssertEqual(first.count, 3, "head, paragraph and list in one selectable run")
        guard case .block(.code, false) = runs[1], case .prose(_, false) = runs[2] else { return XCTFail("\(runs)") }
    }

    func testAListWithCodeUnderAnItemIsNotProse() {
        let blocks = MarkdownParser.parse("1. Install:\n   ```bash\n   pip install portico\n   ```\n2. Run it.")
        XCTAssertEqual(MarkdownRun.split(blocks).count, 1)
        guard case .block(.list, true) = MarkdownRun.split(blocks)[0] else { return XCTFail() }
    }

    @MainActor
    func testProseTextReadsAsShownWithMarkersAndSoftBreaks() {
        let text = MarkdownAttributed.prose(MarkdownParser.parse("**Done.** See [docs](https://example.com)\nnext line\n\n- one\n- `two`"))
        XCTAssertEqual(text.string, "Done. See docs\u{2028}next line\n•\tone\n•\ttwo")
        let bold = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bold.map(MarkdownAttributed.weight(of:)), MarkdownAttributed.boldWeight)
        let link = text.attribute(.link, at: (text.string as NSString).range(of: "docs").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.com")
    }

    // MARK: - click elsewhere deselects (v0.5 decision 5)

    @MainActor
    func testAClickOutsideASelectionClearsItAndOneInsideKeepsIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        func message(_ text: String, y: CGFloat) -> SelectableTextView {
            let view = SelectableTextView(frame: NSRect(x: 0, y: y, width: 400, height: 40))
            view.string = text
            view.isEditable = false
            content.addSubview(view)
            return view
        }
        let first = message("The first message", y: 0)
        let second = message("The second message", y: 100)
        let other = NSView(frame: NSRect(x: 0, y: 200, width: 400, height: 40))
        content.addSubview(other)

        first.setSelectedRange(NSRange(location: 4, length: 5))
        SelectableTextView.deselect(in: window, except: first)
        XCTAssertEqual(first.selectedRange().length, 5, "a click inside the selection's own view keeps it")

        SelectableTextView.deselect(in: window, except: second)
        XCTAssertEqual(first.selectedRange().length, 0, "a click on another message clears it")

        first.setSelectedRange(NSRange(location: 4, length: 5))
        SelectableTextView.deselect(in: window, except: other)
        XCTAssertEqual(first.selectedRange().length, 0, "a click on anything else clears it")

        first.setSelectedRange(NSRange(location: 4, length: 5))
        SelectableTextView.deselect(in: window, except: nil)
        XCTAssertEqual(first.selectedRange().length, 0, "so does a click on nothing")

        // A click in another window leaves this one's selection alone.
        first.setSelectedRange(NSRange(location: 4, length: 5))
        let elsewhere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        SelectableTextView.deselect(in: elsewhere, except: nil)
        XCTAssertEqual(first.selectedRange().length, 5)

        // A click on a scroll bar (the transcript's, say) keeps it.
        let scroller = NSScroller(frame: NSRect(x: 385, y: 0, width: 15, height: 300))
        content.addSubview(scroller)
        SelectableTextView.deselect(in: window, except: scroller)
        XCTAssertEqual(first.selectedRange().length, 5, "a click on a scroller keeps the selection")
        window.contentView = nil
    }
}
