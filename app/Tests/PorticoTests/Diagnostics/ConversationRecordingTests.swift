import XCTest

@testable import Portico

/// v0.26.4 Ruling 14: the recording's structural path reshapes only the tail.
/// Two differential oracles. (1) One recording takes the incremental path; a
/// second, whose `Context` differs on every call, reshapes every entry on every
/// change (the full path); both must write the same events, step by step.
/// (2) Independent of `changed`: a fresh recording started on each state gives
/// that state's whole shape list; the incremental recording's shape and removed
/// events must be exactly the difference between consecutive lists.
@MainActor
final class ConversationRecordingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// One moment of the transcript and what its drawing depends on.
    private struct State {
        var name: String
        var items: [TranscriptItem]
        var briefItem: String? = nil
        var divider = false
        var hidden: Set<String> = []
        var apart: Set<String> = []
        var turn: Int? = nil
    }

    // MARK: Items

    private static func user(_ turn: Int, _ text: String) -> TranscriptItem {
        .userText(UserText(chat: 1, turn: turn, text: text, seq: turn, ts: "2026-11-10T12:00:0\(turn % 10)Z"))
    }

    private static func reply(_ id: String, _ text: String) -> TranscriptItem {
        .assistantText(id: id, text: text)
    }

    private static func tool(_ id: String, turn: Int, name: String = "Bash", finished: Bool = false) -> TranscriptItem {
        var row = ToolRow(toolUseId: id, turn: turn, tool: name, summary: "ls", input: [:])
        row.finished = finished
        return .tool(row)
    }

    private static func viewer(_ id: String, turn: Int) -> TranscriptItem {
        tool(id, turn: turn, name: ViewerSteps.prefix + "click")
    }

    private static func marker(_ turn: Int, _ outcome: Outcome) -> TranscriptItem {
        .turnMarker(TurnMarker(turn: turn, outcome: outcome))
    }

    private static func card(_ id: String) -> TranscriptItem {
        .card(CardAsk(chat: 1, id: id, kind: .question, title: "Which plan?", permission: nil, questions: nil, form: nil))
    }

    // MARK: The sequence

    private static func states() -> [State] {
        let u1 = user(1, "Plan the Acme rollout.\n\nTwo phases.")
        let a1 = reply("a1", "Here is the plan.\n\n- one\n- two")
        let t1 = tool("t1", turn: 1), t2 = tool("t2", turn: 1), t3 = tool("t3", turn: 1)
        let base = [u1, a1]
        var out: [State] = []
        out.append(State(name: "start", items: base, turn: 1))
        out.append(State(name: "one tool row", items: base + [t1], turn: 1))
        out.append(State(name: "two tool rows (no run yet)", items: base + [t1, t2], turn: 1))
        out.append(State(name: "run reaches three", items: base + [t1, t2, t3], turn: 1))
        let c1 = card("c1")
        out.append(State(name: "card inserted into the run", items: base + [t1, c1, t2, t3], turn: 1))
        out.append(State(name: "card removed again", items: base + [t1, t2, t3], turn: 1))
        let m1 = marker(1, .done)  // not drawn: the run goes on across it
        let tx = tool("tx", turn: 2)
        out.append(State(name: "undrawn turn end, then a later turn's row joins the run",
                         items: base + [t1, t2, t3, m1, tx], turn: 2))
        let u2 = user(2, "Now check the page.")
        let v1 = viewer("v1", turn: 2), v2 = viewer("v2", turn: 2)
        let turn1 = base + [t1, t2, t3, m1, tx]
        out.append(State(name: "a viewer step", items: turn1 + [u2, v1], turn: 2))
        out.append(State(name: "viewer run reaches two", items: turn1 + [u2, v1, v2], turn: 2))
        out.append(State(name: "a reply starts", items: turn1 + [u2, v1, v2, reply("a2", "Look")], turn: 2))
        out.append(State(name: "the reply streams", items: turn1 + [u2, v1, v2, reply("a2", "Looks right.\n\nDone")], turn: 2))
        let a2 = reply("a2", "Looks right.\n\nDone")
        let m2 = marker(2, .stopped)  // drawn: splits runs
        out.append(State(name: "a drawn turn end", items: turn1 + [u2, v1, v2, a2, m2], turn: 3))
        let noA1 = [u1, t1, t2, t3, m1, tx, u2, v1, v2, a2, m2]
        out.append(State(name: "a removal in the middle", items: noA1, turn: 3))
        let u3 = user(3, "Start the agents.")
        let t4 = tool("t4", turn: 3)
        out.append(State(name: "a starting row, hidden", items: noA1 + [u3, t4], hidden: ["t4"], turn: 3))
        out.append(State(name: "the starting row shown", items: noA1 + [u3, t4], turn: 3))
        let t5 = tool("t5", turn: 3), t6 = tool("t6", turn: 3)
        let now = noA1 + [u3, t4, t5, t6]
        out.append(State(name: "a run of the new turn", items: now, turn: 3))
        out.append(State(name: "a proposal splits the earlier run", items: now, apart: ["t2"], turn: 3))
        out.append(State(name: "the proposal is gone", items: now, turn: 3))
        out.append(State(name: "the divider appears", items: now, divider: true, turn: 3))
        out.append(State(name: "the divider goes", items: now, turn: 3))
        out.append(State(name: "the brief appears", items: now, briefItem: u1.id, turn: 3))
        out.append(State(name: "the brief goes", items: now, turn: 3))
        out.append(State(name: "the earlier rows finish (no shape changes)",
                         items: [u1, tool("t1", turn: 1, finished: true), t2, t3, m1, tx, u2, v1, v2, a2, m2, u3, t4, t5, t6]
                             + [tool("t7", turn: 3)], turn: 3))
        let reload = [user(9, "Fresh history."), reply("a9", "Reloaded."),
                      tool("r1", turn: 9), tool("r2", turn: 9), tool("r3", turn: 9)]
        out.append(State(name: "a reload replaces every item", items: reload, turn: 9))
        out.append(State(name: "shrink to empty", items: [], turn: nil))
        out.append(State(name: "a message after empty", items: [user(10, "Hello again.")], turn: 10))
        return out
    }

    // MARK: Driving

    private static func drawn(_ state: State, from: Int) -> [TranscriptEntry] {
        let shown = state.items[from...].filter { item in
            guard TurnMarkerView.isDrawn(item) else { return false }
            if case .tool(let row) = item { return !state.hidden.contains(row.toolUseId) }
            return true
        }
        return TranscriptEntry.entries(shown) { state.apart.contains($0.toolUseId) }
    }

    private static func itemsKey(_ state: State, step: Int) -> String {
        guard let last = state.items.last else { return "empty:\(step)" }
        if case .assistantText(let id, let text, _) = last { return "\(state.items.count):\(id):\(text.count)" }
        return "\(state.items.count):\(last.id):\(step)"
    }

    /// The snapshot of `state`; `full` makes `Context` differ on every call
    /// (a tool id no item has, counting up), so every change reshapes all.
    private static func snapshot(_ state: State, step: Int, full: Bool, calls: Counter) -> ConversationRecording.Snapshot {
        ConversationRecording.Snapshot(
            items: state.items, itemsKey: itemsKey(state, step: step), docked: nil, currentTurn: state.turn,
            context: {
                var hidden = state.hidden
                if full {
                    calls.value += 1
                    hidden.insert("no-such-row-\(calls.value)")
                }
                return ConversationRecording.Context(
                    briefItem: state.briefItem, divider: state.divider, hidden: hidden, apart: state.apart)
            },
            drawn: { drawn(state, from: $0) })
    }

    private final class Counter { var value = 0 }

    private static let open = RecordingEvent.open(
        chat: 1, appVersion: "0.26.4", macOS: "27.0", window: [1000, 700], column: 640,
        viewerVisible: false, viewerWidth: 0, sidebarVisible: true, textScale: 1)

    /// Written between steps so one file splits into each step's events.
    private static func boundary(_ step: Int) -> RecordingEvent { .removed(id: "oracle-step-\(step)") }

    /// Each step's events, for one recording.
    private func run(full: Bool, states: [State]) throws -> [[RecordingEvent]] {
        let recording = ConversationRecording()
        var clock: TimeInterval = 100
        recording.now = { clock }
        let calls = Counter()
        let recorder = Recorder(chat: 1, directory: root.appendingPathComponent(full ? "full" : "incremental"))
        for (step, state) in states.enumerated() {
            clock += 1
            let snapshot = Self.snapshot(state, step: step, full: full, calls: calls)
            if step == 0 {
                recording.start(recorder, open: Self.open, window: [1000, 700], snapshot: snapshot)
            } else {
                recording.changed(snapshot)
            }
            recording.note(Self.boundary(step))
        }
        recorder.close()
        var perStep: [[RecordingEvent]] = [[]]
        for event in try Recorder.read(recorder.url).events.map(\.event) {
            if case .removed(let id) = event, id.hasPrefix("oracle-step-") {
                perStep.append([])
            } else {
                perStep[perStep.count - 1].append(event)
            }
        }
        perStep.removeLast()
        return perStep
    }

    /// Every shape a fresh recording writes when it starts on `state`, in order.
    private func freshShapes(_ state: State, step: Int) throws -> [EntryShape] {
        let recording = ConversationRecording()
        let recorder = Recorder(chat: 1, directory: root.appendingPathComponent("fresh-\(step)"))
        recording.start(recorder, open: Self.open, window: [1000, 700],
                        snapshot: Self.snapshot(state, step: step, full: false, calls: Counter()))
        recorder.close()
        return try Recorder.read(recorder.url).events.compactMap { if case .shape(let s) = $0.event { s } else { nil } }
    }

    func testShapesAndRemovalsAreTheDifferenceBetweenWholeShapeLists() throws {
        let states = Self.states()
        let incremental = try run(full: false, states: states)
        var before = try freshShapes(states[0], step: 0)
        for index in 1..<states.count {
            let now = try freshShapes(states[index], step: index)
            let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ids = Set(now.map(\.id))
            let expected: [RecordingEvent] = now.filter { old[$0.id] != $0 }.map { .shape($0) }
                + before.filter { !ids.contains($0.id) }.map { .removed(id: $0.id) }
            let written = incremental[index].filter {
                switch $0 {
                case .shape, .removed: true
                default: false
                }
            }
            XCTAssertEqual(written, expected, "step \(index): \(states[index].name)")
            before = now
        }
    }

    func testIncrementalPathWritesWhatAFullReshapeWrites() throws {
        let states = Self.states()
        let incremental = try run(full: false, states: states)
        let full = try run(full: true, states: states)
        XCTAssertEqual(incremental.count, full.count)
        for (index, state) in states.enumerated() {
            XCTAssertEqual(incremental[index], full[index], "step \(index): \(state.name)")
        }
        // The sequence reaches what Ruling 14 changed: runs forming and splitting,
        // rows removed, the divider and brief, a reload.
        let all = incremental.flatMap { $0 }
        let shapes = all.compactMap { if case .shape(let s) = $0 { s } else { nil } }
        let removed = Set(all.compactMap { if case .removed(let id) = $0 { id } else { nil } })
        XCTAssertTrue(shapes.contains { $0.id == "tool-run:t1" && $0.toolRows == 3 }, "the run of three")
        XCTAssertTrue(shapes.contains { $0.id == "tool-run:t1" && $0.toolRows == 4 }, "the run across the undrawn turn end")
        XCTAssertTrue(shapes.contains { $0.id == "tool-run:v1" && $0.toolRows == 2 }, "the viewer run of two")
        XCTAssertTrue(shapes.contains { $0.kind == .divider }, "the divider")
        XCTAssertTrue(shapes.contains { $0.kind == .brief }, "the brief")
        for id in ["tool:t1", "tool:t2", "card:c1", "assistant:a1", "divider", "brief", "tool-run:t1"] {
            XCTAssertTrue(removed.contains(id), "removed \(id)")
        }
        XCTAssertTrue(removed.contains("tool-run:r1"), "everything removed on shrinking to empty")
        XCTAssertTrue(incremental.last?.contains { if case .shape(let s) = $0 { s.kind == .person } else { false } } ?? false)
    }
}
