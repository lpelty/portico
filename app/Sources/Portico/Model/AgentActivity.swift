import Foundation

// MARK: - One subagent

/// One subagent (or background task) the agent started (`agent.started`),
/// with everything its later frames said: its current step, its step count
/// and time (`agent.progress`), its tool rows (`tool.*` with `agent_id`)
/// and how it ended (`agent.finished`). v0.10 decision 1.
struct AgentRun: Equatable, Sendable, Identifiable {
    var id: String
    var turn: Int
    /// The tool use that started it: that row is drawn as "Started N
    /// agents", not as a tool row of its own.
    var toolUseId: String
    var description: String
    var kind: String
    var workflowId: String? = nil
    var phase: PhaseRef? = nil
    /// It runs on after its turn (`agent.started`'s `background`, and any
    /// agent of a workflow): its turn's end does not stop it.
    var background: Bool = false
    /// The current step in words ("Reading transcripts/p11.md"), from the
    /// last `agent.progress` that named one.
    var step: String? = nil
    /// The step count the gateway last reported.
    var reportedSteps: Int = 0
    /// Seconds run, as the gateway last reported.
    var elapsed: Double = 0
    /// Its start's stamp: a running agent's time keeps moving between
    /// progress frames.
    var startedAt: Date? = nil
    var outcome: AgentOutcome? = nil
    var summary: String? = nil
    /// Its tool rows, oldest first: what clicking it shows, and the
    /// record's "⎿" lines.
    var rows: [ToolRow] = []
    /// Each distinct step it reported, oldest first: the record's lines
    /// when the gateway sent no tool rows for it.
    var stepHistory: [String] = []
    /// When it last moved, on the activity's own clock: the collapsed
    /// tray line follows the agent that moved last.
    var moved: Int = 0

    /// Steps taken: the gateway's count, or the rows seen when more.
    var steps: Int { max(reportedSteps, rows.count) }

    /// The record's and the popover's lines: its tool rows in words
    /// ("Read transcripts/p11.md"), else the steps it reported.
    var stepLines: [String] {
        if rows.isEmpty { return stepHistory }
        return rows.map { $0.summary.isEmpty ? $0.tool : "\($0.tool) \($0.summary)" }
    }
}

/// How an agent reads: a spinner, a grey dot, a check, a warning.
enum AgentStatus: Equatable, Sendable {
    /// In a workflow phase that has not started (AF3's grey dot).
    case queued
    case working
    case done
    case failed
    /// Stopped, or still unfinished when its turn ended.
    case stopped

    var isFinished: Bool { self == .done || self == .failed || self == .stopped }
}

/// A workflow (`workflow.started`) and its phases' states (`workflow.phase`).
/// v0.10 decision 2.
struct WorkflowRun: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var phases: [String]
    var phaseStates: [PhaseState]
    var turn: Int
    var startedAt: Date? = nil
    /// How it ended (`workflow.finished`); `nil` while it runs.
    var outcome: AgentOutcome? = nil
    var summary: String? = nil

    /// The phase under way, 0-based: the running one, else the first not
    /// settled (the last when all are). `nil` when the workflow names none.
    var currentPhase: Int? {
        guard !phases.isEmpty else { return nil }
        if let running = phaseStates.firstIndex(of: .running) { return running }
        return phaseStates.firstIndex(where: { !$0.isSettled }) ?? phases.count - 1
    }

    /// Every phase done or failed (and there was at least one).
    var phasesDone: Bool { !phases.isEmpty && phaseStates.allSatisfy(\.isSettled) }

    func state(ofPhase index: Int) -> PhaseState {
        phaseStates.indices.contains(index) ? phaseStates[index] : .pending
    }
}

/// The conversation's row for a batch of agents (v0.10 decision 1, AF1):
/// "Started 3 agents" while its turn runs, then the folded record — one
/// block per agent, or per phase for a workflow (`workflowId`).
struct AgentGroup: Equatable, Sendable {
    var id: String
    var turn: Int
    var agentIds: [String]
    var workflowId: String? = nil
}

