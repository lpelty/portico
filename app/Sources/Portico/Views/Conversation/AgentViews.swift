import SwiftUI

// Subagents and workflows (v0.10, design/portico.pen row AF): the tray on
// the composer (AF2), the workflow box in its place (AF3), the
// "Started N agents" row where the agent started them, and the folded
// record that row becomes when the turn ends (AF1). The words are
// `AgentPresentation`'s; the state is `AgentActivity`'s.

// MARK: - Above the composer

/// What sits on the composer while a turn's agents run: the workflow box
/// when a workflow runs (it takes the tray's place, decision 2), else the
/// tray; nothing once the turn has ended (decision 1).
struct AgentDock: View {
    let chat: Int
    /// The composer's side margins, so the box is exactly its width.
    let sideInset: CGFloat
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let activity = model.agentActivity[chat] {
            Group {
                if let workflow = activity.liveWorkflow {
                    WorkflowBox(chat: chat, workflow: workflow, activity: activity)
                } else if activity.showsTray {
                    AgentTray(chat: chat, activity: activity)
                }
            }
            .padding(.horizontal, sideInset)
            .padding(.bottom, 8)
        }
    }
}

/// The box the tray and the workflow box share: panel fill, a 1 pt
/// border, radius 10, the composer's width (AF2, AF3).
private struct DockBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Ticks once a second while anything works, so times move; still otherwise.
private struct Ticking<Content: View>: View {
    let running: Bool
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if running {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}

// MARK: - AF2: the tray

/// The live list of a turn's subagents, on the composer (decision 1, AF2).
/// Open: a header (`3 agents · 2 working`, the elapsed time, a chevron)
/// and a row per agent. Folded: one line with the busiest agent's step.
/// It folds itself when every agent is done; the chevron folds or opens it
/// by hand.
struct AgentTray: View {
    let chat: Int
    let activity: AgentActivity
    @EnvironmentObject private var model: AppModel

    private var agents: [AgentRun] { activity.trayAgents }
    private var statuses: [AgentStatus] { agents.map(activity.status(of:)) }
    private var working: Bool { statuses.contains(.working) }

    var body: some View {
        Ticking(running: working) { now in
            if activity.isTrayCollapsed { collapsed } else { open(now: now) }
        }
        .modifier(DockBox())
    }

    private var counts: String { AgentPresentation.counts(statuses) }

