import Foundation
import XCTest

@testable import Portico

/// v0.23: anchoring a selection made in reading mode. The page reports the
/// selected text, its block's source lines and which occurrence it is; the
/// Markdown source is the truth the anchor is found in.
final class CommentAnchoringTests: XCTestCase {
    private func slice(_ text: String, _ r: Range<Int>) -> String {
        String(decoding: Array(text.utf16)[r], as: UTF16.self)
    }

    func testLocatesSecondOccurrenceInBlock() throws {
        let source = "The cat.\n\nThe cat sat with the cat.\n"
        let r = try CommentAnchoring.locate(.init(text: "cat", lines: 2...2, occurrence: 1), in: source).get()
        XCTAssertEqual(r, 31..<34)
        XCTAssertEqual(slice(source, r), "cat")
        let first = try CommentAnchoring.locate(.init(text: "cat", lines: 2...2, occurrence: 0), in: source).get()
        XCTAssertEqual(first, 14..<17, "the block's own first, not the file's")
    }

    func testSelectionAcrossBoldEdgeRefused() {
        let result = CommentAnchoring.locate(.init(text: "bold text", lines: 0...0, occurrence: 0), in: "Some **bold** text.\n")
        guard case .failure(let refusal) = result else { return XCTFail("anchored across a bold edge") }
        XCTAssertEqual(CommentAnchoring.reason(refusal), "Select text within one paragraph, outside links and formatting.")
    }

    func testInsideInlineCodeRefused() {
        let result = CommentAnchoring.locate(.init(text: "make build", lines: 0...0, occurrence: 0), in: "Run `make build` now.\n")
        XCTAssertEqual(result, .failure(.insideIgnored))
        XCTAssertEqual(CommentAnchoring.reason(.insideIgnored), "Comments can't go in code, tables or front matter.")
    }

    func testOverlapsExistingAnchor() throws {
        let source = try CommentFormatTests.read("continuation.md")
        let r = try CommentAnchoring.locate(.init(text: "an agent write", lines: 0...0, occurrence: 0), in: source).get()
        XCTAssertEqual(CommentFormat.stripMarkers(slice(source, r)), "an agent write")
    }

    func testWrappedBlockquoteSelection() throws {
        let source = try CommentFormatTests.read("quote-wrap.md")
        let r = try CommentAnchoring.locate(
            .init(text: "thread, and the\nperson", lines: 0...2, occurrence: 0), in: source
        ).get()
        XCTAssertEqual(slice(source, r), "thread, and the\n> person")
    }

    func testFrontMatterOffsetApplied() throws {
        let source = try CommentFormatTests.read("front-matter.md")
        XCTAssertEqual(MarkdownPage.bodyLine(source), 3)
        let r = try CommentAnchoring.locate(.init(text: "Body", lines: 4...4, occurrence: 0), in: source).get()
        XCTAssertEqual(slice(source, r), "Body")
        XCTAssertEqual(
            CommentAnchoring.locate(.init(text: "Not a comment", lines: 1...1, occurrence: 0), in: source),
            .failure(.insideIgnored))
    }

    func testOutsideTheBlockIsNotFound() {
        let source = "Alpha one.\n\nBeta two.\n"
        XCTAssertEqual(
            CommentAnchoring.locate(.init(text: "Alpha", lines: 2...2, occurrence: 0), in: source), .failure(.notFound))
    }

    func testCJKSelectionIsAnchoredExactly() throws {
        let source = "日本語の文章です\n"
        let r = try CommentAnchoring.locate(.init(text: "文章", lines: 0...0, occurrence: 0), in: source).get()
        XCTAssertEqual(slice(source, r), "文章")
    }

    func testCombiningMarksStayWithTheirBase() throws {
        let source = "an e\u{301}tude here\n"
        // "\u{301}tude": the selection began after the base letter.
        let r = try CommentAnchoring.locate(.init(text: "\u{301}tude", lines: 0...0, occurrence: 0), in: source).get()
        XCTAssertEqual(slice(source, r), "e\u{301}tude")
        XCTAssertEqual(CommentFormat.snapSelection(source, 4..<5), 3..<9)
    }

    func testSelectionSnapTakesWholeGraphemeClusters() {
        let text = "ok 👍🏽 and 👨‍👩‍👧 and 🇯🇵 end"
        func range(_ needle: String, _ length: Int) -> Range<Int> {
            let start = text.utf16.distance(from: text.utf16.startIndex, to: text.range(of: needle)!.lowerBound.samePosition(in: text.utf16)!)
            return start..<(start + length)
        }
        for needle in ["👍🏽", "👨‍👩‍👧", "🇯🇵"] {
            let r = range(needle, 2)
            let snapped = CommentFormat.snapSelection(text, r)
            XCTAssertEqual(String(decoding: Array(text.utf16)[snapped], as: UTF16.self), needle)
        }
    }

    // MARK: - table cells (spec §13)

    func testLocatesInsideATableCell() throws {
        let source = try CommentFormatTests.read("table.md")
        let r = try CommentAnchoring.locate(.init(text: "10", lines: 2...5, occurrence: 0, cell: 2, row: 1), in: source).get()
        XCTAssertEqual(slice(source, r), "10")
        let header = try CommentAnchoring.locate(.init(text: "Size", lines: 2...5, occurrence: 0, cell: 2, row: 0), in: source).get()
        XCTAssertEqual(slice(source, header), "Size")
    }

    func testCellWithAnEscapedPipeKeepsItWhole() throws {
        let source = try CommentFormatTests.read("table.md")
        let r = try CommentAnchoring.locate(.init(text: "a | b", lines: 2...5, occurrence: 0, cell: 1, row: 1), in: source).get()
        XCTAssertEqual(slice(source, r), "a \\| b")
        let tail = try CommentAnchoring.locate(.init(text: "| b", lines: 2...5, occurrence: 0, cell: 1, row: 1), in: source).get()
        XCTAssertEqual(slice(source, tail), "\\| b", "a marker never splits \\|")
    }

    func testCellSelectionIsSearchedInItsCellOnly() {
        let source = (try? CommentFormatTests.read("table.md")) ?? ""
        XCTAssertEqual(CommentAnchoring.locate(.init(text: "alpha", lines: 2...5, occurrence: 0, cell: 1, row: 1), in: source), .failure(.notFound))
        XCTAssertEqual(CommentAnchoring.cellWords, "Select text within one cell.")
    }

    func testInlineCodeInACellIsRefused() throws {
        let source = try CommentFormatTests.read("table.md")
        XCTAssertEqual(
            CommentAnchoring.locate(.init(text: "code", lines: 2...5, occurrence: 0, cell: 1, row: 2), in: source), .failure(.insideIgnored))
    }

    func testATableInsideAListItemIsFoundByItsRow() throws {
        let source = try CommentFormatTests.read("table-in-list.md")
        let r = try CommentAnchoring.locate(.init(text: "y", lines: 0...4, occurrence: 0, cell: 1, row: 1), in: source).get()
        XCTAssertEqual(slice(source, r), "y")
    }
}