// MARK: - The reducer

/// One chat's agents and workflows, reduced from the v0.10 frames. Pure:
/// the model feeds it every turn and agent frame, live or replayed, and
/// the tray, the workflow box and the record read it.
struct AgentActivity: Equatable, Sendable {
    /// What the app names in its `hello` to get these frames (v0.10).
    static let capability = "agents.v1"

    /// Every agent, in start order.
    private(set) var agents: [AgentRun] = []
    /// Every workflow, in start order.
    private(set) var workflows: [WorkflowRun] = []
    /// Turns that have finished: their agents leave the tray and become
    /// the record.
    private(set) var endedTurns: Set<Int> = []
    /// The latest turn seen; a `workflow.started` (which names none)
    /// belongs to it.
    private(set) var turn: Int?
    /// The tool steps of every agent in arrival order (agent id, tool use
    /// id): the workflow box's Log tab.
    private(set) var log: [LogEntry] = []
    /// The person opened or folded the tray by hand; `nil` follows the
    /// rule: open while any agent works, folded when all are done.
    var trayCollapsed: Bool?
    /// The same for the workflow box.
    var boxCollapsed: Bool?
    private var clock = 0

    struct LogEntry: Equatable, Sendable {
        var agentId: String
        /// A tool row's use id, or `nil` for a reported step (`text`).
        var toolUseId: String?
        var text: String?
    }

    // MARK: applying frames

