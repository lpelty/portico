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

    // MARK: v0.14 - the Mark row

    func test_the_mark_row_is_not_folded() {
        let three = TranscriptEntry.entries([step("a", "look"), step("m", "mark"), step("c", "look")])
        XCTAssertEqual(three.map(\.id), ["tool:a", "tool:m", "tool:c"])
        let run = TranscriptEntry.entries([step("a", "look"), step("b", "look"), step("m", "mark"), step("c", "click")])
        XCTAssertEqual(run.count, 3)
        guard case .viewerSteps(let rows) = run[0] else { return XCTFail("\(run)") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(run[1].id, "tool:m")
        XCTAssertEqual(run[2].id, "tool:c")
    }

    func test_clear_marks_folds_and_reads() {
        let entries = TranscriptEntry.entries([step("a", "look"), step("b", "clear_marks")])
        guard case .viewerSteps(let rows) = entries.first else { return XCTFail("\(entries)") }
        XCTAssertEqual(ViewerSteps.verb(rows[1]), "Clear marks")
        XCTAssertEqual(ViewerSteps.markTool, "mcp__portico__viewer_mark")
    }

    private func markRow(count: Int?) -> ToolRow {
        var input: [String: JSONValue] = [:]
        if let count { input["marks"] = .array((0..<count).map { _ in .object(["target": .string("Start")]) }) }
        return ToolRow(toolUseId: "tu1", turn: 1, tool: ViewerSteps.markTool, summary: "", input: input)
    }

    private func call(_ n: Int, pages: [String] = ["trail-detail.html"]) -> MarkCall {
        let marks = (0..<n).map { i in
            let name = pages[min(i, pages.count - 1)]
            return Mark(number: i + 1, page: MarkPage(key: "/tmp/\(name)", name: name), note: "", label: "x",
                        locator: MarkLocator(path: "", tag: "a", text: "x"), found: true, call: "c1")
        }
        return MarkCall(id: "c1", toolUseId: "tu1", marks: marks)
    }

    func test_mark_row_text() {
        let three = MarkRowPresentation(row: markRow(count: 3), call: call(3))
        XCTAssertEqual(three.text, "Mark \u{B7} trail-detail.html \u{B7} 3 areas")
        XCTAssertTrue(three.showsShowAgain)
        XCTAssertEqual(MarkRowPresentation(row: markRow(count: 1), call: call(1)).text, "Mark \u{B7} trail-detail.html \u{B7} 1 area")
        let spanning = MarkRowPresentation(row: markRow(count: 2), call: call(2, pages: ["a.html", "b.html"]))
        XCTAssertEqual(spanning.text, "Mark \u{B7} a.html \u{B7} 2 areas")
        let resumed = MarkRowPresentation(row: markRow(count: 3), call: nil)
        XCTAssertEqual(resumed.text, "Mark \u{B7} 3 areas")
        XCTAssertFalse(resumed.showsShowAgain)
        XCTAssertEqual(MarkRowPresentation(row: markRow(count: nil), call: nil).text, "Mark")
    }
}
