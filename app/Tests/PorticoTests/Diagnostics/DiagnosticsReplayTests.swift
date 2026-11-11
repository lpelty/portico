import AppKit
import XCTest

@testable import Portico

/// v0.26.4 (D8, D9, D10): the replay runner. A recording made hosted (as the
/// recording hooks tests make one) replays on the real `ConversationView`, and
/// the field entry point (`PORTICO_REPLAY=<file>`) writes the evaluation next
/// to the recording and goes red when the replay breaks an invariant.
@MainActor
final class DiagnosticsReplayTests: XCTestCase {
    private var tmp: URL!
    private var savedHome: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portico-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedHome = Diagnostics.home
        ReplayRunner.onStep = nil
    }

    override func tearDown() async throws {
        ReplayRunner.onStep = nil
        Diagnostics.closeAll()
        Diagnostics.home = savedHome
        Diagnostics.refresh()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    /// A recording made the way the field makes one: the switch on in a temp
    /// home, a 30-turn conversation hosted at 800 x 600, three wheels of 40 and
    /// a streamed reply. Returns the recording's file (under `<tmp>/record/diagnostics/recordings/`).
    private func hostedRecording() throws -> URL {
        let home = tmp.appendingPathComponent("record")
        Diagnostics.home = home
        try FileManager.default.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Diagnostics.switchFile.path, contents: nil)
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)

        let suite = "portico-replay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.4", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        var events: [ServerMessage] = []
        for turn in 1...30 {
            events.append(.userText(UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan about the Acme plan.")))
            events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). " + String(repeating: "Priya replied at length. ", count: 30))))
            events.append(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done)))
        }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: 3)))

        let hosted = try ReplayRunner.host(model, defaults: defaults, size: NSSize(width: 800, height: 600))
        defer { hosted.window.close() }
        for _ in 0..<3 {
            XCTAssertTrue(ReplayRunner.wheel(hosted, deltaY: 40, precise: true))
            ReplayRunner.spin(0.1)
        }
        model.apply(.textDelta(TextDelta(chat: 3, turn: 31, text: String(repeating: "x", count: 120))))
        ReplayRunner.spin(0.3)
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 31, outcome: .done)))
        ReplayRunner.spin(0.3)

        let url = try XCTUnwrap(Diagnostics.recorders[3]?.url, "a recorder for chat 3")
        Diagnostics.closeAll()
        // Off again, as the field turns it off before replaying (the runner must not need it).
        try FileManager.default.removeItem(at: Diagnostics.switchFile)
        Diagnostics.refresh()
        return url
    }

    /// A recording written line by line (no hosting).
    private func write(_ lines: [(Int, RecordingEvent)], name: String) throws -> URL {
        let dir = tmp.appendingPathComponent("crafted/diagnostics/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var text = ""
        for (t, event) in lines {
            let data = try encoder.encode(event)
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["t"] = t
            text += String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func open(window: [Int] = [800, 600], column: Int = 800) -> RecordingEvent {
        .open(chat: 9, appVersion: "0.26.4", macOS: "27.0", window: window, column: column,
              viewerVisible: false, viewerWidth: 0, sidebarVisible: false, textScale: 1)
    }

    private func conversation(turns: Int, prefix: String = "") -> [EntryShape] {
        (1...turns).flatMap { turn in [
            EntryShape(id: "user:\(prefix)\(turn)", kind: .person, paragraphs: [48]),
            EntryShape(id: "assistant:\(prefix)\(turn)", kind: .reply, paragraphs: [300, 240, 180]),
        ] }
    }

    private func images() -> URL { tmp.appendingPathComponent("images", isDirectory: true) }

    private func reading(step: Int, input: RecordingEvent?, offset: Double, settled: [Double] = []) -> Reading {
        Reading(step: step, input: input, offset: offset, documentHeight: 6000,
                clip: CGRect(x: 0, y: offset, width: 800, height: 600),
                rowsInView: [RowInView(id: "assistant:1", kind: .reply, height: 220, minY: offset)],
                phase: .idle, settledReadings: settled.isEmpty ? [6000, 6000] : settled)
    }

    // MARK: - Tests

    func testAHealthyRecordingReplaysWithZeroViolations() throws {
        let recording = try hostedRecording()
        let evaluation = try ReplayRunner.run(recording: recording, images: images())
        let text = evaluation.render()
        print("REPLAY-EVALUATION healthy\n\(text)")
        for r in ReplayRunner.lastReadings { print("REPLAY-STEP \(r.step) \(r.input.map { "\($0)" } ?? "none") offset=\(r.offset) doc=\(r.documentHeight)") }
        XCTAssertEqual(evaluation.violations, [], text)
        XCTAssertEqual(evaluation.segments, 1)
        guard case let .open(_, appVersion, macOS, _, _, _, _, _, _)? = try Recorder.read(recording).first?.event else {
            return XCTFail("the recording opens")
        }
        XCTAssertEqual(evaluation.appVersion, appVersion, "the recording's app, not the replaying build's")
        XCTAssertEqual(evaluation.macOS, macOS)
        XCTAssertEqual(evaluation.entriesByKind[.person], 30)
        XCTAssertGreaterThanOrEqual(evaluation.entriesByKind[.reply] ?? 0, 30)
        XCTAssertFalse(evaluation.heightHistogram.isEmpty, "row heights seen")
        XCTAssertTrue(text.contains("\nphases: fire="), "the phase probe's answer in the header")
        XCTAssertFalse(evaluation.window.isEmpty)
        // Rows are named by the recorded ids (ruling 11), never the synthetic ones.
        let recorded = Set(try Recorder.read(recording).compactMap { if case .shape(let s) = $0.event { s.id } else { nil } })
        let named = Set(evaluation.window.flatMap { $0.rowsInView.map(\.id) })
        XCTAssertFalse(named.isEmpty, "rows in view")
        XCTAssertTrue(named.isSubset(of: recorded), "rows \(named) are recorded ids")
        // Turn 31's stream is a reply of its own under the 30th (off screen: the view is scrolled up),
        // not growth of the 30th: that row keeps its height, the document grows.
        let readings = ReplayRunner.lastReadings
        let delta = try XCTUnwrap(readings.firstIndex { if case .delta = $0.input { true } else { false } })
        func thirtieth(_ r: Reading) -> Double? { r.rowsInView.first { $0.id == "assistant:30" }?.height }
        XCTAssertNotNil(thirtieth(readings[delta - 1]))
        XCTAssertEqual(thirtieth(readings[delta]), thirtieth(readings[delta - 1]), "the 30th reply did not grow")
        XCTAssertGreaterThan(readings[delta].documentHeight, readings[delta - 1].documentHeight + 50, "a new row")
        // The wheels were fed as recorded: three wheel steps.
        XCTAssertEqual(ReplayRunner.lastReadings.filter { if case .wheel = $0.input { true } else { false } }.count, 3)

        let file = try ReplayRunner.write(evaluation, for: recording)
        XCTAssertEqual(file.path, recording.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("evaluations").appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".txt").path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text + "\n")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
    }

    func testACraftedAlternationRecordingNamesTheRuleAndStep() throws {
        // Twelve 160 x 90 images on the message right at the fold (the newest turn's
        // question), the reply under it, then a wheel up into them.
        var shapes = conversation(turns: 12)
        shapes.append(EntryShape(id: "user:fold", kind: .person, paragraphs: [40], images: Array(repeating: [160, 90], count: 12)))
        shapes.append(EntryShape(id: "assistant:fold", kind: .reply, paragraphs: [200]))
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += shapes.map { (0, .shape($0)) }
        lines += [(500, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0)),
                  (600, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0))]
        let recording = try write(lines, name: "9-2026-11-10T21-05-00.250Z.jsonl")
        let live = try ReplayRunner.run(recording: recording, images: images())
        print("REPLAY-EVALUATION crafted-live\n\(live.render())")
        XCTAssertEqual(ReplayRunner.lastReadings.count, 3, "the opening reading and one per wheel")
        XCTAssertEqual(live.started, "2026-11-10T21:05:00.250Z")

        if !live.violations.contains(where: { $0.rule == .alternation }) {
            // The live view did not alternate on this Mac: hand the pure half readings that do.
            var readings = (0..<6).map { reading(step: $0, input: nil, offset: 5400) }
            readings[4] = reading(step: 4, input: nil, offset: 5400, settled: [6000, 6120, 6000, 6120, 6000, 6120])
            let crafted = ReplayRunner.check(readings: readings)
            print("REPLAY-EVALUATION crafted-injected\n\(crafted.render())")
            XCTAssertEqual(crafted.violations.map(\.rule), [.alternation])
            XCTAssertEqual(crafted.violations.first?.step, 4)
            XCTAssertTrue(crafted.render().contains("step 4 alternation: document height flipped between 6000 and 6120"))
            XCTAssertEqual(crafted.window.map(\.step), [3, 4, 5], "the failing step and its neighbours")
        }
    }

    func testReplayAcceptsACappedRecording() throws {
        // Two segments (the chat reopened), the second cut off by the cap.
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 4, prefix: "a").map { (0, .shape($0)) }
        lines += [(200, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0)),
                  (900, open(window: [900, 700], column: 640))]
        lines += conversation(turns: 20, prefix: "b").map { (900, .shape($0)) }
        lines += [(1000, .phase(.interacting)),
                  (1000, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0)),
                  (1100, .column(width: 560)),
                  (1200, .delta(turn: 21, chars: 400)),
                  (1300, .shape(EntryShape(id: "user:b21", kind: .person, paragraphs: [30]))),
                  (1400, .removed(id: "user:b1")),
                  (1500, .capped(bytes: 20_000_000))]
        let recording = try write(lines, name: "9-2026-11-10T22-00-00.000Z.jsonl")
        let evaluation = try ReplayRunner.run(recording: recording, images: images())
        print("REPLAY-EVALUATION capped\n\(evaluation.render())")
        XCTAssertEqual(evaluation.segments, 2)
        XCTAssertEqual(evaluation.lengthMs, 600, "the replayed segment's length")
        XCTAssertEqual(evaluation.entriesByKind[.person], 21, "the last segment's people, the appended one too")
        XCTAssertNil(evaluation.entriesByKind[.reply].flatMap { $0 == 4 ? $0 : nil }, "not the first segment's")
        let inputs = ReplayRunner.lastReadings.compactMap(\.input)
        XCTAssertEqual(inputs.count, 4, "wheel, column, delta, new shape: \(inputs)")
        XCTAssertEqual(ReplayRunner.lastReadings.first(where: { if case .wheel = $0.input { true } else { false } })?.phase, .interacting)
        XCTAssertEqual(Double(try XCTUnwrap(ReplayRunner.lastHostedWidth)), 560, accuracy: 0.5, "the column applied")
        XCTAssertTrue(ReplayRunner.lastNotes.contains { $0.hasPrefix("removed: 1") }, "\(ReplayRunner.lastNotes)")
        XCTAssertTrue(ReplayRunner.lastNotes.contains { $0.hasPrefix("capped: 1") }, "\(ReplayRunner.lastNotes)")
    }

    func testRunnerDisablesItsOwnRecorder() throws {
        // The field: the switch is on in the real home while Daedalus replays.
        let home = tmp.appendingPathComponent("field")
        Diagnostics.home = home
        try FileManager.default.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Diagnostics.switchFile.path, contents: nil)
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)

        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 10).map { (0, .shape($0)) }
        lines += [(100, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0)),
                  (200, .delta(turn: 10, chars: 200))]
        let recording = try write(lines, name: "9-2026-11-10T23-00-00.000Z.jsonl")
        var steps: [Int] = []
        ReplayRunner.onStep = { step in
            steps.append(step)
            XCTAssertFalse(Diagnostics.isOn, "off during the replay (step \(step))")
            XCTAssertTrue(Diagnostics.recorders.isEmpty, "no recorder during the replay (step \(step))")
        }
        _ = try ReplayRunner.run(recording: recording, images: images())
        XCTAssertEqual(steps, [0, 1, 2])
        XCTAssertEqual(Diagnostics.home, home, "home put back")
        XCTAssertTrue(Diagnostics.isOn, "the switch reads as before")
        let made = (try? FileManager.default.contentsOfDirectory(atPath: Diagnostics.recordingsDirectory.path)) ?? []
        XCTAssertEqual(made, [], "the replay recorded nothing")
    }

    func testReplayRecordingFromEnvironmentSkipsWithoutTheVariable() throws {
        XCTAssertThrowsError(try ReplayRunner.replayFromEnvironment([:])) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        XCTAssertThrowsError(try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": ""])) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
    }

    func testReplayFromEnvironmentWritesTheEvaluationNextToTheRecording() throws {
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 8).map { (0, .shape($0)) }
        lines += [(100, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0))]
        let recording = try write(lines, name: "9-2026-11-10T23-30-00.000Z.jsonl")
        let (evaluation, file) = try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": recording.path])
        XCTAssertEqual(file.lastPathComponent, "9-2026-11-10T23-30-00.000Z.txt")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "evaluations")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), evaluation.render() + "\n")
    }

    /// The field entry point: `PORTICO_REPLAY=<recording> swift test -c release
    /// --filter DiagnosticsReplayTests/testReplayRecordingFromEnvironment`. Red when the replay breaks an invariant.
    func testReplayRecordingFromEnvironment() throws {
        let (evaluation, file) = try ReplayRunner.replayFromEnvironment(ProcessInfo.processInfo.environment)
        print("PORTICO-EVALUATION \(file.path)\n\(evaluation.render())")
        XCTAssertEqual(evaluation.violations, [], "the replay reproduced a failure; evaluation at \(file.path)")
    }
}