    /// Apply one frame. Frames that say nothing about agents are ignored;
    /// tool rows count only when they carry an `agent_id`.
    mutating func apply(_ event: ServerMessage) {
        clock += 1
        switch event {
        case .turnStarted(let started):
            turn = started.turn
            endedTurns.remove(started.turn)
            trayCollapsed = nil
            boxCollapsed = nil

        case .userText(let user):
            turn = user.turn

        case .turnFinished(let finished):
            endedTurns.insert(finished.turn)
            trayCollapsed = nil
            boxCollapsed = nil

        case .agentStarted(let started):
            turn = started.turn
            var agent = AgentRun(
                id: started.id, turn: started.turn, toolUseId: started.toolUseId,
                description: started.description, kind: started.kind,
                workflowId: started.workflowId, phase: started.phase,
                background: started.background ?? false || started.workflowId != nil,
                startedAt: SessionTime.parse(started.ts), moved: clock)
            if let index = index(of: started.id) {
                // A re-sent start keeps what the agent already did.
                let old = agents[index]
                agent.step = old.step
                agent.reportedSteps = old.reportedSteps
                agent.elapsed = old.elapsed
                agent.outcome = old.outcome
                agent.summary = old.summary
                agent.rows = old.rows
                agent.stepHistory = old.stepHistory
                agents[index] = agent
            } else {
                agents.append(agent)
            }
            // An agent of a workflow the gateway has not announced yet:
            // the box stands for it until `workflow.started` names it.
            if let workflowId = started.workflowId, workflowIndex(of: workflowId) == nil {
                workflows.append(WorkflowRun(
                    id: workflowId, name: "Workflow", phases: [], phaseStates: [], turn: started.turn,
                    startedAt: agent.startedAt))
            }

        case .agentProgress(let progress):
            guard let index = index(of: progress.id) else { return }
            if let step = progress.step, !step.isEmpty {
                agents[index].step = step
                if agents[index].stepHistory.last != step {
                    agents[index].stepHistory.append(step)
                    log.append(LogEntry(agentId: progress.id, toolUseId: nil, text: step))
                }
            }
            agents[index].reportedSteps = max(agents[index].reportedSteps, progress.steps)
            agents[index].elapsed = max(agents[index].elapsed, progress.elapsed)
            agents[index].moved = clock

        case .agentFinished(let finished):
            guard let index = index(of: finished.id) else { return }
            agents[index].outcome = finished.outcome
            agents[index].summary = finished.summary
            agents[index].moved = clock
            // The tray folds itself when the last one is done (decision 1).
            if trayAgents.allSatisfy({ status(of: $0).isFinished }) { trayCollapsed = nil }

        case .workflowStarted(let started):
            if let index = workflowIndex(of: started.id) {
                // Sent again once its phases are known, or when they
                // change: the list is replaced, each phase keeping the state
                // it had at its place (as the gateway keeps it); its agents
                // keep their phase indices into the new list.
                let old = workflows[index].phaseStates
                workflows[index].name = started.name
                workflows[index].phases = started.phases
                workflows[index].phaseStates = started.phases.indices.map { old.indices.contains($0) ? old[$0] : .pending }
            } else {
                workflows.append(WorkflowRun(
                    id: started.id, name: started.name, phases: started.phases,
                    phaseStates: Array(repeating: .pending, count: started.phases.count),
                    turn: started.turn ?? turn ?? 0, startedAt: SessionTime.parse(started.ts)))
            }

        case .workflowFinished(let finished):
            guard let index = workflowIndex(of: finished.id) else { return }
            workflows[index].outcome = finished.outcome
            workflows[index].summary = finished.summary
            // The box folds itself now that it is done.
            boxCollapsed = nil

        case .workflowPhase(let phase):
            guard let index = workflowIndex(of: phase.id) else { return }
            var states = workflows[index].phaseStates
            if phase.index >= states.count {
                // A phase past the announced list: grow to hold it.
                states += Array(repeating: .pending, count: phase.index - states.count + 1)
                while workflows[index].phases.count < states.count {
                    workflows[index].phases.append("Phase \(workflows[index].phases.count + 1)")
                }
            }
            if phase.index >= 0 { states[phase.index] = phase.state }
            workflows[index].phaseStates = states

        case .toolStarted(let started):
            guard let agentId = started.agentId, let index = index(of: agentId) else { return }
            var row = ToolRow(
                toolUseId: started.toolUseId, turn: started.turn, tool: started.tool,
                summary: started.summary, input: started.input, at: started.ts)
            if let rowIndex = agents[index].rows.firstIndex(where: { $0.toolUseId == started.toolUseId }) {
                row.finished = agents[index].rows[rowIndex].finished
                row.ok = agents[index].rows[rowIndex].ok
                row.result = agents[index].rows[rowIndex].result
                agents[index].rows[rowIndex] = row
            } else {
                agents[index].rows.append(row)
                log.append(LogEntry(agentId: agentId, toolUseId: started.toolUseId, text: nil))
            }
            agents[index].moved = clock

        case .toolFinished(let finished):
            guard let agentId = finished.agentId, let index = index(of: agentId) else { return }
            if let rowIndex = agents[index].rows.firstIndex(where: { $0.toolUseId == finished.toolUseId }) {
                agents[index].rows[rowIndex].finished = true
                agents[index].rows[rowIndex].ok = finished.ok
                agents[index].rows[rowIndex].result = finished.summary
                agents[index].rows[rowIndex].permission = finished.permission ?? agents[index].rows[rowIndex].permission
                agents[index].rows[rowIndex].at = finished.ts
            } else {
                agents[index].rows.append(ToolRow(
                    toolUseId: finished.toolUseId, turn: finished.turn, tool: "tool", summary: finished.summary,
                    input: [:], finished: true, ok: finished.ok, result: finished.summary,
                    permission: finished.permission, at: finished.ts))
                log.append(LogEntry(agentId: agentId, toolUseId: finished.toolUseId, text: nil))
            }

        default:
            break
        }
    }

    // MARK: reading

    func agent(_ id: String) -> AgentRun? {
        index(of: id).map { agents[$0] }
    }

    func workflow(_ id: String) -> WorkflowRun? {
        workflowIndex(of: id).map { workflows[$0] }
    }

    /// Whether `turn` is still running (no `turn.finished` for it yet).
    func isLive(turn: Int) -> Bool { !endedTurns.contains(turn) }

