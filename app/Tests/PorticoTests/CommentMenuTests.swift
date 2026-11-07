import XCTest

@testable import Portico

/// v0.23: the viewer's own context menu: Comment, then Cut, Copy, Paste,
/// then Select All, with the rules for what is enabled and why not.
final class CommentMenuTests: XCTestCase {
    private func item(_ items: [CommentMenu.Item], _ title: String) -> CommentMenu.Item? {
        items.first { $0.title == title }
    }

    func testOrderAndShortcuts() {
        let items = CommentMenu.items(.init(editMode: true, hasSelection: true, readOnly: nil, refusal: nil))
        XCTAssertEqual(items.map { $0.isDivider ? "-" : $0.title }, ["Comment", "-", "Cut", "Copy", "Paste", "-", "Select All"])
        XCTAssertEqual(item(items, "Comment")?.symbol, "plus.bubble")
        XCTAssertEqual(item(items, "Cut")?.key, "x")
        XCTAssertEqual(item(items, "Copy")?.key, "c")
        XCTAssertEqual(item(items, "Paste")?.key, "v")
        XCTAssertEqual(item(items, "Select All")?.key, "a")
        XCTAssertTrue(items.filter { !$0.isDivider }.allSatisfy(\.enabled))
    }

    func testReadingModeCutPasteDisabled() {
        let items = CommentMenu.items(.init(editMode: false, hasSelection: true, readOnly: nil, refusal: nil))
        XCTAssertEqual(item(items, "Cut")?.enabled, false)
        XCTAssertEqual(item(items, "Paste")?.enabled, false)
        XCTAssertEqual(item(items, "Copy")?.enabled, true)
        XCTAssertEqual(item(items, "Comment")?.enabled, true)
    }

    func testNoSelectionCommentDisabledWithTip() {
        let items = CommentMenu.items(.init(editMode: false, hasSelection: false, readOnly: "Read-only.", refusal: "Nope."))
        XCTAssertEqual(item(items, "Comment")?.enabled, false)
        XCTAssertEqual(item(items, "Comment")?.tip, "Select text to comment on it.")
        XCTAssertEqual(item(items, "Copy")?.enabled, false)
        XCTAssertEqual(item(items, "Select All")?.enabled, true)
    }

    func testReadOnlyReasonIsTip() {
        let items = CommentMenu.items(.init(editMode: false, hasSelection: true, readOnly: "Read-only.", refusal: "Nope."))
        XCTAssertEqual(item(items, "Comment")?.enabled, false)
        XCTAssertEqual(item(items, "Comment")?.tip, "Read-only.")
    }

    func testRefusalReasonIsTip() {
        let items = CommentMenu.items(.init(editMode: false, hasSelection: true, readOnly: nil, refusal: "Nope."))
        XCTAssertEqual(item(items, "Comment")?.enabled, false)
        XCTAssertEqual(item(items, "Comment")?.tip, "Nope.")
    }
}
