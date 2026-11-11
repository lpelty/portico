import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// v0.26.4 (D8, D9, D10): turns a field recording into a reproduction on the
/// machine where it was made. The last segment of the recording (from its last
/// `open`) is rebuilt as a synthetic conversation from the recorded shapes, the
/// real `ConversationView` is hosted at the recorded size, the recorded inputs
/// are fed in order, each followed by settling and a `Reading`, and the readings
/// go through `Invariants`. The evaluation holds counts and recorded ids only.
///
/// Applied from the recording: `window` (height; the width is the column's),
/// `column` (the hosted width, stepped to the recorded value), `wheel` (a
/// phaseless CGEvent wheel, pixel or line units as recorded, the delta's sign
/// unchanged), `key` (a key-down with focus in the transcript), `jump` (the
/// model's marker jump to the mapped message), `delta` (the last reply grows by
/// that many filler characters, or a new reply starts in the last turn), a new
/// entry's `shape` (appended as the synthetic builder makes it; a reply shape
/// right after a delta that started a reply names that reply), `turnFinished`
/// (the last turn ends). `phase` sets the phase of the readings that follow.
/// Skipped, and counted by event kind in `lastNotes` and the evaluation's `skipped:` line: `removed`, `imageLoaded` (images load
/// through the real thumbnail path), `toolRow` (its run's shape covers it),
/// `card`, `viewer`, `sidebar`, `textScale`, `capped`, a changed shape of a
/// known entry, a new entry of a kind the builder skips, and a jump to an
/// entry it has no stand-in for.
@MainActor
enum ReplayRunner {
    struct Hosted {
        let window: NSWindow
        let host: NSView
        let scroll: NSScrollView
    }

    enum Failure: Error, CustomStringConvertible {
        case noOpen
        case noScrollView
        var description: String {
            switch self {
            case .noOpen: "the recording has no open event"
            case .noScrollView: "no transcript scroll view in the hosted conversation"
            }
        }
    }

    /// Called with each step's number while the replay runs (tests).
    static var onStep: ((Int) -> Void)?
    /// The last run's readings, notes on what it skipped (kind: count) and hosted width (tests, the report).
    static private(set) var lastReadings: [Reading] = []
    static private(set) var lastNotes: [String] = []
    static private(set) var lastHostedWidth: CGFloat?

    static let environmentKey = "PORTICO_REPLAY"
    static let unmapped = "unmapped"
    private static let skippedKinds: Set<EntryShape.Kind> = [.card, .turnMarker, .compacted, .notice, .agents, .signin, .brief, .divider]

    // MARK: - hosting and input

    private struct Selected: View {
        @EnvironmentObject var model: AppModel
        var body: some View {
            if let chat = model.selected { ConversationView(chat: chat).id(chat) }
        }
    }

