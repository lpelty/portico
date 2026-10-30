import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.11 items 58, 59 and 73 (frames AG1 and AG7 option E): the reading
/// column's measures, a failed tool row's words, and the replies' type.
@MainActor
final class ConversationColumnTests: XCTestCase {

    // MARK: - the column (58)

    func testTheColumnIsAtMost768AndOtherwiseTheWholeWidthLessTheInsets() {
        XCTAssertEqual(ConversationColumn.width(available: 1400, sideInset: 32), 768, "a wide window: the desktop app's measure")
        XCTAssertEqual(ConversationColumn.width(available: 832, sideInset: 32), 768, "exactly the column and its insets")
        XCTAssertEqual(ConversationColumn.width(available: 600, sideInset: 32), 536, "narrower: all of it, less the insets")
        XCTAssertEqual(ConversationColumn.width(available: 40, sideInset: 32), 0, "never negative")
        XCTAssertEqual(ConversationColumn.outerWidth(sideInset: 32), 832)
    }

    func testRepliesTake92PercentAndTheBubbleAtMost70() {
        // AG1: 707 and 538 in the 768 column.
        XCTAssertEqual(ConversationColumn.replyWidth(column: 768), 707)
        XCTAssertEqual(ConversationColumn.bubbleMaxWidth(column: 768), 538)
        XCTAssertEqual(ConversationColumn.replyWidth(column: 500), 460)
        XCTAssertEqual(ConversationColumn.bubbleMaxWidth(column: 500), 350)
        XCTAssertEqual(UserBubble.fallbackMaxWidth, 538, "before the column is measured: the widest column's")
    }

    // MARK: - tool rows (59)

    func testAFailedRowCarriesItsWordsAndNoOtherRowDoes() {
        var row = ToolRow(toolUseId: "t", turn: 1, tool: "Bash", summary: "launchctl getenv PATH", input: [:])
        XCTAssertNil(ToolRowPresentation(row: row).failureDetail, "running")
        row.finished = true
        row.ok = true
        row.result = "214 lines"
        XCTAssertNil(ToolRowPresentation(row: row).failureDetail, "done")
        row.ok = false
        row.result = "exit 1 · not found\n"
        XCTAssertEqual(ToolRowPresentation(row: row).failureDetail, "exit 1 · not found")
        row.result = "  "
        XCTAssertNil(ToolRowPresentation(row: row).failureDetail, "failed with no words: the red × says it")
    }

    // MARK: - body text (73)

    func testRepliesAre16PointRegularWithBoldAVisibleStepUp() throws {
        XCTAssertEqual(MarkdownText.bodySize, 16)
        let text = MarkdownAttributed.prose(MarkdownParser.parse("**npx and node** are missing."))
        let bold = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let plain = try XCTUnwrap(text.attribute(.font, at: text.length - 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plain.pointSize, 16)
        XCTAssertEqual(bold.pointSize, 16)
        XCTAssertEqual(MarkdownAttributed.weight(of: plain), .regular)
        XCTAssertEqual(MarkdownAttributed.weight(of: bold), MarkdownAttributed.boldWeight)
        XCTAssertGreaterThan(MarkdownAttributed.boldWeight.rawValue, NSFont.Weight.medium.rawValue)
    }

    func testBoldInAHeadGoesAStepFurtherAndItalicStaysItalic() throws {
        let head = MarkdownAttributed.prose(MarkdownParser.parse("## A **bold** head"))
        let inHead = try XCTUnwrap(head.attribute(.font, at: (head.string as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(MarkdownAttributed.weight(of: inHead), .bold)

        let both = MarkdownAttributed.prose(MarkdownParser.parse("***both***"))
        let font = try XCTUnwrap(both.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertGreaterThan(MarkdownAttributed.weight(of: font).rawValue, NSFont.Weight.regular.rawValue)
    }

    func testListMarkersAreFullSizeInTheTextColour() throws {
        let text = MarkdownAttributed.prose(MarkdownParser.parse("- one\n- two"))
        let marker = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(marker.pointSize, MarkdownText.bodySize)
        let markerColour = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let wordColour = text.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(markerColour)
        XCTAssertEqual(markerColour, wordColour, "the bullet is in the words' colour, not the tertiary one")
    }
}