    /// How an agent reads now: its outcome once it ended; stopped when its
    /// turn ended first, unless it runs in the background (it ends on its
    /// own `agent.finished`); queued while its workflow phase waits; else
    /// working.
    func status(of agent: AgentRun) -> AgentStatus {
        switch agent.outcome {
        case .done: return .done
        case .failed: return .failed
        case .stopped: return .stopped
        case nil: break
        }
        if !agent.background, !isLive(turn: agent.turn) { return .stopped }
        if let workflowId = agent.workflowId, let workflow = workflow(workflowId),
            let phase = phaseIndex(of: agent, in: workflow), workflow.state(ofPhase: phase) == .pending
        {
            return .queued
        }
        return .working
    }

    /// The tool uses that started agents: their rows are the "Started N
    /// agents" row, not tool rows of their own.
    var startingToolUses: Set<String> { Set(agents.map(\.toolUseId)) }

    /// The tray's agents (AF2): those of a running turn outside any
    /// workflow, and background ones still working after their turn ended.
    var trayAgents: [AgentRun] {
        agents.filter { $0.workflowId == nil && (isLive(turn: $0.turn) || runsOn($0)) }
    }

    /// The workflow the box shows (AF3): the latest one of a running turn,
    /// or one still running after its turn ended (workflows run in the
    /// background until their `workflow.finished`).
    var liveWorkflow: WorkflowRun? {
        workflows.last { isLive(turn: $0.turn) || !isDone($0) }
    }

    /// A background agent still working after its turn ended.
    private func runsOn(_ agent: AgentRun) -> Bool {
        agent.background && agent.outcome == nil
    }

    /// Whether a conversation row still stands for live work ("Started N
    /// agents", details in the tray or box) rather than the folded record:
    /// while its turn runs, and after it while its background work does.
    /// The record follows the agents, so it is complete once they end.
    func isLive(_ group: AgentGroup) -> Bool {
        if isLive(turn: group.turn) { return true }
        if let workflowId = group.workflowId {
            return workflow(workflowId).map { !isDone($0) } ?? false
        }
        return group.agentIds.contains { id in agent(id).map(runsOn) ?? false }
    }

    /// The tray shows while a turn's agents run, unless a workflow has the
    /// place (decision 2: a workflow takes the tray's place).
    var showsTray: Bool { liveWorkflow == nil && !trayAgents.isEmpty }

    /// The tray is folded: by hand, else once every agent is done.
    var isTrayCollapsed: Bool {
        trayCollapsed ?? trayAgents.allSatisfy { status(of: $0).isFinished }
    }

    /// The workflow box is folded: by hand, else once the workflow is done.
    var isBoxCollapsed: Bool {
        guard let workflow = liveWorkflow else { return true }
        return boxCollapsed ?? isDone(workflow)
    }

    /// A workflow is done when the gateway said it finished, or when every
    /// phase is, or (naming no phases) when it has agents and all of them
    /// ended.
    func isDone(_ workflow: WorkflowRun) -> Bool {
        if workflow.outcome != nil { return true }
        let members = agents(in: workflow)
        if !workflow.phases.isEmpty { return workflow.phasesDone && members.allSatisfy { status(of: $0).isFinished } }
        return !members.isEmpty && members.allSatisfy { status(of: $0).isFinished }
    }

    func agents(in workflow: WorkflowRun) -> [AgentRun] {
        agents.filter { $0.workflowId == workflow.id }
    }

    /// The agents of one phase, in start order.
    func agents(inPhase phase: Int, of workflow: WorkflowRun) -> [AgentRun] {
        agents(in: workflow).filter { phaseIndex(of: $0, in: workflow) == phase }
    }

    /// A phase's folded record reads failed (⚠) when the gateway said the
    /// phase failed or one of its agents failed or stopped; else done (✓).
    func recordStatus(ofPhase index: Int, in workflow: WorkflowRun) -> AgentStatus {
        if workflow.state(ofPhase: index) == .failed { return .failed }
        let statuses = agents(inPhase: index, of: workflow).map(status(of:))
        if statuses.contains(.failed) || statuses.contains(.stopped) { return .failed }
        return .done
    }