    private var collapsed: some View {
        Button { model.setTrayCollapsed(false, chat: chat) } label: {
            HStack(spacing: 8) {
                AgentBatchIcon(working: working, warning: statuses.contains { $0 == .failed || $0 == .stopped })
                Text(counts)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                if let busiest = activity.busiest(of: agents) {
                    Text(AgentPresentation.busyLine(description: busiest.description, step: busiest.step))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the agents")
        .accessibilityLabel("\(counts). Show the agents")
    }

    private func open(now: Date) -> some View {
        VStack(spacing: 0) {
            Button { model.setTrayCollapsed(true, chat: chat) } label: {
                HStack(spacing: 8) {
                    AgentBatchIcon(working: working, warning: statuses.contains { $0 == .failed || $0 == .stopped })
                    Text(counts)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(AgentPresentation.duration(activity.elapsed(of: agents, now: now)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fold the agents to one line")
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(agents) { agent in
                        AgentRowView(agent: agent, status: activity.status(of: agent), elapsed: activity.elapsed(of: agent, now: now), folder: folder)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: AgentTray.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The open tray's list scrolls past about six rows.
    static let listHeight: CGFloat = 264

    private var folder: String? { model.summary(of: chat)?.folder }
}

/// The header's icon for a batch: a spinner while any agent works, a
/// warning when one failed or stopped, else a check.
struct AgentBatchIcon: View {
    let working: Bool
    var warning: Bool = false

    var body: some View {
        Group {
            if working {
                ProgressView().controlSize(.mini)
            } else if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.wait)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.working)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// One agent's status (AF2): a spinner, a green check, an amber warning
/// (failed or stopped), a grey dot (queued).
struct AgentStatusIcon: View {
    let status: AgentStatus

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.working)
            case .failed, .stopped:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.wait)
            case .queued:
                Circle().fill(Theme.idle).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(Self.label(status))
    }

    static func label(_ status: AgentStatus) -> String {
        switch status {
        case .working: "working"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        case .queued: "queued"
        }
    }
}

/// One agent in the tray or the box's Agents tab (AF2): its status, its
/// description, its current step under it, and at the right `9 steps`
/// (`14 steps · 1 m 52 s` once ended). Clicking it shows its steps.
struct AgentRowView: View {
    let agent: AgentRun
    let status: AgentStatus
    let elapsed: Double
    var folder: String? = nil
    @State private var showingSteps = false

    var body: some View {
        Button { showingSteps.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                AgentStatusIcon(status: status)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.description)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let line = AgentPresentation.stepLine(status: status, step: agent.step, summary: agent.summary) {
                        Text(ToolRowView.display(line, in: folder))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(AgentPresentation.stepsLabel(steps: agent.steps, elapsed: elapsed, finished: status.isFinished))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.text3)
                    .fixedSize()
                    .padding(.top, 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(showingSteps ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this agent's steps")
        .popover(isPresented: $showingSteps, arrowEdge: .top) {
            AgentStepsView(agent: agent, status: status, folder: folder)
        }
    }
}

/// An agent's steps, read-only (decision 1: "opens its steps"): its tool
/// rows as the conversation draws them, or the steps it reported when the
/// gateway sent no rows for it. Shown in a popover on the row: the viewer
/// only shows artifacts (files and links) and has no place for a list.
struct AgentStepsView: View {
    let agent: AgentRun
    let status: AgentStatus
    var folder: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentStatusIcon(status: status)
                Text(agent.description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !agent.rows.isEmpty {
                        ForEach(agent.rows) { row in
                            ToolRowView(row: row, folder: folder)
                        }
                    } else if !agent.stepHistory.isEmpty {
                        ForEach(Array(agent.stepHistory.enumerated()), id: \.offset) { _, step in
                            StepLine(text: ToolRowView.display(step, in: folder))
                        }
                    } else {
                        Text("No steps yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                    if let summary = agent.summary, !summary.isEmpty, status.isFinished {
                        Text(summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 440)
    }
}

/// One record line (AF1): `⎿ Read transcripts/p11.md`.
struct StepLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(AgentPresentation.stepMark)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// MARK: - AF3: the workflow box

/// A running workflow, in the tray's place (decision 2, AF3): its name and
/// `phase 2 of 3 · 7 agents · 4 m 10 s`, a Phases | Agents | Log switch and
/// a chevron. About 290 pt tall, resized by dragging its top edge; folded,
/// the header alone, which then serves as the tray line.
struct WorkflowBox: View {
    let chat: Int
    let workflow: WorkflowRun
    let activity: AgentActivity
    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .phases
    @State private var height: CGFloat = WorkflowBox.startHeight
    @State private var dragStart: CGFloat?

    enum Tab: String, CaseIterable, Identifiable {
        case phases = "Phases"
        case agents = "Agents"
        case log = "Log"
        var id: String { rawValue }
    }

    /// AF3: about 290 pt tall to start; never under a few rows nor over most of a window.
    static let startHeight: CGFloat = 290
    static let minHeight: CGFloat = 140
    static let maxHeight: CGFloat = 640

    private var agents: [AgentRun] { activity.agents(in: workflow) }
    private var working: Bool { agents.contains { activity.status(of: $0) == .working } }
    private var collapsed: Bool { activity.isBoxCollapsed }

    var body: some View {
        Ticking(running: working || !activity.isDone(workflow)) { now in
            VStack(spacing: 0) {
                if !collapsed { resizeEdge }
                header(now: now)
                if !collapsed {
                    Rectangle().fill(Theme.border).frame(height: 1)
                    content(now: now)
                        .frame(height: max(Self.minHeight, height) - Self.headerHeight)
                }
            }
        }
        .modifier(DockBox())
    }

    /// The header's own height, which the box's height includes.
    private static let headerHeight: CGFloat = 46

    /// The top edge: drag it up to make the box taller.
    private var resizeEdge: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        dragStart = start
                        height = min(Self.maxHeight, max(Self.minHeight, start - value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag to resize")
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flowchart")
                .font(.system(size: 12))
                .foregroundStyle(model.brand.accent ?? Theme.accent)
                .frame(width: 14, height: 14)
            Text(workflow.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
            Text(AgentPresentation.workflowHeader(
                currentPhase: workflow.currentPhase, phaseCount: workflow.phases.count,
                agents: agents.count, elapsed: activity.elapsed(of: workflow, now: now)))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !collapsed {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Button { model.setBoxCollapsed(!collapsed, chat: chat) } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the workflow" : "Fold the workflow to one line")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, collapsed ? 9 : 6)
        .contentShape(Rectangle())
        .onTapGesture { if collapsed { model.setBoxCollapsed(false, chat: chat) } }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch tab {
        case .phases:
            // A workflow that names no phases shows its agents (AF3).
            if workflow.phases.isEmpty { agentList(now: now) } else { phaseColumns(now: now) }
        case .agents:
            agentList(now: now)
        case .log:
            log
        }
    }

    private var folder: String? { model.summary(of: chat)?.folder }

    private func agentList(now: Date) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(agents) { agent in
                    AgentRowView(agent: agent, status: activity.status(of: agent), elapsed: activity.elapsed(of: agent, now: now), folder: folder)
                }
                if agents.isEmpty {
                    Text("No agents yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .padding(6)
        }
    }

    /// One column per phase (AF3), each as wide as the box allows (at
    /// least `columnMin`; narrower boxes scroll sideways).
    private func phaseColumns(now: Date) -> some View {
        GeometryReader { geometry in
            let count = CGFloat(max(1, workflow.phases.count))
            let width = max(Self.columnMin, (geometry.size.width - 24 - (count - 1) * 12) / count)
            let limit = PhaseColumn.rowLimit(height: geometry.size.height)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(workflow.phases.enumerated()), id: \.offset) { index, name in
                        PhaseColumn(
                            index: index, name: name, state: workflow.state(ofPhase: index),
                            agents: activity.agents(inPhase: index, of: workflow), activity: activity,
                            now: now, limit: limit, folder: folder)
                            .frame(width: width, alignment: .topLeading)
                    }
                }
                .padding(12)
            }
        }
    }

    static let columnMin: CGFloat = 200

    private var log: some View {
        let lines = activity.logLines(of: workflow)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.agent.description)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .frame(width: 160, alignment: .leading)
                        Text(ToolRowView.display(line.text, in: folder))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if lines.isEmpty {
                    Text("No steps yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

/// One phase's column (AF3): a status icon and `1 · Review` (tertiary
/// until it starts), then its agents, the last place given to
/// "…and N more" when they do not fit.
struct PhaseColumn: View {
    let index: Int
    let name: String
    let state: PhaseState
    let agents: [AgentRun]
    let activity: AgentActivity
    let now: Date
    let limit: Int
    var folder: String? = nil

    /// How many rows fit a column `height` tall: the heading, then about
    /// 40 pt a row.
    static func rowLimit(height: CGFloat) -> Int {
        max(2, Int((height - 24 - 28) / 40))
    }

    var body: some View {
        let (shown, more) = AgentPresentation.overflow(agents, limit: limit)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PhaseStatusIcon(state: state, warning: agents.contains { activity.status(of: $0) == .failed })
                Text(AgentPresentation.phaseTitle(index: index, name: name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .pending ? Theme.text3 : Theme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            ForEach(shown) { agent in
                PhaseAgentRow(agent: agent, status: activity.status(of: agent), elapsed: activity.elapsed(of: agent, now: now), folder: folder)
            }
            if more > 0 {
                Text(AgentPresentation.moreLabel(more))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
        }
    }
}

/// A phase's status: a grey dot pending, a spinner running, a check (or a
/// warning when one of its agents failed) done, a warning failed.
struct PhaseStatusIcon: View {
    let state: PhaseState
    var warning: Bool = false

    var body: some View {
        switch state {
        case .pending: AgentStatusIcon(status: .queued)
        case .running: AgentStatusIcon(status: .working)
        case .done: AgentStatusIcon(status: warning ? .failed : .done)
        case .failed: AgentStatusIcon(status: .failed)
        }
    }
}

/// An agent in a phase column (AF3): status, name, step, and at the right
/// its result (`6 findings`, `confirmed`, `0:38`, `queued`).
struct PhaseAgentRow: View {
    let agent: AgentRun
    let status: AgentStatus
    let elapsed: Double
    var folder: String? = nil
    @State private var showingSteps = false

    var body: some View {
        Button { showingSteps.toggle() } label: {
            HStack(alignment: .top, spacing: 6) {
                AgentStatusIcon(status: status)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status == .queued ? Theme.text2 : Theme.text)
                        .lineLimit(1)
                    if status != .queued, let line = AgentPresentation.stepLine(status: status, step: agent.step, summary: nil) {
                        Text(ToolRowView.display(line, in: folder))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(AgentPresentation.result(status: status, summary: agent.summary, elapsed: elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.top, 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(showingSteps ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this agent's steps")
        .popover(isPresented: $showingSteps, arrowEdge: .top) {
            AgentStepsView(agent: agent, status: status, folder: folder)
        }
    }
}

// MARK: - In the conversation

/// The conversation's row for a batch of agents: while its turn runs, one
/// row like a tool row (`Started 3 agents`, "details in the tray below");
/// after it, the folded record (AF1) — a block per agent, or per phase for
/// a workflow.
struct AgentGroupView: View {
    let group: AgentGroup
    let chat: Int
    var folder: String? = nil
    @EnvironmentObject private var model: AppModel

    private var activity: AgentActivity { model.agentActivity[chat] ?? AgentActivity() }

    var body: some View {
        if activity.isLive(group) {
            startedRow
        } else {
            record
        }
    }

    private var workflow: WorkflowRun? { group.workflowId.flatMap(activity.workflow) }

    private var startedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: workflow == nil ? "person.2" : "flowchart")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text2)
                .frame(width: 14, height: 14)
            Text(workflow.map { AgentPresentation.workflowStartedLabel($0.name) } ?? AgentPresentation.startedLabel(group.agentIds.count))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(workflow == nil ? AgentPresentation.startedDetail : AgentPresentation.workflowDetail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var record: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let workflow, !workflow.phases.isEmpty {
                ForEach(Array(workflow.phases.enumerated()), id: \.offset) { index, name in
                    let members = activity.agents(inPhase: index, of: workflow)
                    PhaseRecordBlock(
                        title: AgentPresentation.phaseTitle(index: index, name: name),
                        agents: members, activity: activity,
                        status: activity.recordStatus(ofPhase: index, in: workflow))
                }
            } else {
                let members = workflow.map(activity.agents(in:)) ?? group.agentIds.compactMap(activity.agent)
                ForEach(members) { agent in
                    AgentRecordBlock(agent: agent, status: activity.status(of: agent), folder: folder)
                }
            }
        }
    }
}

/// The tag chip on a record block: `Agent`, `Phase`.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// One agent's folded record (AF1): ✓ or ⚠, an `Agent` chip, its
/// description, `14 steps · 1 m 52 s`, a chevron; open, its steps
/// prefixed `⎿` and what it ended with.
struct AgentRecordBlock: View {
    let agent: AgentRun
    let status: AgentStatus
    var folder: String? = nil
    @State private var expanded = false

    var body: some View {
        RecordBlock(
            status: status, tag: "Agent", title: agent.description,
            trailing: AgentPresentation.stepsLabel(steps: agent.steps, elapsed: agent.elapsed, finished: true),
            expanded: $expanded
        ) {
            ForEach(Array(agent.stepLines.enumerated()), id: \.offset) { _, line in
                StepLine(text: ToolRowView.display(line, in: folder))
            }
            if let summary = agent.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
    }
}

/// One workflow phase's folded record (AF1): ✓ or ⚠, a `Phase` chip,
/// `1 · Review`, `3 agents · 2 m 10 s`; open, a line per agent.
struct PhaseRecordBlock: View {
    let title: String
    let agents: [AgentRun]
    let activity: AgentActivity
    /// ✓ or ⚠: `AgentActivity.recordStatus(ofPhase:in:)`.
    let status: AgentStatus
    @State private var expanded = false

    var body: some View {
        RecordBlock(
            status: status, tag: "Phase", title: title,
            trailing: AgentPresentation.phaseRecordLabel(agents: agents.count, elapsed: agents.map(\.elapsed).max() ?? 0),
            expanded: $expanded
        ) {
            ForEach(agents) { agent in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(AgentPresentation.stepMark)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    AgentStatusIcon(status: activity.status(of: agent))
                    Text(agent.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(AgentPresentation.result(status: activity.status(of: agent), summary: agent.summary, elapsed: agent.elapsed))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The bordered, folded block AF1 draws for an agent or a phase.
struct RecordBlock<Detail: View>: View {
    let status: AgentStatus
    let tag: String
    let title: String
    let trailing: String
    @Binding var expanded: Bool
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: status == .done ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status == .done ? Theme.working : Theme.wait)
                        .frame(width: 14, height: 14)
                    TagChip(text: tag)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(trailing)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                        .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    detail()
                }
                .padding(.leading, 22)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}
