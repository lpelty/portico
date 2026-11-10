import XCTest

@testable import Portico

final class ShapeTests: XCTestCase {
    private func json(_ shape: EntryShape) throws -> String {
        String(data: try JSONEncoder().encode(shape), encoding: .utf8)!
    }

    func testReplyShapeCountsBlocksNotText() throws {
        let text = "Hello world.\n\n# Title\n\n- a\n- b\n\n```swift\nlet x = 1\nlet y = 2\n```\n\n| h1 | h2 |\n|---|---|\n| 1 | 2 |"
        let shape = Shape.of(.item(.assistantText(id: "r1", text: text)), imageSize: { _ in nil })
        XCTAssertEqual(shape.kind, .reply)
        XCTAssertEqual(shape.paragraphs, [12])
        XCTAssertEqual(shape.headings, [1])
        XCTAssertEqual(shape.listItems, 2)
        XCTAssertEqual(shape.codeBlocks, [2])
        XCTAssertEqual(shape.tables, [[1, 2]])
        XCTAssertFalse(try json(shape).contains("Hello"))
    }

    func testQuoteCountsOnceAndItsInnerBlocksCountToo() {
        let shape = Shape.of(.item(.assistantText(id: "r2", text: "> quoted words\n\nafter\n\n---")), imageSize: { _ in nil })
        XCTAssertEqual(shape.quotes, 1)
        XCTAssertEqual(shape.paragraphs, [12, 5])
        XCTAssertEqual(shape.rules, 1)
    }

    func testPersonShapeHasImagesAsSizesAndDocumentsAsACount() throws {
        let user = UserText(chat: 1, turn: 1, text: "see these", attachments: ["/Users/x/secret-a.png", "/Users/x/secret-b.JPG", "/Users/x/plan.pdf"])
        let sizes = ["/Users/x/secret-a.png": [640, 480], "/Users/x/secret-b.JPG": [100, 50]]
        let shape = Shape.of(.item(.userText(user)), imageSize: { sizes[$0] })
        XCTAssertEqual(shape.kind, .person)
        XCTAssertEqual(shape.images, [[640, 480], [100, 50]])
        XCTAssertEqual(shape.documents, 1)
        XCTAssertEqual(shape.paragraphs, [9])
        let encoded = try json(shape)
        for leak in ["secret", "plan", "/Users", "see these"] { XCTAssertFalse(encoded.contains(leak), leak) }
    }

    func testUnreadableImageIsRecordedAsZeroByZero() {
        let user = UserText(chat: 1, turn: 1, text: "", attachments: ["/x/a.png"])
        let shape = Shape.of(.item(.userText(user)), imageSize: { _ in nil })
        XCTAssertEqual(shape.images, [[0, 0]])
        XCTAssertEqual(shape.paragraphs, [])
    }

    func testPersonTextIsParagraphsOnBlankLinesNeverMarkdownBlocks() {
        let user = UserText(chat: 1, turn: 1, text: "# not a heading\nsecond line\n\n- not a list")
        let shape = Shape.of(.item(.userText(user)), imageSize: { _ in nil })
        XCTAssertEqual(shape.paragraphs, [27, 12])
        XCTAssertEqual(shape.headings, [])
        XCTAssertEqual(shape.listItems, 0)
    }

    func testDocumentAttachmentIsACountNotAName() throws {
        let user = UserText(chat: 1, turn: 1, text: "", attachments: ["/x/Quarterly Numbers.xlsx", "/x/notes.txt"])
        let shape = Shape.of(.item(.userText(user)), imageSize: { _ in nil })
        XCTAssertEqual(shape.documents, 2)
        XCTAssertEqual(shape.images, [])
        let encoded = try json(shape)
        XCTAssertFalse(encoded.contains("Quarterly"))
        XCTAssertFalse(encoded.contains("xlsx"))
    }

    func testLongLineParagraphMetricIsItsLength() {
        let text = String(repeating: "a", count: 10_000)
        let shape = Shape.of(.item(.assistantText(id: "r3", text: text)), imageSize: { _ in nil })
        XCTAssertEqual(shape.paragraphs, [10_000])
    }

    func testToolRunShapeIsRowCountAndFolded() {
        let rows = (1...4).map { ToolRow(toolUseId: "t\($0)", turn: 1, tool: "Bash", summary: "secret command", input: [:]) }
        for kind in [ToolRunKind.any, .viewer] {
            let shape = Shape.of(.toolRun(kind, rows), imageSize: { _ in nil })
            XCTAssertEqual(shape.kind, .toolRun)
            XCTAssertEqual(shape.toolRows, 4)
            XCTAssertTrue(shape.folded)
        }
        let single = Shape.of(.item(.tool(rows[0])), imageSize: { _ in nil })
        XCTAssertEqual(single.kind, .tool)
        XCTAssertEqual(single.toolRows, 1)
        XCTAssertTrue(single.folded)
    }

    func testIdsAreTheAppsOwn() {
        let entries: [TranscriptEntry] = [
            .item(.assistantText(id: "r9", text: "x")),
            .item(.notice(id: "n1", text: "hush")),
            .item(.compacted(id: "c1", trigger: "auto")),
        ]
        for entry in entries { XCTAssertEqual(Shape.of(entry, imageSize: { _ in nil }).id, entry.id) }
        XCTAssertEqual(Shape.of(entries[1], imageSize: { _ in nil }).kind, .notice)
        XCTAssertEqual(Shape.of(entries[2], imageSize: { _ in nil }).kind, .compacted)
    }
}
