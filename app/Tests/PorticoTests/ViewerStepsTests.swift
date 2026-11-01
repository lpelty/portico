import XCTest

@testable import Portico

/// v0.13 decision 8 (Pen AL5): two or more viewer steps in a row fold into one row.
final class ViewerStepsTests: XCTestCase {
    private func step(_ id: String, _ action: String, _ summary: String = "", finished: Bool = true, ok: Bool? = true) -> TranscriptItem {
        var row = ToolRow(toolUseId: id, turn: 1, tool: "mcp__portico__viewer_\(action)", summary: summary, input: [:])
        row.finished = finished
        row.ok = ok
        return .tool(row)
    }
    private func tool(_ id: String, _ name: String) -> TranscriptItem {
        .tool(ToolRow(toolUseId: id, turn: 1, tool: name, summary: "", input: [:]))
    }
    private let reply = TranscriptItem.assistantText(id: "r", text: "Done.")

    func test_a_run_of_two_or_more_viewer_steps_folds() {
        let entries = TranscriptEntry.entries([step("a", "look"), step("b", "click", "Start trail"), step("c", "look"), reply])
        XCTAssertEqual(entries.count, 2)
        guard case .viewerSteps(let rows) = entries[0] else { return XCTFail("\(entries)") }
        XCTAssertEqual(rows.map(\.toolUseId), ["a", "b", "c"])
        XCTAssertEqual(entries[0].id, "viewer-steps:a", "the id holds while the run grows")
    }

    func test_one_step_alone_and_other_tools_stay_rows() {
        let entries = TranscriptEntry.entries([
            step("a", "look"), reply,
            tool("s", "mcp__portico__show_in_viewer"), step("b", "click"), tool("x", "Bash"), step("c", "look"),
        ])
        XCTAssertEqual(entries.map(\.id), ["tool:a", "assistant:r", "tool:s", "tool:b", "tool:x", "tool:c"])
    }

    func test_the_folded_row_reads_title_count_and_latest_step() {
        guard case .tool(let a) = step("a", "look"), case .tool(let b) = step("b", "click", "Start trail"),
            case .tool(let c) = step("c", "scroll", finished: false, ok: nil)
        else { return XCTFail() }
        XCTAssertEqual(ViewerSteps.title([a, b]), "Used the viewer")
        XCTAssertEqual(ViewerSteps.count([a, b]), "2 steps")
        XCTAssertEqual(ViewerSteps.latest([a, b]), "Click · Start trail")
        XCTAssertEqual(ViewerSteps.title([a, b, c]), "Using the viewer", "live while a step runs")
        XCTAssertFalse(ViewerSteps.troubled([a, b]))
    }

    func test_a_refused_step_marks_the_folded_row() {
        guard case .tool(let a) = step("a", "look"), case .tool(let b) = step("b", "click", "Learn more", ok: false)
        else { return XCTFail() }
        XCTAssertTrue(ViewerSteps.troubled([a, b]))
    }

    func test_a_folded_run_closes_up_against_tool_rows() {
        let run = TranscriptEntry.viewerSteps([])
        XCTAssertEqual(TranscriptSpacing.gap(before: run, after: .item(tool("x", "Bash"))), 2)
        XCTAssertEqual(TranscriptSpacing.gap(before: .item(reply), after: run), 20)
    }
}
