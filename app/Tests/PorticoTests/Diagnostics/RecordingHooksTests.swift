import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.26.4 (D4, D5): the recorder hooked into the live conversation view and
/// the person's input. Hosted as the scroll trace and round-trip tests host it.
@MainActor
final class RecordingHooksTests: XCTestCase {
    private var tmp: URL!
    private var savedHome: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portico-hooks-\(UUID().uuidString)")
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
        Diagnostics.home = savedHome
        Diagnostics.refresh()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func switchOn() throws {
        try FileManager.default.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Diagnostics.switchFile.path, contents: nil)
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)
    }

    private func model(
        turns: Int, replyRepeat: Int = 30, question: (Int) -> UserText? = { _ in nil }, extra: [ServerMessage] = []
    ) throws -> AppModel {
        let suite = "portico-hooks-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = 3
        var events: [ServerMessage] = []
        if turns > 0 {
            for turn in 1...turns {
                events.append(.userText(question(turn)
                    ?? UserText(chat: 3, turn: turn, text: "Question \(turn) from Jordan about the Acme plan.")))
                events.append(.textDelta(TextDelta(chat: 3, turn: turn, text: "Answer \(turn). " + String(repeating: "Priya replied at length. ", count: replyRepeat))))
                events.append(.turnFinished(TurnFinished(chat: 3, turn: turn, outcome: .done)))
            }
        }
        events += extra
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

    private struct Hosted {
        let window: NSWindow
        let host: NSView
    }

    private func host(_ model: AppModel) -> Hosted {
        _ = NSApplication.shared
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(1.0)
        return Hosted(window: window, host: host)
    }

    private func spin(_ seconds: Double = 0.4) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1000 { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }

    /// `ConversationRoundTripTests.phaselessWheel`: a plain wheel, as the app dispatches it.
    private static func phaselessWheel(_ scroll: NSScrollView, window: NSWindow, pixels: Int32) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: top - screen.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        NSApp.sendEvent(event)
        scroll.scrollWheel(with: event)
    }

    private func recording(chat: Int = 3) throws -> [(t: Int, event: RecordingEvent)] {
        let url = try XCTUnwrap(Diagnostics.recorders[chat]?.url, "a recorder for chat \(chat)")
        Diagnostics.closeAll()
        return try Recorder.read(url)
    }

    private static func shapes(_ events: [(t: Int, event: RecordingEvent)]) -> [EntryShape] {
        events.compactMap { if case .shape(let s) = $0.event { s } else { nil } }
    }

    /// The events right after `open` that are shapes, in order.
    private static func openShapes(_ events: [(t: Int, event: RecordingEvent)]) -> [EntryShape] {
        Array(events.dropFirst().prefix { if case .shape = $0.event { true } else { false } })
            .compactMap { if case .shape(let s) = $0.event { s } else { nil } }
    }

    // MARK: - Tests

    func testAHostedSessionWritesOpenShapesGeometryInputsAndDeltas() throws {
        try switchOn()
        let model = try model(turns: 30)
        let hosted = host(model)
        defer { hosted.window.close() }
        let scroll = try XCTUnwrap(Self.transcriptScroll(in: hosted.host))
        for _ in 0..<3 {
            try Self.phaselessWheel(scroll, window: hosted.window, pixels: 40)
            spin(0.1)
        }
        let reply = try XCTUnwrap(Self.firstTextView(in: try XCTUnwrap(scroll.documentView)))
        XCTAssertTrue(hosted.window.makeFirstResponder(reply))
        let pageUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: "\u{F72C}",
            charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116))
        NSApp.sendEvent(pageUp)
        hosted.window.sendEvent(pageUp)
        spin(0.3)
        // Ruling 8: the arrows and Space are the transcript's scroll keys too.
        for (code, character) in [(UInt16(126), "\u{F700}"), (UInt16(49), " ")] {
            // The page scroll may have let the first reply's text view go: focus one on screen.
            let focus = try XCTUnwrap(Self.firstTextView(in: try XCTUnwrap(scroll.documentView)))
            XCTAssertTrue(hosted.window.makeFirstResponder(focus))
            let key = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            NSApp.sendEvent(key)
            hosted.window.sendEvent(key)
            spin(0.2)
        }
        model.apply(.textDelta(TextDelta(chat: 3, turn: 31, text: String(repeating: "x", count: 120))))
        spin(0.3)
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 31, outcome: .done)))
        spin(0.3)

        let events = try recording()
        guard case let .open(chat, _, _, window, column, _, _, _, _)? = events.first?.event else {
            return XCTFail("first event is open: \(String(describing: events.first))")
        }
        XCTAssertEqual(chat, 3)
        XCTAssertEqual(window, [800, 600])
        XCTAssertGreaterThan(column, 0)
        let opened = Self.openShapes(events)
        XCTAssertEqual(opened.count, 60, "one shape per drawn entry")
        XCTAssertEqual(opened.filter { $0.kind == .person }.count, 30)
        XCTAssertEqual(opened.filter { $0.kind == .reply }.count, 30)
        let wheels = events.compactMap { if case .wheel(let dy, _, _, _) = $0.event { dy } else { nil } }
        XCTAssertEqual(wheels, [40, 40, 40], "three wheels of 40")
        XCTAssertTrue(events.contains { $0.event == .key(.pageUp) }, "Page Up")
        XCTAssertTrue(events.contains { $0.event == .key(.up) }, "Up arrow")
        XCTAssertTrue(events.contains { $0.event == .key(.space) }, "Space")
        XCTAssertTrue(events.contains { $0.event == .delta(turn: 31, chars: 120) }, "the reply's growth")
        XCTAssertTrue(events.contains { $0.event == .turnFinished(turn: 31) }, "the turn's end")
        XCTAssertTrue(events.contains { if case .phase = $0.event { true } else { false } }, "a scroll phase")
        XCTAssertTrue(Self.shapes(events).dropFirst(60).contains { $0.kind == .reply }, "the new reply's shape")
        XCTAssertEqual(events.map(\.t), events.map(\.t).sorted(), "time never goes back")
    }

    func testSwitchOnMidSessionRecordsOpenChats() throws {
        let model = try model(turns: 30)
        let hosted = host(model)
        defer { hosted.window.close() }
        XCTAssertNil(Diagnostics.recorders[3], "off: nothing recorded")
        try switchOn()
        spin(0.5)
        let events = try recording()
        guard case .open(chat: 3, _, _, let window, _, _, _, _, _)? = events.first?.event else {
            return XCTFail("first event is open: \(String(describing: events.first))")
        }
        XCTAssertEqual(window, [800, 600])
        XCTAssertEqual(Self.openShapes(events).count, 60)
    }

    func testEmptyChatRecordsOpenWithZeroEntries() throws {
        try switchOn()
        let model = try model(turns: 0)
        let hosted = host(model)
        defer { hosted.window.close() }
        let events = try recording()
        guard case .open(chat: 3, _, _, _, _, _, _, _, _)? = events.first?.event else {
            return XCTFail("first event is open: \(String(describing: events.first))")
        }
        XCTAssertTrue(Self.shapes(events).isEmpty, "no entries")
    }

    private func png(named name: String, width: Int, height: Int) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    func testImageLoadedIsRecordedWhenAThumbnailSwaps() throws {
        let path = try png(named: "photo.png", width: 200, height: 100)
        try switchOn()
        let model = try model(turns: 3, question: { turn in
            turn == 3 ? UserText(chat: 3, turn: 3, text: "Look", attachments: [path]) : nil
        })
        let hosted = host(model)
        defer { hosted.window.close() }
        spin(0.5)
        let id = try XCTUnwrap(model.transcripts[3]?.first { if case .userText(let u) = $0 { u.turn == 3 } else { false } }?.id)
        let events = try recording()
        let shape = try XCTUnwrap(Self.shapes(events).first { $0.id == id })
        XCTAssertEqual(shape.images, [[200, 100]], "the image's pixel size from its header")
        // The bubble's thumbnail frame clamps each side on its own (measured hosted:
        // 200 × 100 lays out 160 × 100, 100 × 300 lays out 100 × 120): height min(100, 120).
        XCTAssertTrue(events.contains { $0.event == .imageLoaded(id: id, index: 0, height: 100) }, "\(events.map(\.event))")
    }

    func testEverythingWrittenIsDataless() throws {
        let path = try png(named: "zebra-photo.png", width: 64, height: 48)
        try switchOn()
        let model = try model(
            turns: 4,
            question: { turn in UserText(chat: 3, turn: turn, text: "ZEBRA-TEXT \(turn)", attachments: turn == 4 ? [path] : nil) },
            extra: [
                .artifactCreated(ArtifactCreated(chat: 3, artifact: Artifact(
                    id: "art-1", kind: .file, location: "/tmp/demo/zebra-location.html", media: .html,
                    title: "ZEBRA-TITLE.html", source: .tool, open: true))),
                // A tool row whose summary and input name a file (C1: a tool row and a docked card).
                .toolStarted(ToolStarted(chat: 3, turn: 4, toolUseId: "tu-1", tool: "Read", summary: "zebra-notes.md",
                                         input: ["file_path": .string("/tmp/zebra-dir/zebra-notes.md")])),
                .toolFinished(ToolFinished(chat: 3, turn: 4, toolUseId: "tu-1", ok: true, summary: "ZEBRA read")),
            ])
        let hosted = host(model)
        defer { hosted.window.close() }
        model.setViewer(visible: false, for: 3)
        spin(0.3)
        model.setViewer(visible: true, for: 3)
        spin(0.3)
        // C1: a local file, a link and a space shown in the viewer; their ids hold a path, a URL and a file stem.
        model.openArtifact(file: "/tmp/zebra-dir/zebra.md", in: 3)
        spin(0.3)
        XCTAssertTrue(model.openLink("https://zebra.example/x", chat: 3))
        spin(0.3)
        model.apply(.spacesList(SpacesList(spaces: [SpaceInfo(
            id: "zebra-space", title: "ZEBRA space", icon: "doc.text", order: nil,
            location: "/tmp/zebra-dir/zebra-space.md", media: "markdown", updated: "2026-11-01T09:00:00Z")])))
        model.setOpenSpace("zebra-space")
        spin(0.3)
        model.setOpenSpace(nil)
        spin(0.3)
        // A docked card (a question) with a title.
        model.apply(.cardAsk(CardAsk(
            chat: 3, id: "card-7", kind: .question, title: "ZEBRA-CARD",
            permission: nil, questions: [Question(question: "ZEBRA?", header: "ZEBRA", options: [], multiSelect: false)], form: nil)))
        spin(0.3)
        model.apply(.textDelta(TextDelta(chat: 3, turn: 5, text: "ZEBRA-TEXT reply")))
        spin(0.3)
        XCTAssertNotNil(model.dockedCard(for: 3), "the card docked")
        let url = try XCTUnwrap(Diagnostics.recorders[3]?.url)
        let events = try recording()
        XCTAssertTrue(events.contains { if case .viewer = $0.event { true } else { false } }, "the viewer switch is recorded")
        XCTAssertTrue(events.contains { if case .card(_, true) = $0.event { true } else { false } }, "the docked card is recorded")
        XCTAssertTrue(events.contains { if case .shape(let s) = $0.event { [.tool, .toolRun].contains(s.kind) } else { false } }, "the tool row is recorded")

        // Every string value in the recording is an id, the shown artifact's id (`art-…`
        // or an opaque per-run token), or a version.
        let items = model.transcripts[3] ?? []
        let ids = Set(items.map(\.id)).union(TranscriptEntry.entries(items).map(\.id)).union(["brief", "divider", "art-1", "card-7"])
        let token = try NSRegularExpression(pattern: "^(art-[A-Za-z0-9-]+|local-[0-9]+|link-[0-9]+|space-[0-9]+)$")
        func isToken(_ s: String) -> Bool { token.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        var strings: [String] = []
        func walk(_ value: Any, key: String?) {
            if let dict = value as? [String: Any] { for (k, v) in dict { walk(v, key: k) } }
            else if let array = value as? [Any] { for v in array { walk(v, key: key) } }
            else if let string = value as? String, key != "kind" { strings.append("\(key ?? "-")=\(string)") }
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            walk(try JSONSerialization.jsonObject(with: Data(line.utf8)), key: nil)
        }
        var shown: [String] = []
        for entry in strings {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let (key, value) = (parts[0], parts.count > 1 ? parts[1] : "")
            switch key {
            case "appVersion", "macOS": continue
            case "value": XCTAssertTrue(ScrollKey(rawValue: value) != nil || ScrollPhaseName(rawValue: value) != nil, entry)
            case "shown":
                shown.append(value)
                XCTAssertTrue(isToken(value), "not an artifact token: \(entry)")
            default: XCTAssertTrue(ids.contains(value), "not an id: \(entry)")
            }
        }
        for kind in ["local-", "link-", "space-"] {
            XCTAssertTrue(shown.contains { $0.hasPrefix(kind) }, "a \(kind) token among \(shown)")
        }

        // Nothing planted appears in any file under diagnostics/.
        let planted = ["ZEBRA", "zebra", "Jordan", "Priya", "/tmp", "https"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Diagnostics.directory, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        XCTAssertTrue(files.contains { $0.lastPathComponent == "trace.log" }, "the trace was written too")
        XCTAssertTrue(files.contains { $0.pathExtension == "jsonl" })
        for file in files {
            let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for word in planted {
                XCTAssertFalse(body.contains(word), "\(word) in \(file.lastPathComponent)")
                XCTAssertFalse(file.lastPathComponent.contains(word))
            }
        }
        // The trace's viewer line keeps its shape (D13), with tokens for the ids.
        let trace = (try? String(contentsOf: Diagnostics.tracePath, encoding: .utf8)) ?? ""
        let viewerLines = trace.split(separator: "\n").filter { $0.contains("viewer chat=3 shown from=") }
        XCTAssertFalse(viewerLines.isEmpty, "the trace's viewer lines")
        for line in viewerLines {
            let fields = line.components(separatedBy: " shown from=")[1].components(separatedBy: " to=")
            XCTAssertEqual(fields.count, 2, String(line))
            for f in fields { XCTAssertTrue(f == "none" || isToken(f), "\(f) in \(line)") }
        }
    }

    /// Off then on inside one poll deletes `recordings/` under the open recorders;
    /// the next refresh closes them and each open conversation starts a new file.
    func testOffThenOnWithinOnePollStartsFreshRecordings() throws {
        try switchOn()
        let model = try model(turns: 5)
        let hosted = host(model)
        defer { hosted.window.close() }
        let first = try XCTUnwrap(Diagnostics.recorders[3])
        try FileManager.default.removeItem(at: Diagnostics.directory)
        try switchOn()
        spin(0.5)
        let second = try XCTUnwrap(Diagnostics.recorders[3], "a recorder again")
        XCTAssertFalse(first === second, "a new recorder")
        let events = try recording()
        guard case .open(chat: 3, _, _, _, _, _, _, _, _)? = events.first?.event else {
            return XCTFail("the new file starts with open: \(String(describing: events.first))")
        }
        XCTAssertEqual(Self.openShapes(events).count, 10)
    }

    /// Review I1: a streaming delta costs the recording the same however long the
    /// conversation is. 200 turns of about 5000 characters each, 40 deltas.
    func testStreamingIntoALongConversationStaysUnderAMillisecondPerChange() throws {
        try switchOn()
        let model = try model(turns: 200, replyRepeat: 200)
        let hosted = host(model)
        defer { hosted.window.close() }
        let wasEnabled = ConversationProbe.enabled
        ConversationProbe.enabled = true
        defer { ConversationProbe.enabled = wasEnabled }
        ConversationProbe.recordingChangeNanos = []
        for _ in 0..<40 {
            model.apply(.textDelta(TextDelta(chat: 3, turn: 201, text: String(repeating: "y", count: 30))))
            spin(0.03)
        }
        let times = ConversationProbe.recordingChangeNanos.map { Double($0) / 1_000_000 }
        ConversationProbe.recordingChangeNanos = []
        model.apply(.turnFinished(TurnFinished(chat: 3, turn: 201, outcome: .done)))
        spin(0.3)
        let average = times.reduce(0, +) / Double(max(times.count, 1))
        print(String(format: "RECORDING per change: n=%d average=%.3f ms max=%.3f ms", times.count, average, times.max() ?? 0))
        XCTAssertGreaterThanOrEqual(times.count, 20, "the follow key changed with the deltas")
        XCTAssertLessThan(average, 1.0)

        let id = try XCTUnwrap(model.transcripts[3]?.last { if case .assistantText = $0 { true } else { false } }?.id)
        let events = try recording()
        let deltas = events.compactMap { if case .delta(201, let chars) = $0.event { chars } else { nil } }
        XCTAssertEqual(deltas.reduce(0, +), 1200, "every character's growth, at its own time")
        let shapes = Self.shapes(events).filter { $0.id == id }
        XCTAssertLessThan(shapes.count, 40, "the streaming shape is throttled")
        XCTAssertEqual(shapes.last?.paragraphs, [1200], "and right once the turn ends")
    }
}
