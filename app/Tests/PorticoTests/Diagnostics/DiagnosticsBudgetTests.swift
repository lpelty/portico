import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.26.4 (D15, P6): the suite on costs a bounded amount of main-thread time.
/// Off costs a Bool read; on is held to the SendFreezeTests scenario's pace
/// and to a per-event budget (average under 1 ms, structural events under
/// 2 ms in a debug build; the full path is O(n), so 800 turns gets 4 ms).
@MainActor
final class DiagnosticsBudgetTests: XCTestCase {
    private var tmp: URL!
    private var savedHome: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portico-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedHome = Diagnostics.home
        Diagnostics.home = tmp
        ScrollTrace.override = nil
        ScrollTrace.sink = nil
        Diagnostics.refresh()
    }

    override func tearDown() async throws {
        Diagnostics.closeAll()
        ScrollTrace.closeHandle()
        ConversationProbe.enabled = false
        ConversationProbe.recordingChangeNanos = []
        Diagnostics.home = savedHome
        Diagnostics.refresh()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers (copied from SendFreezeTests, kept private there)

    private func switchOn() throws {
        try FileManager.default.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Diagnostics.switchFile.path, contents: nil)
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)
    }

    private func switchOff() {
        try? FileManager.default.removeItem(at: Diagnostics.switchFile)
        Diagnostics.refresh()
        XCTAssertFalse(Diagnostics.isOn)
    }

    private func model(turns: Int) throws -> AppModel {
        let suite = "portico-budget-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions", ChatHistory.timesCapability], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        var events: [ServerMessage] = []
        let start = Date().addingTimeInterval(-Double(turns) * 120)
        for turn in 1...turns {
            let at = ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(turn) * 120))
            events.append(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan " + String(repeating: "pasted context line. ", count: 100), ts: at)))
            for k in 0..<3 {
                let id = "t\(turn)-\(k)"
                events.append(.toolStarted(ToolStarted(chat: 3, turn: turn, toolUseId: id, tool: "Bash", summary: "ls -la step \(k)", input: [:], ts: at)))
                events.append(.toolFinished(ToolFinished(chat: 3, turn: turn, toolUseId: id, ok: true, summary: "done", ts: at)))
            }
            events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). \(reply)", ts: at)))
            events.append(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done, ts: at)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3)))
        return model
    }

    private struct Selected: View {
        @EnvironmentObject var model: AppModel
        var body: some View {
            if let chat = model.selected { ConversationView(chat: chat).id(chat) }
        }
    }

    private func host(_ model: AppModel) -> NSWindow {
        _ = NSApplication.shared
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(1)
        return window
    }

    private func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// A send in the long conversation: the person's turn, then the reply's 40 updates.
    /// Returns the wall time of the 40 updates.
    private func streamedReply(turns: Int, on: Bool) throws -> TimeInterval {
        if on { try switchOn() } else { switchOff() }
        let model = try model(turns: turns)
        let window = host(model)
        defer { window.close() }
        var seq = 1000
        model.sendMessage(chat: 3, text: "Please log the session")
        seq += 1
        model.apply(.turnStarted(TurnStarted(chat: 3, turn: turns + 1, seq: seq)))
        seq += 1
        model.apply(.userText(UserText(chat: 3, turn: turns + 1, text: "Please log the session", seq: seq)))
        spin(0.3)
        let t0 = Date()
        for i in 0..<40 {
            seq += 1
            if i % 8 == 0 {
                model.apply(.toolStarted(ToolStarted(chat: 3, turn: turns + 1, toolUseId: "live\(i)", tool: "Bash", summary: "step \(i)", input: [:], seq: seq)))
                seq += 1
                model.apply(.toolFinished(ToolFinished(chat: 3, turn: turns + 1, toolUseId: "live\(i)", ok: true, summary: "ok", seq: seq)))
                seq += 1
            }
            model.apply(.textDelta(TextDelta(chat: 3, turn: turns + 1, text: "word\(i) " + (i % 5 == 0 ? "\n\nA new paragraph of the reply that keeps growing. " : ""), seq: seq)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        return Date().timeIntervalSince(t0)
    }

    private struct Step {
        let kind: String
        let structural: Bool
        let action: (AppModel, inout Int) -> Void
    }

    /// Per-change main-thread cost of the recording's own work (snapshot + diff,
    /// the region `ConversationProbe.recordingChangeNanos` times), tagged by step.
    private func measure(turns: Int, deltas: Int, steps: [Step]) throws -> [(kind: String, structural: Bool, ms: Double)] {
        try switchOn()
        let model = try model(turns: turns)
        let window = host(model)
        defer { window.close() }
        ConversationProbe.enabled = true
        ConversationProbe.recordingChangeNanos = []
        var seq = 1000
        var taken = 0
        var out: [(kind: String, structural: Bool, ms: Double)] = []
        func mark(_ kind: String, _ structural: Bool) {
            let all = ConversationProbe.recordingChangeNanos
            for nanos in all[taken...] { out.append((kind, structural, Double(nanos) / 1_000_000)) }
            taken = all.count
        }
        for step in steps {
            step.action(model, &seq)
            spin(0.1)
            mark(step.kind, step.structural)
        }
        _ = deltas
        return out
    }

    private func structuralSteps(turns: Int, deltas: Int) -> [Step] {
        let turn = turns + 1
        var steps: [Step] = [
            Step(kind: "turnStarted+userText", structural: true) { model, seq in
                seq += 1
                model.apply(.turnStarted(TurnStarted(chat: 3, turn: turn, seq: seq)))
                seq += 1
                model.apply(.userText(UserText(chat: 3, turn: turn, text: "Please log the session", seq: seq)))
            },
            Step(kind: "toolStarted", structural: true) { model, seq in
                seq += 1
                model.apply(.toolStarted(ToolStarted(chat: 3, turn: turn, toolUseId: "live-a", tool: "Bash", summary: "step", input: [:], seq: seq)))
            },
            Step(kind: "toolFinished", structural: true) { model, seq in
                seq += 1
                model.apply(.toolFinished(ToolFinished(chat: 3, turn: turn, toolUseId: "live-a", ok: true, summary: "ok", seq: seq)))
            },
            Step(kind: "newReply", structural: true) { model, seq in
                seq += 1
                model.apply(.textDelta(TextDelta(chat: 3, turn: turn, text: "First words ", seq: seq)))
            },
        ]
        for i in 0..<deltas {
            steps.append(Step(kind: "delta", structural: false) { model, seq in
                seq += 1
                model.apply(.textDelta(TextDelta(chat: 3, turn: turn, text: "word\(i) " + (i % 5 == 0 ? "\n\nA new paragraph of the reply that keeps growing. " : ""), seq: seq)))
            })
        }
        steps.append(Step(kind: "turnFinished", structural: true) { model, seq in
            seq += 1
            model.apply(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done, seq: seq)))
        })
        steps.append(Step(kind: "nextTurn", structural: true) { model, seq in
            seq += 1
            model.apply(.turnStarted(TurnStarted(chat: 3, turn: turn + 1, seq: seq)))
            seq += 1
            model.apply(.userText(UserText(chat: 3, turn: turn + 1, text: "And again", seq: seq)))
        })
        return steps
    }

    private func report(_ label: String, _ rows: [(kind: String, structural: Bool, ms: Double)]) {
        let times = rows.map(\.ms)
        let average = times.reduce(0, +) / Double(max(times.count, 1))
        var maxima: [String: Double] = [:]
        for row in rows { maxima[row.kind] = max(maxima[row.kind] ?? 0, row.ms) }
        let kinds = maxima.sorted { $0.key < $1.key }.map { String(format: "%@=%.3f", $0.key, $0.value) }.joined(separator: " ")
        print(String(format: "BUDGET %@ n=%d average=%.3f ms max=%.3f ms", label, times.count, average, times.max() ?? 0), "per-kind max ms:", kinds)
    }

    // MARK: - Tests

    func testStreamingWithDiagnosticsOnStaysWithinBudget() throws {
        let off = try streamedReply(turns: 400, on: false)
        Diagnostics.closeAll()
        let on = try streamedReply(turns: 400, on: true)
        print(String(format: "BUDGET streaming 400 turns off=%.3fs on=%.3fs ratio=%.2f", off, on, on / off))
        XCTAssertLessThanOrEqual(on, off * 1.5, "on \(on)s vs off \(off)s")
        XCTAssertLessThanOrEqual(on, 3.0)
        let url = try XCTUnwrap(Diagnostics.recorders[3]?.url, "a recorder for chat 3")
        Diagnostics.closeAll()
        let events = try Recorder.read(url)
        let deltas = events.filter { if case .delta = $0.event { true } else { false } }
        XCTAssertEqual(deltas.count, 40, "one delta per update")
    }

    func testPerEventMainThreadCostIsWithinBudget() throws {
        let rows = try measure(turns: 400, deltas: 40, steps: structuralSteps(turns: 400, deltas: 40))
        report("per-event 400 turns", rows)
        let times = rows.map(\.ms)
        XCTAssertGreaterThanOrEqual(rows.filter(\.structural).count, 5, "structural changes were recorded")
        XCTAssertGreaterThanOrEqual(rows.filter { $0.kind == "delta" }.count, 30, "the deltas were recorded")
        XCTAssertLessThan(times.reduce(0, +) / Double(max(times.count, 1)), 1.0, "average per recorded change")
        for row in rows where row.structural {
            XCTAssertLessThan(row.ms, 2.0, "structural \(row.kind)")
        }
    }

    func testLongTranscriptStructuralCostIsReported() throws {
        let rows = try measure(turns: 800, deltas: 0, steps: structuralSteps(turns: 800, deltas: 0))
        report("long 800 turns", rows)
        for row in rows { print(String(format: "BUDGET long %@ %.3f ms", row.kind, row.ms)) }
        XCTAssertGreaterThanOrEqual(rows.filter(\.structural).count, 5)
        for row in rows where row.structural {
            XCTAssertLessThan(row.ms, 4.0, "O(n) full path at 800 turns: \(row.kind)")
        }
    }
}
