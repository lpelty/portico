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

    private func open(window: [Int] = [800, 600], column: Int = 800, textScale: Double = 1, atBottom: Bool = true,
                      topId: String? = nil, topOffset: Int = 0, clipHeight: Int = 0) -> RecordingEvent {
        .open(chat: 9, appVersion: "0.26.4", macOS: "27.0", window: window, column: column,
              viewerVisible: false, viewerWidth: 0, sidebarVisible: false, textScale: textScale,
              atBottom: atBottom, topId: topId, topOffset: topOffset, clipHeight: clipHeight)
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
        guard case let .open(_, appVersion, macOS, _, _, _, _, _, _, _, _, _, _)? = try Recorder.read(recording).first?.event else {
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
        // G2: no drawn row lacks a recorded stand-in, at any step; a failure names the row's kind and height.
        let unmappedRows = ReplayRunner.lastReadings.flatMap { r in
            r.rowsInView.filter { $0.id == ReplayRunner.unmapped }.map { "step \(r.step) \($0.kind.rawValue):\(Int($0.height.rounded()))" }
        }
        XCTAssertEqual(unmappedRows, [], "every drawn row maps to a recorded id")
        XCTAssertTrue(named.isSubset(of: recorded), "rows \(named) are recorded ids")
        // I5: the window's rows carry their recorded metrics, its inputs their fields.
        XCTAssertTrue(evaluation.window.allSatisfy { $0.rowsInView.allSatisfy { $0.shape != nil } }, "every row's shape")
        XCTAssertTrue(text.contains(":reply:") && text.contains("{paragraphs=["), text)
        XCTAssertTrue(text.contains("input=delta(turn=31 chars=120)") || text.contains("input=turnFinished(31)"), text)
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

        XCTAssertEqual(evaluation.steps, ReplayRunner.lastReadings.count)
        XCTAssertTrue(text.contains("\nsteps: \(evaluation.steps)\n"))
        let file = try ReplayRunner.write(evaluation, for: recording, in: Diagnostics.evaluationsDirectory)
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
            XCTAssertTrue(crafted.render().contains("step 1.4 alternation: document height flipped between 6000 and 6120"))
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
        XCTAssertEqual(evaluation.replayed, [1, 2], "every segment replays (I4)")
        XCTAssertEqual(evaluation.lengthMs, 1500, "the replayed segments' length")
        XCTAssertEqual(evaluation.entriesByKind[.person], 21, "the last segment's people, the appended one too")
        XCTAssertEqual(evaluation.entriesByKind[.reply], 20, "the last segment's replies (the delta grew the 20th)")
        XCTAssertEqual(evaluation.skipped, ["capped": 1, "removed": 1])
        XCTAssertTrue(evaluation.render().contains("\nskipped: capped 1, removed 1\n"))
        XCTAssertEqual(ReplayRunner.lastReadings.filter { $0.segment == 1 }.compactMap(\.input).count, 1, "the first segment's wheel")
        let second = ReplayRunner.lastReadings.filter { $0.segment == 2 }
        let inputs = second.compactMap(\.input)
        XCTAssertEqual(inputs.count, 4, "wheel, column, delta, new shape: \(inputs)")
        XCTAssertEqual(second.first(where: { if case .wheel = $0.input { true } else { false } })?.phase, .interacting)
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

    func testReplayFromEnvironmentWritesTheEvaluationUnderDiagnostics() throws {
        // A mouse's line wheels (fractional, both ways) and a key, as a field recording holds them.
        Diagnostics.home = tmp.appendingPathComponent("crafted")
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 8).map { (0, .shape($0)) }
        lines += [(100, .wheel(deltaY: 40, precise: true, phase: 0, momentum: 0)),
                  (200, .wheel(deltaY: 1, precise: false, phase: 0, momentum: 0)),
                  (300, .wheel(deltaY: 0.4, precise: false, phase: 0, momentum: 0)),
                  (400, .wheel(deltaY: 0.4, precise: false, phase: 0, momentum: 0)),
                  (500, .wheel(deltaY: -2.5, precise: false, phase: 0, momentum: 0)),
                  (600, .key(.pageUp))]
        let recording = try write(lines, name: "9-2026-11-10T23-30-00.000Z.jsonl")
        let (evaluation, file) = try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": recording.path])
        let text = evaluation.render()
        print("REPLAY-EVALUATION env\n\(text)")
        for r in ReplayRunner.lastReadings { print("REPLAY-STEP \(r.step) \(r.input.map { "\($0)" } ?? "none") offset=\(r.offset)") }
        XCTAssertEqual(evaluation.violations, [], "line wheels move by lines, checked by direction (ruling 12)")
        let offsets = ReplayRunner.lastReadings.map(\.offset)
        XCTAssertLessThan(offsets[2], offsets[1] - 1, "one line up moved up")
        XCTAssertLessThan(offsets[3], offsets[2], "0.4 lines up moved up")
        XCTAssertLessThan(offsets[4], offsets[3], "0.4 lines up moved up")
        XCTAssertGreaterThan(offsets[5], offsets[4] + 1, "2.5 lines down moved down")
        // Ruling 13: the key is counted; one that did not move is noted in its window line, never a violation.
        XCTAssertEqual(evaluation.keysStepped, 1)
        XCTAssertTrue(text.contains("\nkeys: 1 stepped, \(evaluation.keysMoved) moved\n"))
        if evaluation.keysMoved == 0 { XCTAssertTrue(text.contains("input=key(pageUp) ") && text.contains("note=key-not-moved"), text) }
        XCTAssertEqual(file.path, Diagnostics.evaluationsDirectory.appendingPathComponent("9-2026-11-10T23-30-00.000Z.txt").path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text + "\n")
    }

    /// I3: a trackpad gesture (began, changed x3, ended) is one run: fed at its recorded spacing
    /// inside the zero-delta envelope, read per wheel without settling, settled once at its end;
    /// a wheel on its own keeps its own settle.
    func testAGestureRunIsFedAsOneRunAndSettlesOnceAtItsEnd() throws {
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 10).map { (0, .shape($0)) }
        lines += [(1000, .wheel(deltaY: 0, precise: true, phase: 1, momentum: 0)),
                  (1016, .phase(.interacting)),
                  (1016, .wheel(deltaY: -30, precise: true, phase: 4, momentum: 0)),
                  (1040, .wheel(deltaY: -30, precise: true, phase: 4, momentum: 0)),
                  (1200, .wheel(deltaY: -30, precise: true, phase: 4, momentum: 0)),
                  (1220, .wheel(deltaY: 0, precise: true, phase: 8, momentum: 0)),
                  (1300, .phase(.idle)),
                  (2000, .wheel(deltaY: -40, precise: true, phase: 0, momentum: 0))]
        let recording = try write(lines, name: "9-2026-11-10T23-45-00.000Z.jsonl")
        let evaluation = try ReplayRunner.run(recording: recording, images: images())
        let text = evaluation.render()
        print("REPLAY-EVALUATION run\n\(text)")
        XCTAssertEqual(ReplayRunner.lastRuns.runs, 1, "one gesture run")
        XCTAssertEqual(ReplayRunner.lastRuns.wheels, 5, "its five wheels")
        let readings = ReplayRunner.lastReadings
        XCTAssertEqual(readings.count, 7, "the opening reading and one per wheel")
        XCTAssertEqual(readings[1...4].map(\.settledReadings.count), [1, 1, 1, 1], "no settle inside the run")
        XCTAssertGreaterThanOrEqual(readings[5].settledReadings.count, 20 + 5, "the run's heights and one settle at its end")
        XCTAssertEqual(readings[6].settledReadings.count, 20, "a wheel on its own settles on its own")
        XCTAssertEqual(evaluation.envelope, "on (1 gesture runs)", "the phases fired around the run (spike: they do on this Mac)")
        XCTAssertTrue(text.contains("\nenvelope: on (1 gesture runs)\n"), text)
    }

    /// I3c: a field replay says up front how many steps it takes and about how long.
    func testTheEstimateCountsStepsAndSeconds() throws {
        var lines: [(t: Int, event: RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 2).map { (t: 0, event: .shape($0)) }
        lines += [(100, .wheel(deltaY: 1, precise: false, phase: 0, momentum: 0)), (200, .key(.end)), (300, .phase(.idle)),
                  (400, .removed(id: "x")), (500, open())]
        lines += conversation(turns: 2).map { (t: 500, event: .shape($0)) }
        lines += [(600, .delta(turn: 3, chars: 9))]
        let estimate = ReplayRunner.estimate(lines)
        XCTAssertEqual(estimate.steps, 5, "an opening reading per segment, a wheel, a key, a delta")
        XCTAssertEqual(estimate.seconds, 10, "the phase probe, hosting per segment, each step's settle (4 + 2 x 2 + 5 x 0.35, up)")
    }

    /// I4: every segment replays in order, each from its own `open`; readings are numbered
    /// `segment.step` and violations reported per segment. The first segment's window shrinks
    /// to nothing (no row in view, on any Mac); the second is healthy.
    private func twoSegments() throws -> URL {
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 4, prefix: "a").map { (0, .shape($0)) }
        lines += [(100, .window(width: 800, height: 1))]
        lines += [(900, open(window: [900, 700], column: 700))]
        lines += conversation(turns: 6, prefix: "b").map { (900, .shape($0)) }
        lines += [(1000, .key(.end))]
        return try write(lines, name: "9-2026-11-11T09-00-00.000Z.jsonl")
    }

    func testEverySegmentReplaysAndAFirstSegmentViolationIsRed() throws {
        let evaluation = try ReplayRunner.run(recording: try twoSegments(), images: images())
        let text = evaluation.render()
        print("REPLAY-EVALUATION segments\n\(text)")
        XCTAssertEqual(evaluation.segments, 2)
        XCTAssertEqual(Set(ReplayRunner.lastReadings.map(\.segment)), [1, 2], "both segments replayed")
        XCTAssertEqual(ReplayRunner.lastReadings.filter { $0.segment == 2 }.map(\.step), [0, 1], "the second from its own open")
        XCTAssertFalse(evaluation.violations.isEmpty, "the first segment's violation is red")
        XCTAssertEqual(Set(evaluation.violations.map(\.segment)), [1])
        XCTAssertTrue(text.contains("\nstep 1.1 rowsInView: "), text)
        XCTAssertTrue(text.contains("\nper segment: 1=\(evaluation.violations.count), 2=0\n"), text)
        XCTAssertTrue(evaluation.window.allSatisfy { $0.segment == 1 }, "the window is the failing segment's")
    }

    func testOneSegmentReplaysWhenNamed() throws {
        let recording = try twoSegments()
        let evaluation = try ReplayRunner.run(recording: recording, images: images(), segment: 2)
        XCTAssertEqual(Set(ReplayRunner.lastReadings.map(\.segment)), [2])
        XCTAssertEqual(evaluation.violations, [])
        XCTAssertTrue(evaluation.render().contains("\nper segment: 2=0\n"))
        XCTAssertEqual(ReplayRunner.segment(from: ["PORTICO_REPLAY_SEGMENT": "2"]), 2)
        XCTAssertNil(ReplayRunner.segment(from: [:]))
        XCTAssertThrowsError(try ReplayRunner.run(recording: recording, images: images(), segment: 3))
        // The field entry point reads the variable.
        Diagnostics.home = tmp.appendingPathComponent("crafted")
        let (fromEnvironment, _) = try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": recording.path, "PORTICO_REPLAY_SEGMENT": "2"])
        XCTAssertEqual(fromEnvironment.replayed, [2])
    }

    /// I4: an `open` that says scrolled up starts the replay scrolled up: the recorded top row at
    /// the recorded distance from the view's top, in a view of the recorded clip height.
    func testAScrolledUpOpenStartsTheReplayScrolledUp() throws {
        var lines: [(Int, RecordingEvent)] = [(0, open(atBottom: false, topId: "assistant:6", topOffset: -40, clipHeight: 480))]
        lines += conversation(turns: 20).map { (0, .shape($0)) }
        lines += [(100, .key(.down))]
        let recording = try write(lines, name: "9-2026-11-11T09-30-00.000Z.jsonl")
        _ = try ReplayRunner.run(recording: recording, images: images())
        let first = try XCTUnwrap(ReplayRunner.lastReadings.first)
        for r in ReplayRunner.lastReadings { print("REPLAY-STEP \(r.segment).\(r.step) offset=\(r.offset) doc=\(r.documentHeight) clip=\(r.clip) rows=\(r.rowsInView.map { "\($0.id)@\(Int($0.minY))" })") }
        XCTAssertEqual(Double(first.clip.height), 480, accuracy: 1, "hosted at the recorded clip height")
        let top = try XCTUnwrap(first.rowsInView.first { $0.id == "assistant:6" }, "the recorded top row in view: \(first.rowsInView.map(\.id))")
        XCTAssertEqual(top.minY - first.offset, -40, accuracy: 8, "at the recorded distance from the view's top")
        XCTAssertLessThan(Double(first.clip.maxY), first.documentHeight - 100, "scrolled up, not at the bottom")
    }

    /// G1 (Ruling 15): a line wheel is sent as a precise pixel wheel of lines x the scroll view's
    /// line height, in the recorded direction; the reading keeps the recorded (line) input.
    func testALineWheelIsSentAsAPixelWheelOfLinesTimesTheLineHeight() throws {
        XCTAssertEqual(ReplayRunner.pixels(deltaY: -2.5, precise: false, lineHeight: 12), -30)
        XCTAssertEqual(ReplayRunner.pixels(deltaY: 0.4, precise: false, lineHeight: 0), 4, "no line height: 10 pt")
        XCTAssertEqual(ReplayRunner.pixels(deltaY: 40, precise: true, lineHeight: 12), 40, "a pixel wheel as recorded")
        let event = try XCTUnwrap(ReplayRunner.wheelEvent(pixels: -25, at: .zero))
        XCTAssertTrue(event.hasPreciseScrollingDeltas, "sent in pixels")
        XCTAssertEqual(event.scrollingDeltaY, -25)

        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 8).map { (0, .shape($0)) }
        lines += [(100, .wheel(deltaY: 1, precise: false, phase: 0, momentum: 0)),
                  (200, .wheel(deltaY: 0.4, precise: false, phase: 0, momentum: 0)),
                  (300, .wheel(deltaY: 0.4, precise: false, phase: 0, momentum: 0)),
                  (400, .wheel(deltaY: -2.5, precise: false, phase: 0, momentum: 0))]
        let recording = try write(lines, name: "9-2026-11-10T23-40-00.000Z.jsonl")
        _ = try ReplayRunner.run(recording: recording, images: images())
        let height = try XCTUnwrap(ReplayRunner.lastLineHeight)
        XCTAssertEqual(ReplayRunner.lastSentWheels.count, 4)
        for (sent, lines) in zip(ReplayRunner.lastSentWheels, [1, 0.4, 0.4, -2.5]) {
            XCTAssertTrue(sent.precise, "a pixel wheel")
            XCTAssertEqual(sent.pixels, lines * height, accuracy: 1, "lines x line height (\(height)), in the recorded direction")
        }
        XCTAssertEqual(ReplayRunner.lastSentWheels.map(\.pixels).reduce(0, +), -0.7 * height, accuracy: 1, "remainders carried")
        let inputs = ReplayRunner.lastReadings.compactMap(\.input)
        XCTAssertTrue(inputs.allSatisfy { if case .wheel(_, false, _, _) = $0 { true } else { false } }, "readings keep the line input")
    }

    /// I6: a recording copied out of `diagnostics/` (say to Downloads), with no `PORTICO_HOME` and
    /// no checkout `.portico-home`, fails with one line, writing nothing anywhere.
    private func copiedRecording() throws -> (copy: URL, downloads: URL) {
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 6).map { (0, .shape($0)) }
        lines += [(100, .wheel(deltaY: -40, precise: true, phase: 0, momentum: 0))]
        let made = try write(lines, name: "9-2026-11-11T08-00-00.000Z.jsonl")
        let downloads = tmp.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let copy = downloads.appendingPathComponent(made.lastPathComponent)
        try FileManager.default.copyItem(at: made, to: copy)
        return (copy, downloads)
    }

    func testACopiedRecordingWithNoHomeFailsWithOneLine() throws {
        let (copy, downloads) = try copiedRecording()
        let checkout = tmp.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: checkout.appendingPathComponent("bin/portico-gateway").path, contents: nil)
        XCTAssertThrowsError(try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": copy.path], checkout: checkout)) { error in
            XCTAssertEqual("\(error)", "set PORTICO_HOME to the app's home")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [copy.lastPathComponent], "nothing beside the copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("evaluations").path))
    }

    /// I6: with `PORTICO_HOME`, or the checkout's `.portico-home`, the evaluation goes under that
    /// home's existing `diagnostics/` (an `evaluations/` left too open is tightened); a home with no
    /// `diagnostics/` gets none made.
    func testACopiedRecordingsEvaluationGoesUnderTheNamedHomesDiagnostics() throws {
        let (copy, downloads) = try copiedRecording()
        let home = tmp.appendingPathComponent("home", isDirectory: true)
        let evaluations = home.appendingPathComponent("diagnostics/evaluations", isDirectory: true)
        try FileManager.default.createDirectory(at: evaluations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let (_, file) = try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": copy.path, "PORTICO_HOME": home.path], checkout: nil)
        XCTAssertEqual(file.deletingLastPathComponent().path, evaluations.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: evaluations.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [copy.lastPathComponent], "nothing beside the copy")

        // The checkout's `.portico-home` (as the gateway reads it), when PORTICO_HOME is not set.
        let other = tmp.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("diagnostics"), withIntermediateDirectories: true)
        let checkout = tmp.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: checkout.appendingPathComponent("bin/portico-gateway").path, contents: nil)
        try (other.path + "\n").write(to: checkout.appendingPathComponent(".portico-home"), atomically: true, encoding: .utf8)
        let (_, second) = try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": copy.path], checkout: checkout)
        XCTAssertEqual(second.deletingLastPathComponent().path, other.appendingPathComponent("diagnostics/evaluations").path)

        // A home with no diagnostics/: nothing made, one line.
        let bare = tmp.appendingPathComponent("bare-home", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ReplayRunner.replayFromEnvironment(["PORTICO_REPLAY": copy.path, "PORTICO_HOME": bare.path], checkout: nil)) { error in
            XCTAssertEqual("\(error)", "set PORTICO_HOME to the app's home")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.appendingPathComponent("diagnostics").path), "no diagnostics/ made")
    }

    /// I6: the normal case writes beside the recording, under its own `diagnostics/`, whatever the
    /// environment says.
    func testARecordingUnderDiagnosticsIsEvaluatedThere() throws {
        var lines: [(Int, RecordingEvent)] = [(0, open())]
        lines += conversation(turns: 6).map { (0, .shape($0)) }
        let recording = try write(lines, name: "9-2026-11-11T08-30-00.000Z.jsonl")
        let elsewhere = tmp.appendingPathComponent("elsewhere/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let (_, file) = try ReplayRunner.replayFromEnvironment(
            ["PORTICO_REPLAY": recording.path, "PORTICO_HOME": elsewhere.deletingLastPathComponent().path], checkout: nil)
        XCTAssertEqual(file.path, tmp.appendingPathComponent("crafted/diagnostics/evaluations/9-2026-11-11T08-30-00.000Z.txt").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("evaluations").path))
    }

    /// I7: what the field entry point prints names the evaluation's file only, never its folder.
    func testTheFieldOutputNamesTheFileOnly() {
        let e = Evaluation(appVersion: "1", macOS: "2", phasesFire: false, phasesMove: false, recording: "a.jsonl", started: "s",
                           lengthMs: 0, segments: 1, entriesByKind: [:], heightHistogram: [:], violations: [], window: [])
        let file = URL(fileURLWithPath: "/Users/someone/Library/portico/diagnostics/evaluations/9-x.txt")
        let out = ReplayRunner.fieldOutput(e, file: file)
        XCTAssertTrue(out.hasPrefix("PORTICO-EVALUATION 9-x.txt\n"), out)
        XCTAssertFalse(out.contains("/"), out)
        XCTAssertFalse(out.contains("someone"))
    }

    /// The field entry point: `PORTICO_REPLAY=<recording> swift test -c release
    /// --filter DiagnosticsReplayTests/testReplayRecordingFromEnvironment`. Red when the replay breaks an invariant.
    func testReplayRecordingFromEnvironment() throws {
        let (evaluation, file) = try ReplayRunner.replayFromEnvironment(ProcessInfo.processInfo.environment)
        // The render carries the steps, keys and skipped lines (review I4) with everything else.
        // I7: the file's name only; the home's path stays on this Mac.
        print(ReplayRunner.fieldOutput(evaluation, file: file))
        XCTAssertEqual(evaluation.violations, [], "the replay reproduced a failure; evaluation \(file.lastPathComponent)")
    }
}
