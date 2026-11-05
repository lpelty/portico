import XCTest

@testable import Portico

/// v0.19 §7: runs of three or more tool rows fold; failures stay out.
final class ToolRunTests: XCTestCase {
    private func row(_ id: String, _ name: String = "Bash", summary: String = "", finished: Bool = true, ok: Bool? = true) -> ToolRow {
        var r = ToolRow(toolUseId: id, turn: 1, tool: name, summary: summary, input: [:])
        r.finished = finished
        r.ok = ok
        return r
    }
    private func items(_ rows: [ToolRow]) -> [TranscriptItem] { rows.map { .tool($0) } }
    private let reply = TranscriptItem.assistantText(id: "r", text: "Done.")

    func test_two_rows_do_not_fold_three_do_and_seven_make_one() {
        XCTAssertEqual(TranscriptEntry.entries(items([row("a"), row("b")])).map(\.id), ["tool:a", "tool:b"])
        XCTAssertEqual(TranscriptEntry.entries(items([row("a"), row("b"), row("c")])).map(\.id), ["tool-run:a"])
        let seven = TranscriptEntry.entries(items((0..<7).map { row("t\($0)") }))
        XCTAssertEqual(seven.count, 1)
        guard case .toolRun(.any, let rows) = seven[0] else { return XCTFail("\(seven)") }
        XCTAssertEqual(rows.count, 7)
    }

    func test_a_viewer_run_of_two_still_folds_as_the_viewer() {
        let e = TranscriptEntry.entries(items([row("a", "mcp__portico__viewer_look"), row("b", "mcp__portico__viewer_click")]))
        guard case .toolRun(.viewer, let rows) = e.first else { return XCTFail("\(e)") }
        XCTAssertEqual(rows.count, 2)
    }

    func test_mixed_run_is_any_unless_every_row_is_a_viewer_step() {
        let mixed = TranscriptEntry.entries(items([row("a", "mcp__portico__viewer_look"), row("b"), row("c", "mcp__portico__viewer_look")]))
        guard case .toolRun(.any, _) = mixed.first else { return XCTFail("\(mixed)") }
        let allViewer = TranscriptEntry.entries(items((0..<3).map { row("v\($0)", "mcp__portico__viewer_look") }))
        guard case .toolRun(.viewer, _) = allViewer.first else { return XCTFail("\(allViewer)") }
    }

    func test_a_question_or_a_proposal_card_splits_runs() {
        let q = row("q", QuestionRecord.tool)
        let e = TranscriptEntry.entries(items([row("a"), row("b"), q, row("c"), row("d")]))
        XCTAssertEqual(e.map(\.id), ["tool:a", "tool:b", "tool:q", "tool:c", "tool:d"])
        let split = TranscriptEntry.entries(items([row("a"), row("b"), row("c"), row("p"), row("d"), row("e"), row("f")])) { $0.toolUseId == "p" }
        XCTAssertEqual(split.map(\.id), ["tool-run:a", "tool:p", "tool-run:d"])
        let withReply = TranscriptEntry.entries([.tool(row("a")), .tool(row("b")), reply, .tool(row("c"))])
        XCTAssertEqual(withReply.count, 4)
    }

    func test_titles() {
        XCTAssertEqual(ToolRunPresentation.title(kind: .any, running: true, count: 3), "Working \u{B7} 3 steps")
        XCTAssertEqual(ToolRunPresentation.title(kind: .any, running: false, count: 7), "Ran 7 steps")
        XCTAssertEqual(ToolRunPresentation.title(kind: .viewer, running: true, count: 2), "Using the viewer")
        XCTAssertEqual(ToolRunPresentation.title(kind: .viewer, running: false, count: 2), "Used the viewer")
    }

    func test_summary_order_once_and_plus_n() {
        let rows = ["Read", "Bash", "Bash", "Read", "Bash", "Edit", "Grep", "Glob"].enumerated().map { row("t\($0.offset)", $0.element) }
        // Bash x3, Read x2, then Edit (first of the singles); Grep and Glob are the +2.
        XCTAssertEqual(ToolRunPresentation.summary(rows), "Bash \u{D7}3 \u{B7} Read \u{D7}2 \u{B7} Edit \u{B7} +2")
        XCTAssertEqual(ToolRunPresentation.summary([row("a", "Edit"), row("b", "Bash"), row("c", "Bash")]), "Bash \u{D7}2 \u{B7} Edit")
        XCTAssertEqual(ToolRunPresentation.summary([row("a", "mcp__memory__query_documents"), row("b", "mcp__memory__query_documents")]), "memory \u{B7} query documents \u{D7}2")
    }

    func test_outside_returns_only_troubled_rows_in_order() {
        var declined = row("d")
        declined.permission = .declined
        var blocked = row("k")
        blocked.permission = .blocked
        let rows = [row("a"), row("f", ok: false), row("b"), declined, blocked]
        XCTAssertEqual(ToolRunPresentation.outside(rows).map(\.toolUseId), ["f", "d", "k"])
        XCTAssertTrue(ToolRunPresentation.outside([row("a")]).isEmpty)
    }

    func test_a_running_group_shows_the_newest_rows_line() {
        let rows = [row("a"), row("b"), row("c", "Read", summary: "src/app.ts", finished: false, ok: nil)]
        XCTAssertTrue(ToolRunPresentation.running(rows))
        XCTAssertEqual(ToolRunPresentation.latest(rows, kind: .any), "Read \u{B7} src/app.ts")
    }
}
