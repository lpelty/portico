import XCTest

@testable import Portico

/// v0.13 decision 1: tool rows that follow each other close up; the space
/// around them, and between everything else, is unchanged.
final class TranscriptSpacingTests: XCTestCase {
    private func tool(_ id: String) -> TranscriptItem {
        .tool(ToolRow(toolUseId: id, turn: 1, tool: "mcp__portico__viewer_look", summary: "", input: [:]))
    }

    func test_consecutive_tool_rows_sit_two_points_apart() {
        XCTAssertEqual(TranscriptSpacing.gap(before: tool("b"), after: tool("a")), 2)
    }

    func test_the_space_around_a_block_of_tool_rows_is_unchanged() {
        let user = TranscriptItem.userText(UserText(chat: 1, turn: 1, text: "Check Start trail"))
        let reply = TranscriptItem.assistantText(id: "r", text: "It works.")
        XCTAssertEqual(TranscriptSpacing.gap(before: tool("a"), after: user), 20)
        XCTAssertEqual(TranscriptSpacing.gap(before: reply, after: tool("a")), 20)
        XCTAssertEqual(TranscriptSpacing.gap(before: reply, after: user), 20)
    }
}