    /// Which phase an agent is in: its index, or its name looked up in the
    /// workflow's list.
    func phaseIndex(of agent: AgentRun, in workflow: WorkflowRun) -> Int? {
        switch agent.phase {
        case .index(let i): return i
        case .name(let name): return workflow.phases.firstIndex(of: name)
        case nil: return nil
        }
    }

    /// The agent the collapsed line follows: the working one that moved
    /// last, else the one that moved last.
    func busiest(of list: [AgentRun]) -> AgentRun? {
        let working = list.filter { status(of: $0) == .working }
        return (working.isEmpty ? list : working).max { $0.moved < $1.moved }
    }

    /// Seconds an agent has run at `now`: what the gateway reported, or
    /// for a working agent the time since its start, whichever is more.
    func elapsed(of agent: AgentRun, now: Date) -> Double {
        guard status(of: agent) == .working, let start = agent.startedAt else { return agent.elapsed }
        return max(agent.elapsed, now.timeIntervalSince(start))
    }

    /// The batch's time: the longest of its agents'.
    func elapsed(of list: [AgentRun], now: Date) -> Double {
        list.map { elapsed(of: $0, now: now) }.max() ?? 0
    }

    /// The workflow's time: since its start while it runs, else its
    /// longest agent's.
    func elapsed(of workflow: WorkflowRun, now: Date) -> Double {
        let longest = elapsed(of: agents(in: workflow), now: now)
        guard !isDone(workflow), let start = workflow.startedAt else { return longest }
        return max(longest, now.timeIntervalSince(start))
    }

    /// The Log tab's lines for a workflow, oldest first: each tool step (or
    /// reported step) of its agents, with the agent it belongs to.
    func logLines(of workflow: WorkflowRun) -> [(agent: AgentRun, text: String)] {
        let members = Dictionary(uniqueKeysWithValues: agents(in: workflow).map { ($0.id, $0) })
        var hasRows: Set<String> = []
        for entry in log where entry.toolUseId != nil { hasRows.insert(entry.agentId) }
        return log.compactMap { entry in
            guard let agent = members[entry.agentId] else { return nil }
            if let toolUseId = entry.toolUseId {
                guard let row = agent.rows.first(where: { $0.toolUseId == toolUseId }) else { return nil }
                return (agent, row.summary.isEmpty ? row.tool : "\(row.tool) \(row.summary)")
            }
            // A reported step stands in only for an agent with no tool rows.
            guard !hasRows.contains(entry.agentId), let text = entry.text else { return nil }
            return (agent, text)
        }
    }

    private func index(of id: String) -> Int? {
        agents.firstIndex { $0.id == id }
    }

    private func workflowIndex(of id: String) -> Int? {
        workflows.firstIndex { $0.id == id }
    }
}

// MARK: - Words

