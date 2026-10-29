import Foundation
import XCTest

@testable import Portico

/// v0.10: subagents in a tray, workflows in a box, the record after the
/// turn (design/portico.pen row AF). The frames decode, the client hello
/// names `agents.v1`, the reducer keeps each chat's agents, and the
/// tray's, box's and record's words read as the design has them. No window.
@MainActor
final class AgentActivityTests: XCTestCase {

    // MARK: - frames

    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    func testAgentStartedDecodes() throws {
        let message = try decode(#"""
            {"type":"agent.started","chat":1,"turn":2,"id":"a1","tool_use_id":"toolu_1",
             "description":"Checking quotes","kind":"subagent","seq":5,"ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .agentStarted(let started) = message else { return XCTFail("got \(message)") }
        XCTAssertEqual(started.id, "a1")
        XCTAssertEqual(started.toolUseId, "toolu_1")
        XCTAssertEqual(started.description, "Checking quotes")
        XCTAssertEqual(started.kind, "subagent")
        XCTAssertNil(started.workflowId)
        XCTAssertNil(started.phase)
        XCTAssertEqual(message.envelope, Envelope(chat: 1, id: "a1", seq: 5))
    }

    func testAgentStartedInAWorkflowTakesThePhaseAsIndexOrName() throws {
        let byIndex = try decode(#"""
            {"type":"agent.started","chat":1,"turn":2,"id":"a1","tool_use_id":"t","description":"d",
             "kind":"subagent","workflow_id":"w1","phase":1,"ts":"2026-10-27T12:00:00Z"}
            """#)
        let byName = try decode(#"""
            {"type":"agent.started","chat":1,"turn":2,"id":"a2","tool_use_id":"t","description":"d",
             "kind":"subagent","workflow_id":"w1","phase":"Verify","ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .agentStarted(let a) = byIndex, case .agentStarted(let b) = byName else { return XCTFail() }
        XCTAssertEqual(a.workflowId, "w1")
        XCTAssertEqual(a.phase, .index(1))
        XCTAssertEqual(b.phase, .name("Verify"))
        // Each form encodes back as it came.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(byName)) as? [String: Any]
        XCTAssertEqual(encoded?["phase"] as? String, "Verify")
    }

    func testAgentProgressDecodesWithAndWithoutAStep() throws {
        let withStep = try decode(#"""
            {"type":"agent.progress","chat":1,"id":"a1","step":"Reading p11.md","steps":9,"elapsed":38,"ts":"2026-10-27T12:00:00Z"}
            """#)
        let without = try decode(#"""
            {"type":"agent.progress","chat":1,"id":"a1","steps":10,"elapsed":40.5,"ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .agentProgress(let a) = withStep, case .agentProgress(let b) = without else { return XCTFail() }
        XCTAssertEqual(a.step, "Reading p11.md")
        XCTAssertEqual(a.steps, 9)
        XCTAssertEqual(a.elapsed, 38)
        XCTAssertNil(b.step)
        XCTAssertEqual(b.elapsed, 40.5)
    }

    func testAgentFinishedDecodesEachOutcome() throws {
        for word in ["done", "failed", "stopped"] {
            let message = try decode(#"{"type":"agent.finished","chat":1,"id":"a1","outcome":"\#(word)","ts":"2026-10-27T12:00:00Z"}"#)
            guard case .agentFinished(let finished) = message else { return XCTFail("got \(message)") }
            XCTAssertEqual(finished.outcome.rawValue, word)
            XCTAssertNil(finished.summary)
        }
    }

    func testWorkflowFramesDecode() throws {
        let started = try decode(#"""
            {"type":"workflow.started","chat":1,"id":"w1","name":"Review","phases":["Review","Verify"],"ts":"2026-10-27T12:00:00Z"}
            """#)
        let noPhases = try decode(#"""
            {"type":"workflow.started","chat":1,"id":"w2","name":"Sweep","phases":[],"ts":"2026-10-27T12:00:00Z"}
            """#)
        let phase = try decode(#"""
            {"type":"workflow.phase","chat":1,"id":"w1","index":0,"state":"running","ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .workflowStarted(let w) = started, case .workflowStarted(let empty) = noPhases,
            case .workflowPhase(let p) = phase
        else { return XCTFail() }
        XCTAssertEqual(w.phases, ["Review", "Verify"])
        XCTAssertEqual(empty.phases, [])
        XCTAssertEqual(p.index, 0)
        XCTAssertEqual(p.state, .running)
    }

    func testToolRowsCarryAnOptionalAgentId() throws {
        let inside = try decode(#"""
            {"type":"tool.started","chat":1,"turn":2,"tool_use_id":"t9","tool":"Read","summary":"p11.md",
             "input":{},"agent_id":"a1","ts":"2026-10-27T12:00:00Z"}
            """#)
        let outside = try decode(#"""
            {"type":"tool.finished","chat":1,"turn":2,"tool_use_id":"t9","ok":true,"summary":"40 lines","ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .toolStarted(let s) = inside, case .toolFinished(let f) = outside else { return XCTFail() }
        XCTAssertEqual(s.agentId, "a1")
        XCTAssertNil(f.agentId)
        // Absent stays absent on the wire.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outside)) as? [String: Any]
        XCTAssertNil(encoded?["agent_id"])
    }

    func testAHistoryKeepsTheEventsItCanReadAndDropsAnUnknownOne() throws {
        let message = try decode(#"""
            {"type":"chat.history","chat":1,"truncated":false,"ts":"2026-10-27T12:00:00Z","events":[
              {"type":"turn.started","chat":1,"turn":1,"seq":1,"ts":"2026-10-27T12:00:00Z"},
              {"type":"agent.teleported","chat":1,"seq":2,"ts":"2026-10-27T12:00:00Z"},
              {"type":"turn.finished","chat":1,"turn":1,"outcome":"done","seq":3,"ts":"2026-10-27T12:00:00Z"}
            ]}
            """#)
        guard case .chatHistory(let history) = message else { return XCTFail("got \(message)") }
        XCTAssertEqual(history.events.map(\.type), ["turn.started", "turn.finished"])
    }

    // MARK: - the client hello

    func testTheClientHelloNamesAgentsV1() throws {
        XCTAssertEqual(HelloClient.appCapabilities, ["agents.v1"])
        let hello = HelloClient(appVersion: "0.10.0", capabilities: HelloClient.appCapabilities, ts: "2026-10-27T12:00:00Z")
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.hello(hello))) as? [String: Any]
        XCTAssertEqual(raw?["capabilities"] as? [String], ["agents.v1"])
        // Without capabilities the field is not sent at all.
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.hello(HelloClient(appVersion: "0.10.0")))) as? [String: Any]
        XCTAssertNil(bare?["capabilities"])
    }

    func testConnectSendsTheCapability() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }
        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.10.0-test")
        let first = try XCTUnwrap(gateway.received.first)
        XCTAssertEqual(first["capabilities"] as? [String], ["agents.v1"])
        await client.disconnect()
    }

    func testAGatewayThatRefusesTheFieldGetsAHelloWithoutIt() async throws {
        // A gateway older than v0.10 rejects unknown fields: the app says
        // hello again without capabilities and connects.
        let gateway = FakeGateway(refusesCapabilities: true)
        try await gateway.start()
        defer { gateway.stop() }
        let client = GatewayClient()
        let hello = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.10.0-test")
        XCTAssertEqual(hello.epoch, "epoch-1")
        let hellos = gateway.received.filter { $0["type"] as? String == "hello" }
        XCTAssertEqual(hellos.count, 2)
        XCTAssertNotNil(hellos.first?["capabilities"])
        XCTAssertNil(hellos.last?["capabilities"])
        await client.disconnect()
    }

    // MARK: - fixtures

    private let ts = "2026-10-27T12:00:00Z"
    private var seq = 0

    private func next() -> Int {
        seq += 1
        return seq
    }

    private func model() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        return model
    }

    private func turnStarted(_ turn: Int, chat: Int = 1) -> ServerMessage {
        .turnStarted(TurnStarted(chat: chat, turn: turn, seq: next(), ts: ts))
    }

    private func turnFinished(_ turn: Int, chat: Int = 1, outcome: Outcome = .done) -> ServerMessage {
        .turnFinished(TurnFinished(chat: chat, turn: turn, outcome: outcome, seq: next(), ts: ts))
    }

    private func spawnTool(_ id: String, turn: Int = 1) -> ServerMessage {
        .toolStarted(ToolStarted(chat: 1, turn: turn, toolUseId: id, tool: "Task", summary: "spawn", input: [:], seq: next(), ts: ts))
    }

    private func started(_ id: String, _ description: String, turn: Int = 1, tool: String? = nil,
                         workflow: String? = nil, phase: PhaseRef? = nil, background: Bool? = nil) -> ServerMessage {
        .agentStarted(AgentStarted(
            chat: 1, turn: turn, id: id, toolUseId: tool ?? "toolu_\(id)", description: description,
            kind: workflow == nil ? "subagent" : "workflow",
            workflowId: workflow, phase: phase, background: background ?? (workflow == nil ? nil : true), seq: next(), ts: ts))
    }

    private func progress(_ id: String, step: String?, steps: Int, elapsed: Double) -> ServerMessage {
        .agentProgress(AgentProgress(chat: 1, id: id, step: step, steps: steps, elapsed: elapsed, seq: next(), ts: ts))
    }

    private func finished(_ id: String, _ outcome: AgentOutcome = .done, summary: String? = nil) -> ServerMessage {
        .agentFinished(AgentFinished(chat: 1, id: id, outcome: outcome, summary: summary, seq: next(), ts: ts))
    }

    private func agentTool(_ toolUseId: String, agent: String, tool: String = "Read", summary: String) -> ServerMessage {
        .toolStarted(ToolStarted(
            chat: 1, turn: 1, toolUseId: toolUseId, tool: tool, summary: summary, input: [:], agentId: agent, seq: next(), ts: ts))
    }

    private func agentToolDone(_ toolUseId: String, agent: String) -> ServerMessage {
        .toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: toolUseId, ok: true, summary: "40 lines", agentId: agent, seq: next(), ts: ts))
    }

    /// A turn that starts three agents (each from its own tool use), two
    /// working and one done.
    private func threeAgents(_ model: AppModel) {
        for frame in [
            turnStarted(1),
            spawnTool("tA"), started("a", "Checking quotes", tool: "tA"),
            spawnTool("tB"), started("b", "Coding themes", tool: "tB"),
            spawnTool("tC"), started("c", "Counting mentions", tool: "tC"),
            progress("a", step: "Reading transcripts/p11.md", steps: 9, elapsed: 30),
            progress("b", step: "Writing codebook.md", steps: 4, elapsed: 20),
            progress("c", step: "Grepping", steps: 14, elapsed: 112),
            finished("c", summary: "41 mentions"),
        ] {
            model.apply(frame)
        }
    }

    private func groups(_ model: AppModel, chat: Int = 1) -> [AgentGroup] {
        (model.transcripts[chat] ?? []).compactMap { if case .agents(let g) = $0 { g } else { nil } }
    }

    // MARK: - the reducer: subagents

    func testAgentsAreKeptByIdWithTheirStepsAndOutcome() {
        let model = model()
        threeAgents(model)
        let activity = try! XCTUnwrap(model.agentActivity[1])
        XCTAssertEqual(activity.agents.map(\.id), ["a", "b", "c"])
        let a = try! XCTUnwrap(activity.agent("a"))
        XCTAssertEqual(a.step, "Reading transcripts/p11.md")
        XCTAssertEqual(a.steps, 9)
        XCTAssertEqual(a.elapsed, 30)
        XCTAssertEqual(activity.status(of: a), .working)
        let c = try! XCTUnwrap(activity.agent("c"))
        XCTAssertEqual(activity.status(of: c), .done)
        XCTAssertEqual(c.summary, "41 mentions")
        XCTAssertEqual(AgentPresentation.counts(activity.trayAgents.map(activity.status(of:))), "3 agents · 2 working")
    }

    func testOneStartedRowStandsForTheAgentsAndTheirStartingToolRows() {
        let model = model()
        threeAgents(model)
        let groups = groups(model)
        XCTAssertEqual(groups.count, 1, "agents started together share one row")
        XCTAssertEqual(groups.first?.agentIds, ["a", "b", "c"])
        XCTAssertEqual(AgentPresentation.startedLabel(groups.first?.agentIds.count ?? 0), "Started 3 agents")
        let drawn = (model.transcripts[1] ?? []).filter { model.isDrawn($0, in: 1) }
        XCTAssertFalse(drawn.contains { if case .tool = $0 { true } else { false } }, "the Task rows are the Started row")
    }

    func testAgentsStartedAfterTheAgentSpokeGetARowOfTheirOwn() {
        let model = model()
        model.apply(turnStarted(1))
        model.apply(started("a", "One"))
        model.apply(.textDelta(TextDelta(chat: 1, turn: 1, text: "Now two more.", seq: next(), ts: ts)))
        model.apply(started("b", "Two"))
        model.apply(started("c", "Three"))
        XCTAssertEqual(groups(model).map(\.agentIds), [["a"], ["b", "c"]])
    }

    func testASubagentsToolRowsAreItsStepsNotTheConversations() {
        let model = model()
        model.apply(turnStarted(1))
        model.apply(started("a", "Checking quotes"))
        model.apply(agentTool("r1", agent: "a", summary: "transcripts/p11.md"))
        model.apply(agentToolDone("r1", agent: "a"))
        model.apply(agentTool("r2", agent: "a", tool: "Grep", summary: "\"quote\""))
        let items = model.transcripts[1] ?? []
        XCTAssertFalse(items.contains { if case .tool(let row) = $0 { row.toolUseId == "r1" || row.toolUseId == "r2" } else { false } })
        let agent = try! XCTUnwrap(model.agentActivity[1]?.agent("a"))
        XCTAssertEqual(agent.rows.map(\.toolUseId), ["r1", "r2"])
        XCTAssertEqual(agent.rows.first?.finished, true)
        XCTAssertEqual(agent.steps, 2, "steps count the rows when the gateway reported fewer")
        XCTAssertEqual(agent.stepLines, ["Read transcripts/p11.md", "Grep \"quote\""])
        XCTAssertEqual(model.toolName(chat: 1, toolUseId: "r2"), "Grep")
    }

    func testTheTrayFoldsItselfWhenEveryAgentIsDone() {
        let model = model()
        threeAgents(model)
        XCTAssertTrue(model.agentActivity[1]!.showsTray)
        XCTAssertFalse(model.agentActivity[1]!.isTrayCollapsed, "open while agents work")
        model.apply(finished("a"))
        XCTAssertFalse(model.agentActivity[1]!.isTrayCollapsed)
        model.apply(finished("b", .failed))
        let activity = model.agentActivity[1]!
        XCTAssertTrue(activity.isTrayCollapsed, "folded once all are done")
        XCTAssertTrue(activity.showsTray, "still there until the turn ends")
        XCTAssertEqual(AgentPresentation.counts(activity.trayAgents.map(activity.status(of:))), "3 agents · 1 failed")
    }

    func testFoldingByHandWinsUntilTheLastAgentEnds() {
        let model = model()
        threeAgents(model)
        model.setTrayCollapsed(true, chat: 1)
        XCTAssertTrue(model.agentActivity[1]!.isTrayCollapsed)
        model.setTrayCollapsed(false, chat: 1)
        model.apply(finished("a"))
        XCTAssertFalse(model.agentActivity[1]!.isTrayCollapsed, "opened by hand stays open")
        model.apply(finished("b"))
        XCTAssertTrue(model.agentActivity[1]!.isTrayCollapsed, "the last one ending folds it anyway")
    }

    func testTheTrayDisappearsAtTheEndOfTheTurnAndTheRowBecomesTheRecord() {
        let model = model()
        threeAgents(model)
        let group = groups(model)[0]
        XCTAssertTrue(model.agentActivity[1]!.isLive(turn: group.turn))
        model.apply(turnFinished(1))
        let activity = model.agentActivity[1]!
        XCTAssertFalse(activity.showsTray)
        XCTAssertFalse(activity.isLive(turn: group.turn), "the row now draws the folded record")
        XCTAssertEqual(activity.status(of: activity.agent("a")!), .stopped, "unfinished when the turn ended")
        XCTAssertEqual(activity.status(of: activity.agent("c")!), .done)
    }

    func testTheCollapsedLineFollowsTheAgentThatMovedLast() {
        let model = model()
        threeAgents(model)
        let activity = model.agentActivity[1]!
        let busiest = try! XCTUnwrap(activity.busiest(of: activity.trayAgents))
        XCTAssertEqual(busiest.id, "b", "c finished; b moved after a")
        XCTAssertEqual(
            AgentPresentation.busyLine(description: busiest.description, step: busiest.step),
            "Coding themes — writing codebook.md")
    }

    func testARunningAgentsTimeKeepsMovingBetweenProgressFrames() {
        var activity = AgentActivity()
        activity.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, ts: ts)))
        activity.apply(.agentStarted(AgentStarted(chat: 1, turn: 1, id: "a", toolUseId: "t", description: "d", kind: "subagent", ts: ts)))
        activity.apply(.agentProgress(AgentProgress(chat: 1, id: "a", steps: 1, elapsed: 5, ts: ts)))
        let start = try! XCTUnwrap(SessionTime.parse(ts))
        let agent = activity.agent("a")!
        XCTAssertEqual(activity.elapsed(of: agent, now: start.addingTimeInterval(64)), 64)
        activity.apply(.agentFinished(AgentFinished(chat: 1, id: "a", outcome: .done, ts: ts)))
        XCTAssertEqual(activity.elapsed(of: activity.agent("a")!, now: start.addingTimeInterval(500)), 5, "an ended agent keeps its time")
    }

    // MARK: - replay

    func testAReplayDrawsTheRecord() {
        let model = model()
        let events: [ServerMessage] = [
            turnStarted(1),
            .userText(UserText(chat: 1, turn: 1, text: "Check the quotes", seq: next(), ts: ts)),
            spawnTool("tA"), started("a", "Checking quotes", tool: "tA"),
            agentTool("r1", agent: "a", summary: "p11.md"), agentToolDone("r1", agent: "a"),
            progress("a", step: "Reading p11.md", steps: 14, elapsed: 112),
            finished("a", summary: "6 findings"),
            turnFinished(1),
        ]
        model.apply(.chatHistory(ChatHistory(chat: 1, events: events, truncated: false, ts: ts)))
        let group = try! XCTUnwrap(groups(model).first)
        let activity = model.agentActivity[1]!
        XCTAssertFalse(activity.isLive(turn: group.turn))
        XCTAssertFalse(activity.showsTray)
        let agent = activity.agent("a")!
        XCTAssertEqual(activity.status(of: agent), .done)
        XCTAssertEqual(AgentPresentation.stepsLabel(steps: agent.steps, elapsed: agent.elapsed, finished: true), "14 steps · 1 m 52 s")
        XCTAssertEqual(agent.stepLines, ["Read p11.md"])

        // Replaying again from the beginning gives the same, not doubled.
        model.apply(.chatHistory(ChatHistory(chat: 1, events: events, truncated: false, ts: ts)))
        XCTAssertEqual(groups(model).count, 1)
        XCTAssertEqual(model.agentActivity[1]!.agents.count, 1)
    }

    func testAReplayOfARunningTurnShowsTheTray() {
        let model = model()
        let events: [ServerMessage] = [turnStarted(3), started("a", "One", turn: 3), progress("a", step: "x", steps: 1, elapsed: 1)]
        model.apply(.chatHistory(ChatHistory(chat: 1, events: events, truncated: false, ts: ts)))
        XCTAssertTrue(model.agentActivity[1]!.showsTray)
    }

    // MARK: - workflows

    private func workflow(_ model: AppModel, phases: [String] = ["Review", "Verify", "Report"]) {
        model.apply(turnStarted(1))
        model.apply(.workflowStarted(WorkflowStarted(chat: 1, id: "w", name: "Interview review", phases: phases, seq: next(), ts: ts)))
    }

    func testAWorkflowTakesTheTraysPlace() {
        let model = model()
        workflow(model)
        model.apply(started("plain", "A plain agent"))
        model.apply(started("r1", "Checking quotes", workflow: "w", phase: .index(0)))
        let activity = model.agentActivity[1]!
        XCTAssertEqual(activity.liveWorkflow?.id, "w")
        XCTAssertFalse(activity.showsTray)
        let rows = groups(model)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.workflowId, "w", "the workflow's row, where it started")
        XCTAssertEqual(rows.last?.agentIds, ["plain"], "a workflow's agents join its row, not a Started row")
    }

    func testPhasesAdvanceAndQueuedAgentsWait() {
        let model = model()
        workflow(model)
        model.apply(started("r1", "Checking quotes", workflow: "w", phase: .index(0)))
        model.apply(started("v1", "Verifying", workflow: "w", phase: .name("Verify")))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .running, seq: next(), ts: ts)))
        var activity = model.agentActivity[1]!
        var wf = activity.liveWorkflow!
        XCTAssertEqual(wf.currentPhase, 0)
        XCTAssertEqual(activity.status(of: activity.agent("r1")!), .working)
        XCTAssertEqual(activity.status(of: activity.agent("v1")!), .queued, "its phase waits")
        XCTAssertEqual(activity.agents(inPhase: 1, of: wf).map(\.id), ["v1"])

        model.apply(finished("r1", summary: "6 findings"))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .done, seq: next(), ts: ts)))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 1, state: .running, seq: next(), ts: ts)))
        activity = model.agentActivity[1]!
        wf = activity.liveWorkflow!
        XCTAssertEqual(wf.currentPhase, 1)
        XCTAssertEqual(activity.status(of: activity.agent("v1")!), .working)
        XCTAssertEqual(
            AgentPresentation.workflowHeader(currentPhase: wf.currentPhase, phaseCount: wf.phases.count, agents: 2, elapsed: 250),
            "phase 2 of 3 · 2 agents · 4 m 10 s")
        XCTAssertFalse(activity.isBoxCollapsed)
    }

    func testTheBoxFoldsWhenTheWorkflowIsDoneAndGoesAtTheTurnsEnd() {
        let model = model()
        workflow(model, phases: ["Review"])
        model.apply(started("r1", "Checking quotes", workflow: "w", phase: .index(0)))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .running, seq: next(), ts: ts)))
        model.apply(finished("r1"))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .done, seq: next(), ts: ts)))
        XCTAssertTrue(model.agentActivity[1]!.isBoxCollapsed)
        model.apply(turnFinished(1))
        XCTAssertNil(model.agentActivity[1]!.liveWorkflow)
    }

    func testAWorkflowWithoutPhasesIsDoneWhenItsAgentsAre() {
        let model = model()
        workflow(model, phases: [])
        model.apply(started("r1", "One", workflow: "w"))
        let activity = model.agentActivity[1]!
        let wf = activity.liveWorkflow!
        XCTAssertNil(wf.currentPhase)
        XCTAssertEqual(activity.agents(in: wf).map(\.id), ["r1"])
        XCTAssertEqual(
            AgentPresentation.workflowHeader(currentPhase: nil, phaseCount: 0, agents: 1, elapsed: 5), "1 agent · 5 s")
        XCTAssertFalse(activity.isDone(wf))
        model.apply(finished("r1"))
        XCTAssertTrue(model.agentActivity[1]!.isDone(wf))
    }

    func testAnAgentBeforeItsWorkflowsStartStillHasABox() {
        let model = model()
        model.apply(turnStarted(1))
        model.apply(started("r1", "One", workflow: "w", phase: .name("Review")))
        XCTAssertEqual(model.agentActivity[1]!.liveWorkflow?.id, "w")
        model.apply(.workflowStarted(WorkflowStarted(chat: 1, id: "w", name: "Named later", phases: ["Review"], seq: next(), ts: ts)))
        let activity = model.agentActivity[1]!
        XCTAssertEqual(activity.workflows.count, 1)
        XCTAssertEqual(activity.liveWorkflow?.name, "Named later")
        XCTAssertEqual(activity.agents(inPhase: 0, of: activity.liveWorkflow!).map(\.id), ["r1"])
        XCTAssertEqual(groups(model).count, 1, "one row for the workflow")
    }

    func testTheLogListsStepsInTimeOrder() {
        let model = model()
        workflow(model)
        model.apply(started("r1", "Checking quotes", workflow: "w", phase: .index(0)))
        model.apply(started("r2", "Coding", workflow: "w", phase: .index(0)))
        model.apply(agentTool("s1", agent: "r1", summary: "p1.md"))
        model.apply(progress("r2", step: "Thinking about codes", steps: 1, elapsed: 2))
        model.apply(agentTool("s2", agent: "r1", tool: "Grep", summary: "quote"))
        let activity = model.agentActivity[1]!
        let lines = activity.logLines(of: activity.liveWorkflow!).map { "\($0.agent.id): \($0.text)" }
        XCTAssertEqual(lines, ["r1: Read p1.md", "r2: Thinking about codes", "r1: Grep quote"])
    }

    // MARK: - the gateway's wire format (v0.10 reconciliation)

    /// `protocol/examples/<name>`, as the gateway writes it.
    private func example(_ name: String) throws -> ServerMessage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/examples/\(name)")
        return try JSONDecoder().decode(ServerMessage.self, from: Data(contentsOf: url))
    }

    func testThePhaseStatesAreTheGatewaysAndTheOldWaitingStillReads() throws {
        for (word, state) in [("pending", PhaseState.pending), ("running", .running), ("done", .done), ("failed", .failed),
                              ("waiting", .pending)] {
            let message = try decode(#"{"type":"workflow.phase","chat":1,"id":"w","index":0,"state":"\#(word)","ts":"2026-10-27T12:00:00Z"}"#)
            guard case .workflowPhase(let phase) = message else { return XCTFail("got \(message)") }
            XCTAssertEqual(phase.state, state, word)
        }
        XCTAssertThrowsError(try decode(#"{"type":"workflow.phase","chat":1,"id":"w","index":0,"state":"sleeping","ts":"2026-10-27T12:00:00Z"}"#))
        guard case .workflowPhase(let example) = try example("server.workflow.phase.json") else { return XCTFail() }
        XCTAssertEqual(example.state, .running)
        XCTAssertEqual(example.index, 1)
    }

    func testAFailedPhaseReadsAsAWarning() {
        let model = model()
        workflow(model, phases: ["Find", "Verify"])
        model.apply(started("w.0", "find", workflow: "w", phase: .index(0)))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .running, seq: next(), ts: ts)))
        model.apply(finished("w.0", .failed))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .failed, seq: next(), ts: ts)))
        let activity = model.agentActivity[1]!
        let wf = activity.workflow("w")!
        XCTAssertEqual(wf.state(ofPhase: 0), .failed)
        XCTAssertEqual(wf.state(ofPhase: 1), .pending)
        XCTAssertEqual(wf.currentPhase, 1, "a failed phase is settled: the next is under way")
        XCTAssertEqual(activity.recordStatus(ofPhase: 0, in: wf), .failed)
        XCTAssertEqual(activity.recordStatus(ofPhase: 1, in: wf), .done)
        // Said failed with no agent of its own failing: still a warning.
        var bare = AgentActivity()
        bare.apply(.workflowStarted(WorkflowStarted(chat: 1, turn: 1, id: "x", name: "x", phases: ["One"], ts: ts)))
        bare.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "x", index: 0, state: .failed, ts: ts)))
        XCTAssertEqual(bare.recordStatus(ofPhase: 0, in: bare.workflow("x")!), .failed)
    }

    func testWorkflowFinishedDecodesFromTheGatewaysExample() throws {
        guard case .workflowFinished(let finished) = try example("server.workflow.finished.json") else { return XCTFail() }
        XCTAssertEqual(finished.id, "w9k2m4")
        XCTAssertEqual(finished.outcome, .done)
        XCTAssertEqual(finished.summary, "Workflow audit-quotes completed")
        for word in ["done", "failed", "stopped"] {
            let message = try decode(#"{"type":"workflow.finished","chat":1,"id":"w","outcome":"\#(word)","seq":3,"ts":"2026-10-27T12:00:00Z"}"#)
            guard case .workflowFinished(let f) = message else { return XCTFail("got \(message)") }
            XCTAssertEqual(f.outcome.rawValue, word)
            XCTAssertNil(f.summary)
            XCTAssertEqual(message.envelope, Envelope(chat: 1, id: "w", seq: 3))
        }
    }

    func testWorkflowFinishedEndsTheWorkflowTheBoxFoldsAndTheRecordKeepsIt() {
        let model = model()
        workflow(model, phases: ["Find"])
        model.apply(started("w.0", "find", workflow: "w", phase: .index(0)))
        model.setBoxCollapsed(false, chat: 1)
        model.apply(finished("w.0", summary: "3 found"))
        model.apply(.workflowFinished(WorkflowFinished(chat: 1, id: "w", outcome: .done, summary: "Workflow w completed", seq: next(), ts: ts)))
        var activity = model.agentActivity[1]!
        XCTAssertEqual(activity.workflow("w")?.outcome, .done)
        XCTAssertTrue(activity.isDone(activity.workflow("w")!), "done though the phase never said so")
        XCTAssertTrue(activity.isBoxCollapsed, "the box folds itself, even opened by hand")
        model.apply(turnFinished(1))
        activity = model.agentActivity[1]!
        XCTAssertNil(activity.liveWorkflow)
        let group = groups(model)[0]
        XCTAssertFalse(activity.isLive(group), "the row is the record")
        XCTAssertEqual(activity.agents(in: activity.workflow("w")!).map(\.summary), ["3 found"])
    }

    func testTheSecondWorkflowStartedReplacesThePhasesAndKeepsItsAgents() throws {
        // The gateway's order: an empty start, then the same id with phases,
        // then the agents with 0-based phase indices.
        let model = model()
        model.apply(turnStarted(3))
        model.apply(.workflowStarted(WorkflowStarted(chat: 1, turn: 3, id: "w9k2m4", name: "audit-quotes", phases: [], seq: next(), ts: ts)))
        model.apply(started("w9k2m4.1", "read:alpha", turn: 3, workflow: "w9k2m4"))  // no phases yet: no phase
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w9k2m4", index: 0, state: .running, seq: next(), ts: ts)))
        guard case .workflowStarted(var again) = try example("server.workflow.started.json") else { return XCTFail() }
        XCTAssertEqual(again.turn, 3)
        again.seq = next()
        model.apply(.workflowStarted(again))
        model.apply(started("w9k2m4.2", "read:beta", turn: 3, workflow: "w9k2m4", phase: .index(1)))
        let activity = model.agentActivity[1]!
        XCTAssertEqual(activity.workflows.count, 1, "replaced, not duplicated")
        let wf = activity.workflows[0]
        XCTAssertEqual(wf.phases, ["find", "verify", "report"])
        XCTAssertEqual(wf.phaseStates, [.running, .pending, .pending], "a phase keeps the state it had at its place")
        XCTAssertEqual(wf.turn, 3)
        XCTAssertEqual(activity.agents(in: wf).map(\.id), ["w9k2m4.1", "w9k2m4.2"], "the earlier agent keeps its place")
        XCTAssertEqual(activity.agents(inPhase: 1, of: wf).map(\.id), ["w9k2m4.2"])
        XCTAssertEqual(groups(model).count, 1, "one row for the workflow")
        XCTAssertEqual(groups(model).first?.turn, 3)
    }

    func testAgentStartedCarriesBackgroundAndAWorkflowKind() throws {
        guard case .agentStarted(let plain) = try example("server.agent.started.json") else { return XCTFail() }
        XCTAssertNil(plain.background)
        XCTAssertEqual(plain.kind, "general-purpose")
        let message = try decode(#"""
            {"type":"agent.started","chat":1,"turn":3,"id":"w9k2m4.0","tool_use_id":"toolu_07","description":"read:alpha",
             "kind":"workflow","workflow_id":"w9k2m4","phase":0,"background":true,"seq":60,"ts":"2026-10-27T12:00:00Z"}
            """#)
        guard case .agentStarted(let started) = message else { return XCTFail("got \(message)") }
        XCTAssertEqual(started.kind, "workflow")
        XCTAssertEqual(started.phase, .index(0))
        XCTAssertEqual(started.background, true)
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        XCTAssertEqual(raw?["background"] as? Bool, true, "kept on the way back out")
        var activity = AgentActivity()
        activity.apply(message)
        XCTAssertTrue(activity.agent("w9k2m4.0")!.background)
    }

    func testABackgroundAgentOutlivesItsTurn() {
        let model = model()
        model.apply(turnStarted(1))
        model.apply(started("fg", "Foreground"))
        model.apply(started("bg", "Background", background: true))
        model.apply(turnFinished(1))
        var activity = model.agentActivity[1]!
        XCTAssertEqual(activity.status(of: activity.agent("fg")!), .stopped, "a foreground agent open at its turn's end is stopped")
        XCTAssertEqual(activity.status(of: activity.agent("bg")!), .working, "a background one is not")
        XCTAssertTrue(activity.showsTray, "the tray stays for it")
        XCTAssertEqual(activity.trayAgents.map(\.id), ["bg"])
        XCTAssertTrue(activity.isLive(groups(model)[0]), "its row still points at the tray")

        // It keeps reporting under the turn that started it, during a later turn.
        model.apply(turnStarted(2))
        model.apply(progress("bg", step: "Reading alpha.md", steps: 3, elapsed: 41.3))
        model.apply(finished("bg", summary: "42"))
        activity = model.agentActivity[1]!
        XCTAssertEqual(activity.status(of: activity.agent("bg")!), .done)
        XCTAssertEqual(activity.agent("bg")?.elapsed, 41.3)
        XCTAssertFalse(activity.showsTray, "gone once it finished on its own")
        XCTAssertFalse(activity.isLive(groups(model)[0]), "turn 1's row is now the record, with the late result in it")
        XCTAssertEqual(activity.agent("bg")?.summary, "42")
    }

    func testAWorkflowRunsOnAfterItsTurnUntilItsOwnFinish() {
        let model = model()
        model.apply(turnStarted(1))
        model.apply(.workflowStarted(WorkflowStarted(chat: 1, turn: 1, id: "w", name: "audit", phases: ["Find"], seq: next(), ts: ts)))
        model.apply(started("w.0", "find", workflow: "w", phase: .index(0)))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .running, seq: next(), ts: ts)))
        model.apply(turnFinished(1))
        var activity = model.agentActivity[1]!
        XCTAssertEqual(activity.liveWorkflow?.id, "w", "the box stays")
        XCTAssertEqual(activity.status(of: activity.agent("w.0")!), .working, "not stopped by the turn's end")
        XCTAssertTrue(activity.isLive(groups(model)[0]))

        model.apply(progress("w.0", step: "Read alpha.md", steps: 1, elapsed: 3.4))
        model.apply(finished("w.0", summary: "7"))
        model.apply(.workflowPhase(WorkflowPhase(chat: 1, id: "w", index: 0, state: .done, seq: next(), ts: ts)))
        model.apply(.workflowFinished(WorkflowFinished(chat: 1, id: "w", outcome: .done, seq: next(), ts: ts)))
        activity = model.agentActivity[1]!
        XCTAssertNil(activity.liveWorkflow)
        XCTAssertFalse(activity.isLive(groups(model)[0]), "the record now")
        XCTAssertEqual(activity.recordStatus(ofPhase: 0, in: activity.workflow("w")!), .done)
    }

    func testProgressTakesTheGatewaysFractionalElapsedAndTheEnginesOwnWords() throws {
        guard case .agentProgress(let example) = try example("server.agent.progress.json") else { return XCTFail() }
        XCTAssertEqual(example.elapsed, 12.5)
        let model = model()
        model.apply(turnStarted(1))
        model.apply(started("a", "Read alpha.md number"))
        // Before its first tool call the step is the engine's own wording.
        model.apply(progress("a", step: "Reading alpha.md", steps: 0, elapsed: 0.8))
        model.apply(agentTool("r1", agent: "a", summary: "alpha.md"))
        model.apply(progress("a", step: "Read alpha.md", steps: 1, elapsed: 1.6))
        let agent = model.agentActivity[1]!.agent("a")!
        XCTAssertEqual(agent.elapsed, 1.6)
        XCTAssertEqual(agent.stepHistory, ["Reading alpha.md", "Read alpha.md"])
        XCTAssertEqual(agent.stepLines, ["Read alpha.md"], "tool rows win over reported steps")
        XCTAssertEqual(AgentPresentation.busyLine(description: agent.description, step: "Reading alpha.md"),
                       "Read alpha.md number — reading alpha.md")
    }

    func testTheHelloCapabilityIsTheOneTheGatewayChecks() throws {
        // The gateway's example hello (and its `AGENTS_CAPABILITY`).
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/examples/client.hello.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(raw?["capabilities"] as? [String], HelloClient.appCapabilities)
    }

    // MARK: - words

    func testDurations() {
        XCTAssertEqual(AgentPresentation.duration(0), "0 s")
        XCTAssertEqual(AgentPresentation.duration(38.9), "38 s")
        XCTAssertEqual(AgentPresentation.duration(112), "1 m 52 s")
        XCTAssertEqual(AgentPresentation.duration(124), "2 m 04 s")
        XCTAssertEqual(AgentPresentation.duration(3720), "1 h 02 m")
    }

    func testStepsLabels() {
        XCTAssertEqual(AgentPresentation.stepsLabel(steps: 9, elapsed: 40, finished: false), "9 steps")
        XCTAssertEqual(AgentPresentation.stepsLabel(steps: 14, elapsed: 112, finished: true), "14 steps · 1 m 52 s")
        XCTAssertEqual(AgentPresentation.stepsLabel(steps: 1, elapsed: 3, finished: true), "1 step · 3 s")
    }

    func testCounts() {
        XCTAssertEqual(AgentPresentation.counts([.working, .working, .done]), "3 agents · 2 working")
        XCTAssertEqual(AgentPresentation.counts([.working]), "1 agent · 1 working")
        XCTAssertEqual(AgentPresentation.counts([.done, .done]), "2 agents · done")
        XCTAssertEqual(AgentPresentation.counts([.done, .stopped]), "2 agents · 1 stopped")
        XCTAssertEqual(AgentPresentation.counts([.queued, .done]), "2 agents · 1 working")
    }

    func testBusyLineLowercasesTheStepButNotAnInitialism() {
        XCTAssertEqual(AgentPresentation.busyLine(description: "Checking quotes", step: "Reading transcripts/p11.md"),
                       "Checking quotes — reading transcripts/p11.md")
        XCTAssertEqual(AgentPresentation.busyLine(description: "Docs", step: "README.md"), "Docs — README.md")
        XCTAssertEqual(AgentPresentation.busyLine(description: "Docs", step: nil), "Docs")
    }

    func testOverflowGivesTheLastPlaceToAndNMore() {
        let (shown, more) = AgentPresentation.overflow(Array(1...7), limit: 4)
        XCTAssertEqual(shown, [1, 2, 3])
        XCTAssertEqual(more, 4)
        XCTAssertEqual(AgentPresentation.moreLabel(more), "…and 4 more")
        let (all, none) = AgentPresentation.overflow(Array(1...4), limit: 4)
        XCTAssertEqual(all, [1, 2, 3, 4])
        XCTAssertEqual(none, 0)
    }

    func testPhaseColumnWords() {
        XCTAssertEqual(AgentPresentation.phaseTitle(index: 0, name: "Review"), "1 · Review")
        XCTAssertEqual(AgentPresentation.result(status: .done, summary: "6 findings", elapsed: 40), "6 findings")
        XCTAssertEqual(AgentPresentation.result(status: .done, summary: "confirmed", elapsed: 40), "confirmed")
        XCTAssertEqual(AgentPresentation.result(status: .done, summary: "A long report about everything it found.", elapsed: 112), "1 m 52 s")
        XCTAssertEqual(AgentPresentation.result(status: .working, summary: nil, elapsed: 38), "0:38")
        XCTAssertEqual(AgentPresentation.result(status: .queued, summary: nil, elapsed: 0), "queued")
        XCTAssertEqual(AgentPresentation.phaseRecordLabel(agents: 3, elapsed: 130), "3 agents · 2 m 10 s")
    }

    func testStepLine() {
        XCTAssertEqual(AgentPresentation.stepLine(status: .working, step: "Reading p11.md", summary: nil), "Reading p11.md")
        XCTAssertEqual(AgentPresentation.stepLine(status: .done, step: "Reading p11.md", summary: "6 findings\nmore"), "6 findings")
        XCTAssertEqual(AgentPresentation.stepLine(status: .queued, step: nil, summary: nil), "Waiting for its phase")
    }
}