    /// The conversation the model has selected, hosted as the round-trip tests host it.
    static func host(_ model: AppModel, defaults: UserDefaults, size: NSSize) throws -> Hosted {
        _ = NSApplication.shared
        let settings = Settings(defaults: defaults)
        let host = NSHostingView(rootView:
            Selected()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ReadAloud(settings: settings))
                .environmentObject(Dictation(settings: settings)))
        let frame = NSRect(origin: .zero, size: size)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        spin(1.0)
        guard let scroll = transcriptScroll(in: host) else {
            window.close()
            throw Failure.noScrollView
        }
        return Hosted(window: window, host: host, scroll: scroll)
    }

    static func spin(_ seconds: Double = 0.4) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The transcript: the tallest scroll view on screen (the composer's editor scrolls too).
    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        var all: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { all.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return all.max { $0.frame.height < $1.frame.height }
    }

    /// A wheel as the app dispatches it, without gesture phases (ruling 3): the
    /// recorded delta unchanged (positive toward the top, ruling 10), in lines when
    /// it was not precise. Pixel deltas are whole points in a CGEvent; the caller
    /// carries the remainder (`delta` is the whole amount sent, `exact` the recorded
    /// line delta). A line wheel also carries its exact fractional lines in the
    /// fixed-point field, which AppKit reads as `scrollingDeltaY` and scrolls by
    /// (verified hosted: 0.4 lines moved 4 pt, 1.5 moved 15 pt, with a whole field of 0).
    @discardableResult
    static func wheel(_ hosted: Hosted, deltaY: Double, precise: Bool, exact: Double? = nil) -> Bool {
        let amount = Int32(clamping: Int(deltaY.rounded()))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
                               wheel1: amount, wheel2: 0, wheel3: 0) else { return false }
        if !precise { cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: exact ?? deltaY) }
        let scroll = hosted.scroll
        let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = hosted.window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: top - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return false }
        // Two calls, one delivery: `NSApp.sendEvent` runs the app's local monitor (the
        // person-input mark); the window is never shown or key, so it routes the event no
        // further, and only `scrollWheel(with:)` scrolls.
        NSApp.sendEvent(event)
        scroll.scrollWheel(with: event)
        return true
    }

    private static let keyCodes: [ScrollKey: (code: UInt16, character: String)] = [
        .pageUp: (116, "\u{F72C}"), .pageDown: (121, "\u{F72D}"), .home: (115, "\u{F729}"), .end: (119, "\u{F72B}"),
        .up: (126, "\u{F700}"), .down: (125, "\u{F701}"), .space: (49, " "),
    ]

    /// A scroll key with the focus in the transcript (a reply's text view on screen).
    static func key(_ hosted: Hosted, _ key: ScrollKey) {
        guard let (code, character) = keyCodes[key] else { return }
        if let document = hosted.scroll.documentView, let focus = visibleTextView(in: document, visible: hosted.scroll.contentView.bounds) {
            hosted.window.makeFirstResponder(focus)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: hosted.window.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return }
        // Two calls, one delivery: `NSApp.sendEvent` runs the local monitor only (the window
        // is never shown or key, so NSApp does not route the key on); `window.sendEvent`
        // delivers it to the first responder.
        NSApp.sendEvent(event)
        hosted.window.sendEvent(event)
    }

    private static func visibleTextView(in document: NSView, visible: CGRect) -> NSTextView? {
        var found: NSTextView?
        func walk(_ v: NSView) {
            if found != nil { return }
            if let text = v as? NSTextView, !text.isHiddenOrHasHiddenAncestor,
               text.convert(text.bounds, to: document).intersects(visible) { found = text; return }
            v.subviews.forEach(walk)
        }
        walk(document)
        return found
    }

    /// The hosted width stepped to `width` over a few frames (the round-trip tests' easing).
    private static func resize(_ hosted: Hosted, width: CGFloat? = nil, height: CGFloat? = nil) {
        let from = hosted.host.frame.size
        let to = NSSize(width: width ?? from.width, height: height ?? from.height)
        for step in 1...4 {
            let f = CGFloat(step) / 4
            let size = NSSize(width: (from.width + (to.width - from.width) * f).rounded(),
                              height: (from.height + (to.height - from.height) * f).rounded())
            hosted.host.setFrameSize(size)
            hosted.window.setContentSize(size)
            spin(0.03)
        }
    }

    // MARK: - readings

    /// Spins 50 ms, then samples the document's height every 10 ms for 200 ms.
    private static func settle(_ hosted: Hosted) -> [Double] {
        spin(0.05)
        var heights: [Double] = []
        for _ in 0..<20 {
            spin(0.01)
            heights.append(Double(hosted.scroll.documentView?.frame.height ?? 0))
        }
        return heights
    }

    private struct Names {
        /// Synthetic entry id -> recorded id.
        var recorded: [String: String] = [:]
        /// Recorded id -> synthetic entry id.
        var synthetic: [String: String] = [:]
        /// Recorded id -> recorded kind.
        var kinds: [String: EntryShape.Kind] = [:]

        mutating func pair(recorded id: String, synthetic: String, kind: EntryShape.Kind) {
            recorded[synthetic] = id
            self.synthetic[id] = synthetic
            kinds[id] = kind
        }
    }

    private static func reading(step: Int, input: RecordingEvent?, hosted: Hosted, chat: Int, phase: ScrollPhaseName,
                                settled: [Double], names: Names, hasRows: Bool) -> Reading {
        let clip = hosted.scroll.contentView.bounds
        let frames = ConversationProbe.rows[chat]?.frames ?? [:]
        let rows = frames.filter { $0.value.maxY > 0 && $0.value.minY < clip.height && $0.value.height > 0 }
            .sorted { $0.value.minY < $1.value.minY }
            .map { id, frame -> RowInView in
                let recorded = names.recorded[id]
                // `unmapped` (not expected: every drawn synthetic row comes from a recorded shape)
                // keeps the row for the rows-in-view check; it never enters the histogram.
                return RowInView(id: recorded ?? unmapped, kind: recorded.flatMap { names.kinds[$0] } ?? .notice,
                                 height: Double(frame.height), minY: Double(clip.minY + frame.minY))
            }
        return Reading(step: step, input: input, offset: Double(clip.origin.y),
                       documentHeight: Double(hosted.scroll.documentView?.frame.height ?? 0), clip: clip,
                       rowsInView: rows, phase: phase, settledReadings: settled, hasRows: hasRows)
    }

    // MARK: - the pure half

    /// Violations, the window (the first failing step and its neighbours, or the
    /// last three) and the row-height histogram (each row's last height, 50 pt
    /// buckets). The header is left blank for `run` to fill.
    static func check(readings: [Reading]) -> Evaluation {
        let violations = Invariants.check(readings)
        // Ruling 13: a key step moved the view when the offset changed by a tenth of the clip
        // (Page Up/Down, Home, End, Space) or a point (the arrows); one that did not is noted.
        var noted = readings
        var keysStepped = 0, keysMoved = 0
        for i in noted.indices {
            guard case .key(let key) = noted[i].input else { continue }
            keysStepped += 1
            let moved = i > 0 ? abs(noted[i].offset - noted[i - 1].offset) : 0
            let bar = key == .up || key == .down ? 1 : 0.1 * Double(noted[i].clip.height)
            if moved >= bar { keysMoved += 1 } else { noted[i].note = "key-not-moved" }
        }
        let window: [Reading]
        if let failing = violations.first?.step {
            window = noted.filter { abs($0.step - failing) <= 1 }
        } else {
            window = Array(noted.suffix(3))
        }
        var heights: [String: Double] = [:]
        // A row with no recorded stand-in stays out of the histogram.
        for r in readings { for row in r.rowsInView where row.id != unmapped { heights[row.id] = row.height } }
        var histogram: [Int: Int] = [:]
        for h in heights.values { histogram[Int(max(h, 0) / 50) * 50, default: 0] += 1 }
        return Evaluation(appVersion: "", macOS: "", phasesFire: false, phasesMove: false, recording: "readings", started: "",
                          lengthMs: 0, segments: 0, entriesByKind: [:], heightHistogram: histogram,
                          violations: violations, window: window, steps: readings.count,
                          keysStepped: keysStepped, keysMoved: keysMoved)
    }

    // MARK: - the replay

    static func run(recording: URL, images: URL) throws -> Evaluation {
        let all = try Recorder.read(recording)
        let opens = all.indices.filter { if case .open = all[$0].event { true } else { false } }
        guard let start = opens.last,
              case let .open(chat, appVersion, macOS, window, column, _, _, _, _) = all[start].event
        else { throw Failure.noOpen }
        let segment = Array(all[start...])
        var cursor = 1
        var shapes: [EntryShape] = []
        while cursor < segment.count, case .shape(let s) = segment[cursor].event {
            shapes.append(s)
            cursor += 1
        }

        // The runner never records itself: an empty home, no switch file, for the run.
        let savedHome = Diagnostics.home
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("portico-replay-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        Diagnostics.closeAll()
        Diagnostics.home = home
        Diagnostics.refresh()
        let wasProbing = ConversationProbe.enabled
        ConversationProbe.enabled = true
        var cleanups: [() -> Void] = []
        defer {
            cleanups.reversed().forEach { $0() }
            ConversationProbe.enabled = wasProbing
            ConversationProbe.rows[chat] = nil
            ConversationProbe.phaseNames[chat] = nil
            Diagnostics.closeAll()
            Diagnostics.home = savedHome
            Diagnostics.refresh()
            try? FileManager.default.removeItem(at: home)
        }
        func defaults() throws -> UserDefaults {
            let suite = "portico-replay-\(UUID().uuidString)"
            guard let d = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
            cleanups.append { d.removePersistentDomain(forName: suite) }
            return d
        }

        let width = CGFloat(column > 0 ? column : (window.first ?? 800))
        let height = CGFloat(window.count > 1 ? window[1] : 600)
        let size = NSSize(width: width, height: height)

        // The phase probe (D12) on its own model: it scrolls, and the replay starts where the recording did.
        let probeModel = try SyntheticConversation.model(chat: chat, shapes: shapes, images: images, defaults: try defaults())
        let probeHost = try host(probeModel, defaults: try defaults(), size: size)
        let probe = PhaseProbe.run(scroll: probeHost.scroll, chat: chat)
        probeHost.window.close()
        ConversationProbe.phaseNames[chat] = nil
        ConversationProbe.rows[chat] = nil

        let built = try SyntheticConversation.events(chat: chat, shapes: shapes, images: images)
        var names = Names()
        for shape in shapes {
            if let synthetic = built.ids[shape.id] ?? nil { names.pair(recorded: shape.id, synthetic: synthetic, kind: shape.kind) }
        }
        var entries: [EntryShape.Kind: Int] = [:]
        for shape in shapes { entries[shape.kind, default: 0] += 1 }
        let model = try SyntheticConversation.model(chat: chat, shapes: shapes, images: images, defaults: try defaults())
        let hosted = try host(model, defaults: try defaults(), size: size)
        cleanups.append { hosted.window.close() }

        // The last turn and the kind of the last entry drawn, for deltas and turn ends.
        let keptIndex = shapes.lastIndex { !skippedKinds.contains($0.kind) }
        var lastTurn = (keptIndex ?? -1) + 1
        var lastKind = keptIndex.map { shapes[$0].kind }
        var nextTurn = shapes.count + 1
        var pendingReply: String?
        var replyTurn = lastKind == .reply ? Optional(lastTurn) : nil
        /// The recorded turn of the last delta: a delta of the same turn grows the same reply.
        var deltaTurn: Int?
        let rest = Array(segment[cursor...])
        /// Whether the delta at `index` starts a reply: a new reply's shape follows before a delta of another turn.
        func startsReply(at index: Int) -> Bool {
            guard case .delta(let turn, _) = rest[index].event else { return false }
            for (_, later) in rest[(index + 1)...] {
                switch later {
                case .shape(let s) where s.kind == .reply && !known.contains(s.id): return true
                case .delta(let t, _) where t != turn: return false
                default: continue
                }
            }
            return false
        }
        var known = Set(shapes.map(\.id))
        var notes: [String: Int] = [:]
        var phase: ScrollPhaseName = .idle
        var residual = 0.0
        var lineResidual = 0.0
        var readings: [Reading] = []
        var appended = 0

        func entriesNow() -> [TranscriptEntry] { TranscriptEntry.entries(model.transcripts[chat] ?? []) }
        func take(_ input: RecordingEvent?) {
            let step = readings.count
            XCTAssertTrue(Diagnostics.recorders.isEmpty, "the replay records nothing")
            let settled = settle(hosted)
            readings.append(reading(step: step, input: input, hosted: hosted, chat: chat, phase: phase,
                                    settled: settled, names: names, hasRows: !entriesNow().isEmpty))
            onStep?(step)
        }

        take(nil)
        for (index, (_, event)) in rest.enumerated() {
            switch event {
            case .phase(let p):
                phase = p
            case .open:
                break  // not in the last segment
            case .window(_, let h):
                resize(hosted, height: CGFloat(h))
                take(event)
            case .column(let w):
                resize(hosted, width: CGFloat(w))
                take(event)
            case let .wheel(deltaY, precise, _, _):
                // Ruling 12: the remainder of a whole-unit CGEvent field carries to the next wheel, for pixels and lines alike.
                var delta = deltaY
                if precise {
                    delta += residual
                    residual = delta - delta.rounded()
                } else {
                    delta += lineResidual
                    lineResidual = delta - delta.rounded()
                }
                wheel(hosted, deltaY: delta, precise: precise, exact: precise ? nil : deltaY)
                take(event)
            case .key(let k):
                key(hosted, k)
                take(event)
            case .jump(let id):
                guard let synthetic = names.synthetic[id] else { notes["jump", default: 0] += 1; continue }
                model.jumpToMessage(synthetic, chat: chat)
                take(event)
            case let .delta(recordedTurn, chars):
                let text = SyntheticConversation.text(matching: EntryShape(id: "delta-\(readings.count)", kind: .reply, paragraphs: [chars]))
                let sameStream = recordedTurn == deltaTurn
                deltaTurn = recordedTurn
                if let turn = replyTurn, sameStream || (lastKind == .reply && !startsReply(at: index)) {
                    model.apply(.textDelta(TextDelta(chat: chat, turn: turn, text: " " + text)))
                } else {
                    // A new reply: in the turn of the question just appended, else a turn of its own.
                    let turn: Int
                    if lastKind == .person, lastTurn > 0 { turn = lastTurn } else { turn = nextTurn; nextTurn += 1 }
                    model.apply(.textDelta(TextDelta(chat: chat, turn: turn, text: text)))
                    pendingReply = entriesNow().last?.id
                    lastTurn = turn
                    replyTurn = turn
                    lastKind = .reply
                }
                take(event)
            case .shape(let s):
                if known.contains(s.id) {
                    notes["shape", default: 0] += 1  // a known entry re-shaped: deltas already grew it
                    continue
                }
                known.insert(s.id)
                entries[s.kind, default: 0] += 1
                if s.kind == .reply, let synthetic = pendingReply {
                    names.pair(recorded: s.id, synthetic: synthetic, kind: s.kind)
                    pendingReply = nil
                    continue
                }
                if skippedKinds.contains(s.kind) {
                    notes["shape", default: 0] += 1  // a kind the builder skips
                    continue
                }
                pendingReply = nil
                // A reply after a reply needs a turn of its own (one turn's text is one reply).
                let fresh = s.kind == .person || lastTurn == 0 || (s.kind == .reply && lastKind == .reply)
                let turn = fresh ? nextTurn : lastTurn
                if fresh { nextTurn += 1 }
                appended += 1
                for message in try SyntheticConversation.events(chat: chat, shapes: [s], images: images).events {
                    model.apply(retarget(message, turn: turn, tag: "live-\(appended)-"))
                }
                if let id = entriesNow().last?.id { names.pair(recorded: s.id, synthetic: id, kind: s.kind) }
                lastTurn = turn
                lastKind = s.kind
                if s.kind == .reply { replyTurn = turn }
                take(event)
            case .turnFinished:
                guard lastTurn > 0 else { continue }
                model.apply(.turnFinished(TurnFinished(chat: chat, turn: lastTurn, outcome: .done)))
                take(event)
            case .removed: notes["removed", default: 0] += 1
            case .imageLoaded: notes["imageLoaded", default: 0] += 1
            case .toolRow: notes["toolRow", default: 0] += 1
            case .card: notes["card", default: 0] += 1
            case .viewer: notes["viewer", default: 0] += 1
            case .sidebar: notes["sidebar", default: 0] += 1
            case .textScale: notes["textScale", default: 0] += 1
            case .capped: notes["capped", default: 0] += 1
            }
        }

        lastReadings = readings
        lastNotes = notes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        lastHostedWidth = hosted.host.frame.width

        var evaluation = check(readings: readings)
        evaluation.appVersion = appVersion
        evaluation.macOS = macOS
        evaluation.phasesFire = probe.phased
        evaluation.phasesMove = abs(probe.moved) >= 1
        evaluation.recording = recording.lastPathComponent
        evaluation.started = started(from: recording)
        evaluation.lengthMs = (segment.last?.t ?? 0) - segment[0].t
        evaluation.segments = opens.count
        evaluation.entriesByKind = entries
        evaluation.skipped = notes
        return evaluation
    }

    /// A live copy of a builder message: the replay's turn, no sequence number (the
    /// model drops a live message at or below one it has seen), its own tool ids.
    private static func retarget(_ message: ServerMessage, turn: Int, tag: String) -> ServerMessage {
        switch message {
        case .userText(var m): m.turn = turn; m.seq = nil; return .userText(m)
        case .textDelta(var m): m.turn = turn; m.seq = nil; return .textDelta(m)
        case .toolStarted(var m): m.turn = turn; m.seq = nil; m.toolUseId = tag + m.toolUseId; return .toolStarted(m)
        case .toolFinished(var m): m.turn = turn; m.seq = nil; m.toolUseId = tag + m.toolUseId; return .toolFinished(m)
        default: return message
        }
    }

    /// The start time from the file name (`<chat>-<date>T<hh-mm-ss.mmm>Z[-N].jsonl`), colons put back.
    static func started(from recording: URL) -> String {
        let stem = recording.deletingPathExtension().lastPathComponent
        guard let dash = stem.firstIndex(of: "-"), let t = stem.firstIndex(of: "T") else { return "" }
        let date = stem[stem.index(after: dash)..<t]
        var time = String(stem[stem.index(after: t)...])
        if let z = time.firstIndex(of: "Z") { time = String(time[...z]) }
        return date + "T" + time.replacingOccurrences(of: "-", with: ":")
    }

    // MARK: - the evaluation file

    /// Writes the rendered evaluation to `<directory>/<recording-stem>.txt`, `directory` being
    /// the app's `diagnostics/evaluations/` (never beside a recording copied elsewhere). Creates
    /// `diagnostics/` and `evaluations/` 0700 when missing and tightens `evaluations/` to 0700
    /// when it exists; the file is 0600, replacing an earlier one.
    @discardableResult
    static func write(_ evaluation: Evaluation, for recording: URL, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let diagnostics = directory.deletingLastPathComponent()
        if !fm.fileExists(atPath: diagnostics.path) {
            try fm.createDirectory(at: diagnostics, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if fm.fileExists(atPath: directory.path) {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let url = directory.appendingPathComponent(recording.deletingPathExtension().lastPathComponent + ".txt")
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: Data((evaluation.render() + "\n").utf8), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The field entry point: skips without `PORTICO_REPLAY`; otherwise replays the
    /// named recording and writes its evaluation. The caller fails on violations.
    static func replayFromEnvironment(_ environment: [String: String]) throws -> (Evaluation, URL) {
        guard let path = environment[environmentKey], !path.isEmpty else {
            throw XCTSkip("set \(environmentKey)=<recording.jsonl> to replay a recording")
        }
        let recording = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // Taken before the run, which points the home at a temp folder for its duration.
        let directory = Diagnostics.evaluationsDirectory
        let images = FileManager.default.temporaryDirectory.appendingPathComponent("portico-replay-images-\(UUID().uuidString)", isDirectory: true)
        // Removed only when made: XCTest reports the last error thrown, and a `try?` remove of a
        // folder never made would mask the replay's own error (found with a hand-written recording).
        defer { if FileManager.default.fileExists(atPath: images.path) { try? FileManager.default.removeItem(at: images) } }
        let evaluation = try run(recording: recording, images: images)
        return (evaluation, try write(evaluation, for: recording, in: directory))
    }
}