/// The tray's, the box's and the record's words, view-free so they can be
/// tested (AF1–AF3).
enum AgentPresentation {
    /// `38 s`, `1 m 52 s`, `2 m 04 s`, `1 h 02 m`.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) m " + String(format: "%02d", total % 60) + " s" }
        return "\(total / 3600) h " + String(format: "%02d", (total % 3600) / 60) + " m"
    }

    /// `1 step`, `9 steps`.
    static func stepCount(_ steps: Int) -> String {
        steps == 1 ? "1 step" : "\(steps) steps"
    }

    /// The right of an agent row (AF2): `9 steps` while it works,
    /// `14 steps · 1 m 52 s` once it ended.
    static func stepsLabel(steps: Int, elapsed: Double, finished: Bool) -> String {
        finished ? "\(stepCount(steps)) · \(duration(elapsed))" : stepCount(steps)
    }

    /// `3 agents`, `1 agent`.
    static func agentCount(_ count: Int) -> String {
        count == 1 ? "1 agent" : "\(count) agents"
    }

    /// The tray's header and collapsed line (AF2): `3 agents · 2 working`;
    /// when none works, `3 agents · 1 failed`, `3 agents · 1 stopped`, or
    /// `3 agents · done`.
    static func counts(_ statuses: [AgentStatus]) -> String {
        let all = agentCount(statuses.count)
        let working = statuses.filter { $0 == .working || $0 == .queued }.count
        if working > 0 { return "\(all) · \(working) working" }
        let failed = statuses.filter { $0 == .failed }.count
        if failed > 0 { return "\(all) · \(failed) failed" }
        let stopped = statuses.filter { $0 == .stopped }.count
        if stopped > 0 { return "\(all) · \(stopped) stopped" }
        return "\(all) · done"
    }

    /// The collapsed line's tail (AF2): the busiest agent and its step,
    /// `Checking quotes — reading transcripts/p11.md`; the description
    /// alone when it has reported no step.
    static func busyLine(description: String, step: String?) -> String {
        guard let step, !step.isEmpty else { return description }
        return "\(description) — \(lowercasedFirst(step))"
    }

    /// `Reading x` -> `reading x`; an initialism (`README`, `PDF`) stays.
    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }

    /// The conversation's row where the agent started them (decision 1):
    /// `Started 3 agents`.
    static func startedLabel(_ count: Int) -> String {
        "Started \(agentCount(count))"
    }

    /// Its tertiary tail.
    static let startedDetail = "details in the tray below"
    /// The same for a workflow's row.
    static let workflowDetail = "details in the box below"

    /// A workflow row's title: `Started Interview review`.
    static func workflowStartedLabel(_ name: String) -> String {
        "Started \(name)"
    }

    /// The box's header detail (AF3): `phase 2 of 3 · 7 agents · 4 m 10 s`;
    /// without phases, `7 agents · 4 m 10 s`.
    static func workflowHeader(currentPhase: Int?, phaseCount: Int, agents: Int, elapsed: Double) -> String {
        var parts: [String] = []
        if let currentPhase, phaseCount > 0 { parts.append("phase \(currentPhase + 1) of \(phaseCount)") }
        parts.append(agentCount(agents))
        parts.append(duration(elapsed))
        return parts.joined(separator: " · ")
    }

    /// A phase column's heading (AF3): `1 · Review`.
    static func phaseTitle(index: Int, name: String) -> String {
        "\(index + 1) · \(name)"
    }

    /// The rows a column shows and how many it leaves out: at most `limit`,
    /// the last place given to "…and N more" when there are more.
    static func overflow<T>(_ rows: [T], limit: Int) -> (shown: [T], more: Int) {
        guard rows.count > limit, limit > 0 else { return (rows, 0) }
        let shown = Array(rows.prefix(limit - 1))
        return (shown, rows.count - shown.count)
    }

    /// `…and 3 more`.
    static func moreLabel(_ count: Int) -> String {
        "…and \(count) more"
    }

    /// The right of an agent in a phase column (AF3): its summary when
    /// short (`6 findings`, `confirmed`), else its time; `0:38` while it
    /// works; `queued`, `failed`, `stopped`.
    static func result(status: AgentStatus, summary: String?, elapsed: Double) -> String {
        switch status {
        case .queued: return "queued"
        case .working: return AppModel.elapsedText(elapsed)
        case .failed: return "failed"
        case .stopped: return "stopped"
        case .done:
            if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
                summary.count <= shortSummary, !summary.contains("\n")
            {
                return summary
            }
            return duration(elapsed)
        }
    }

    /// A summary up to this long is a result; a longer one is a report.
    static let shortSummary = 24

    /// An agent row's second line: its step, else what it ended with.
    static func stepLine(status: AgentStatus, step: String?, summary: String?) -> String? {
        if status == .queued { return "Waiting for its phase" }
        if let step, !step.isEmpty, !status.isFinished { return step }
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary.split(separator: "\n").first.map(String.init)
        }
        return step
    }

    /// The record's line prefix (AF1).
    static let stepMark = "⎿"

    /// A record block's right (AF1): `14 steps · 1 m 52 s`, or for a
    /// phase `3 agents · 2 m 10 s`.
    static func phaseRecordLabel(agents: Int, elapsed: Double) -> String {
        "\(agentCount(agents)) · \(duration(elapsed))"
    }
}
