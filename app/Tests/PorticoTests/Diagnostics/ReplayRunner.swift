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
/// phaseless precise CGEvent wheel in points, a line wheel's lines times the
/// scroll view's line height (Ruling 15), the delta's sign unchanged), `key` (a key-down with focus in the transcript), `jump` (the
/// model's marker jump to the mapped message), `delta` (the last reply grows by
/// that many filler characters, or a new reply starts in the last turn), a new
/// entry's `shape` (appended as the synthetic builder makes it; a reply shape
/// right after a delta that started a reply names that reply), `turnFinished`
/// (the last turn ends). `phase` sets the phase of the readings that follow.
/// A gesture run (wheels with a scroll or momentum phase, or wheels while the
/// recorded phase is tracking or interacting, until the gesture or its momentum
/// ends or the phase goes idle) is fed at its recorded spacing (at most 50 ms
/// apart) inside a zero-delta began/ended envelope (Ruling 16), read per wheel
/// without settling while the document's height is sampled, and settled once at
/// its end; a wheel on its own settles on its own.
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
        case noSegment(Int, Int)
        case noHome
        var description: String {
            switch self {
            case .noHome: "set PORTICO_HOME to the app's home"
            case .noOpen: "the recording has no open event"
            case let .noSegment(n, count): "the recording has no segment \(n) (it has \(count))"
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
    /// The last run's wheels as sent (points, always precise; Ruling 15) and the line height used.
    static private(set) var lastSentWheels: [(pixels: Double, precise: Bool)] = []
    static private(set) var lastLineHeight: Double?
    /// The last run's gesture runs and the wheels fed inside them (I3).
    static private(set) var lastRuns: (runs: Int, wheels: Int) = (0, 0)

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

    /// Ruling 15: what a recorded wheel is sent as, in points. A pixel wheel as recorded; a
    /// line wheel (`precise == false`) as lines x the scroll view's line height (10 pt when it
    /// has none), because AppKit's own line-to-point conversion of a synthesized line wheel
    /// depends on the Mac's devices (it moved 10/4/25 pt, then 0 pt, on one Mac in one day).
    /// The sign is unchanged: positive is toward the top (ruling 10).
    static func pixels(deltaY: Double, precise: Bool, lineHeight: CGFloat) -> Double {
        precise ? deltaY : deltaY * Double(lineHeight > 0 ? lineHeight : 10)
    }

    /// A precise (pixel) wheel event of `pixels` whole points at `location` (CG screen
    /// coordinates, top-left origin), with the scroll phase and momentum phase fields set
    /// when given (the replay's envelope sends began and ended).
    static func wheelEvent(pixels: Double, at location: CGPoint, phase: NSEvent.Phase? = nil) -> NSEvent? {
        let amount = Int32(clamping: Int(pixels.rounded()))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: amount, wheel2: 0, wheel3: 0) else { return nil }
        if let phase {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        }
        cg.location = location
        return NSEvent(cgEvent: cg)
    }

    /// The scroll view's middle in CG screen coordinates.
    private static func location(of hosted: Hosted) -> CGPoint {
        let scroll = hosted.scroll
        let inWindow = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let screen = hosted.window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: screen.x, y: top - screen.y)
    }

    /// A wheel of `pixels` whole points as the app dispatches it, without gesture phases
    /// (ruling 3) unless `phase` is given.
    @discardableResult
    static func wheel(_ hosted: Hosted, pixels: Double, phase: NSEvent.Phase? = nil) -> Bool {
        guard let event = wheelEvent(pixels: pixels, at: location(of: hosted), phase: phase) else { return false }
        // Two calls, one delivery: `NSApp.sendEvent` runs the app's local monitor (the
        // person-input mark); the window is never shown or key, so it routes the event no
        // further, and only `scrollWheel(with:)` scrolls.
        NSApp.sendEvent(event)
        hosted.scroll.scrollWheel(with: event)
        return true
    }

    /// A recorded wheel, sent as `pixels(deltaY:precise:lineHeight:)` says (Ruling 15).
    @discardableResult
    static func wheel(_ hosted: Hosted, deltaY: Double, precise: Bool) -> Bool {
        wheel(hosted, pixels: pixels(deltaY: deltaY, precise: precise, lineHeight: hosted.scroll.verticalLineScroll))
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
        /// Recorded id -> recorded shape (the newest).
        var shapes: [String: EntryShape] = [:]

        mutating func pair(_ shape: EntryShape, synthetic: String) {
            recorded[synthetic] = shape.id
            self.synthetic[shape.id] = synthetic
            shapes[shape.id] = shape
        }
    }

    private static func reading(step: Int, input: RecordingEvent?, hosted: Hosted, chat: Int, phase: ScrollPhaseName,
                                settled: [Double], names: Names, hasRows: Bool,
                                syntheticKind: (String) -> EntryShape.Kind? = { _ in nil }) -> Reading {
        let clip = hosted.scroll.contentView.bounds
        let frames = ConversationProbe.rows[chat]?.frames ?? [:]
        let rows = frames.filter { $0.value.maxY > 0 && $0.value.minY < clip.height && $0.value.height > 0 }
            .sorted { $0.value.minY < $1.value.minY }
            .map { id, frame -> RowInView in
                let recorded = names.recorded[id]
                // `unmapped` (not expected: every drawn synthetic row comes from a recorded shape)
                // keeps the row for the rows-in-view check; it never enters the histogram.
                // An unmapped row is named by its synthetic entry's kind (G2: the failure says which row).
                let shape = recorded.flatMap { names.shapes[$0] }
                return RowInView(id: recorded ?? unmapped, kind: shape?.kind ?? syntheticKind(id) ?? .notice,
                                 height: Double(frame.height), minY: Double(clip.minY + frame.minY), shape: shape)
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
            let moved = i > 0 && noted[i - 1].segment == noted[i].segment ? abs(noted[i].offset - noted[i - 1].offset) : 0
            let bar = key == .up || key == .down ? 1 : 0.1 * Double(noted[i].clip.height)
            if moved >= bar { keysMoved += 1 } else { noted[i].note = "key-not-moved" }
        }
        let window: [Reading]
        if let failing = violations.first {
            window = noted.filter { $0.segment == failing.segment && abs($0.step - failing.step) <= 1 }
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

    /// The recording's segments: each `open` and what follows it up to the next.
    static func segments(_ all: [(t: Int, event: RecordingEvent)]) -> [[(t: Int, event: RecordingEvent)]] {
        let opens = all.indices.filter { if case .open = all[$0].event { true } else { false } }
        return opens.enumerated().map { n, start in
            Array(all[start..<(n + 1 < opens.count ? opens[n + 1] : all.endIndex)])
        }
    }

    /// `PORTICO_REPLAY_SEGMENT=<n>`: replay segment `n` only (from 1).
    static let segmentKey = "PORTICO_REPLAY_SEGMENT"
    static func segment(from environment: [String: String]) -> Int? {
        environment[segmentKey].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Replays every segment of the recording in order (I4), or segment `only`.
    static func run(recording: URL, images: URL, segment only: Int? = nil) throws -> Evaluation {
        let all = try Recorder.read(recording)
        let segments = Self.segments(all)
        guard let firstOpen = segments.first?.first, case let .open(chat, appVersion, macOS, _, _, _, _, _, _, _, _, _, _) = firstOpen.event
        else { throw Failure.noOpen }
        let chosen: [Int]
        if let only {
            guard segments.indices.contains(only - 1) else { throw Failure.noSegment(only, segments.count) }
            chosen = [only]
        } else {
            chosen = Array(1...segments.count)
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
        func openingShapes(_ segment: [(t: Int, event: RecordingEvent)]) -> [EntryShape] {
            Array(segment.dropFirst().prefix { if case .shape = $0.event { true } else { false } })
                .compactMap { if case .shape(let s) = $0.event { s } else { nil } }
        }
        func size(_ open: RecordingEvent) -> NSSize {
            guard case let .open(_, _, _, window, column, _, _, _, _, _, _, _, _) = open else { return NSSize(width: 800, height: 600) }
            return NSSize(width: CGFloat(column > 0 ? column : (window.first ?? 800)), height: CGFloat(window.count > 1 ? window[1] : 600))
        }

        // The phase probe (D12) on its own model, once: it scrolls, and each replay starts where
        // its segment did. It also measures the chrome (the hosted height outside the transcript's clip).
        let firstSegment = segments[chosen[0] - 1]
        let probeModel = try SyntheticConversation.model(chat: chat, shapes: openingShapes(firstSegment), images: images, defaults: try defaults())
        let probeHost = try host(probeModel, defaults: try defaults(), size: size(firstSegment[0].event))
        let chrome = max(0, probeHost.host.frame.height - probeHost.scroll.contentView.bounds.height)
        let probe = PhaseProbe.run(scroll: probeHost.scroll, chat: chat)
        probeHost.window.close()
        ConversationProbe.phaseNames[chat] = nil
        ConversationProbe.rows[chat] = nil

        var allReadings: [Reading] = []
        var allNotes: [String: Int] = [:]
        var allSent: [(pixels: Double, precise: Bool)] = []
        var allRuns = 0, allRunWheels = 0, allEnvelopeFailed = 0
        var lastEntries: [EntryShape.Kind: Int] = [:]
        for number in chosen {
            try replay(segments[number - 1], number: number)
        }

        /// One segment, from its own `open`, on a model and host of its own.
        func replay(_ segment: [(t: Int, event: RecordingEvent)], number: Int) throws {
        guard case let .open(_, _, _, window, _, _, _, _, _, atBottom, topId, topOffset, clipHeight) = segment[0].event else { return }
        let shapes = openingShapes(segment)
        let cursor = 1 + shapes.count
        var size = size(segment[0].event)
        // I4: hosted so the transcript's clip is the recorded one; window steps keep their difference.
        if clipHeight > 0 { size.height = CGFloat(clipHeight) + chrome }
        let windowHeight = CGFloat(window.count > 1 ? window[1] : 600)

        let built = try SyntheticConversation.events(chat: chat, shapes: shapes, images: images)
        var names = Names()
        for shape in shapes {
            if let synthetic = built.ids[shape.id] ?? nil { names.pair(shape, synthetic: synthetic) }
        }
        var entries: [EntryShape.Kind: Int] = [:]
        for shape in shapes { entries[shape.kind, default: 0] += 1 }
        let model = try SyntheticConversation.model(chat: chat, shapes: shapes, images: images, defaults: try defaults())
        var hosted = try host(model, defaults: try defaults(), size: size)
        defer { hosted.window.close() }
        // I4: the starting place, put back as the app puts a conversation's place back: away to
        // another conversation and back, the place kept in between (found hosted: a restore at
        // the window's very first layout finds no row laid out and leaves the view at the top,
        // and a switch to no conversation leaves the new scroll view unlaid out).
        if !atBottom, let topId, let synthetic = names.synthetic[topId] {
            let away = chat + 1
            model.apply(.chatList(ChatList(chats: [chat, away].map {
                ChatSummary(chat: $0, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")
            })))
            model.selected = away
            spin(0.4)
            model.notePlace(ConversationPlace(atBottom: false, topItem: synthetic, topOffset: CGFloat(topOffset)), chat: chat)
            model.selected = chat
            spin(1.0)
            // The conversation came back as a new view, with a scroll view of its own.
            guard let scroll = transcriptScroll(in: hosted.host) else { throw Failure.noScrollView }
            hosted = Hosted(window: hosted.window, host: hosted.host, scroll: scroll)
        }

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
        /// The new reply's shape that follows the delta at `index` before a delta of another turn,
        /// if any: that delta starts it, and the reply it starts is named by it from the delta on (G2).
        func replyStarted(at index: Int) -> EntryShape? {
            guard case .delta(let turn, _) = rest[index].event else { return nil }
            for (_, later) in rest[(index + 1)...] {
                switch later {
                case .shape(let s) where s.kind == .reply && !known.contains(s.id): return s
                case .delta(let t, _) where t != turn: return nil
                default: continue
                }
            }
            return nil
        }
        var known = Set(shapes.map(\.id))
        var notes: [String: Int] = [:]
        var phase: ScrollPhaseName = .idle
        var residual = 0.0
        var sent: [(pixels: Double, precise: Bool)] = []
        var runs = 0, runWheels = 0, envelopeFailed = 0
        var readings: [Reading] = []
        var appended = 0

        func entriesNow() -> [TranscriptEntry] { TranscriptEntry.entries(model.transcripts[chat] ?? []) }
        func take(_ input: RecordingEvent?, settled given: [Double]? = nil) {
            let step = readings.count
            XCTAssertTrue(Diagnostics.recorders.isEmpty, "the replay records nothing")
            let settled = given ?? settle(hosted)
            readings.append(reading(step: step, input: input, hosted: hosted, chat: chat, phase: phase,
                                    settled: settled, names: names, hasRows: !entriesNow().isEmpty,
                                    syntheticKind: { id in entriesNow().first { $0.id == id }.map { EntryShape.of($0, imageSize: { _ in nil }).kind } }))
            readings[readings.count - 1].segment = number
            onStep?(step)
        }

        // I3: a gesture run (a trackpad's phased wheels, or a mouse's wheels while SwiftUI
        // reports a phase) is fed at its recorded spacing inside the envelope (Ruling 16),
        // sampling the document's height all through, and settles once at its end.
        var inRun = false
        var runSamples: [Double] = []
        var runLastWheel: Int?
        var runLastT: Int?
        func sample() { runSamples.append(Double(hosted.scroll.documentView?.frame.height ?? 0)) }
        func startRun() {
            inRun = true
            runs += 1
            runSamples = []
            runLastWheel = nil
            runLastT = nil
            let seen = ConversationProbe.phaseNames[chat]?.count ?? 0
            wheel(hosted, pixels: 0, phase: .began)
            spin(0.05)
            let names = ConversationProbe.phaseNames[chat] ?? []
            if !names.dropFirst(min(seen, names.count)).contains(where: { $0 != "idle" }) { envelopeFailed += 1 }
        }
        func endRun() {
            guard inRun else { return }
            inRun = false
            wheel(hosted, pixels: 0, phase: .ended)
            let settled = settle(hosted)
            // The run's last wheel is read again, settled, with every height sampled in the run.
            if let i = runLastWheel {
                let fresh = reading(step: readings[i].step, input: readings[i].input, hosted: hosted, chat: chat, phase: readings[i].phase,
                                    settled: runSamples + settled, names: names, hasRows: !entriesNow().isEmpty)
                readings[i] = fresh
                readings[i].segment = number
            }
        }
        /// Whether the wheel at `index` closes its run: its momentum ended, or its gesture ended
        /// (or was cancelled) with no momentum wheel before the next idle phase.
        func closesRun(at index: Int) -> Bool {
            guard case let .wheel(_, _, p, m) = rest[index].event else { return false }
            if m == 8 { return true }
            guard m == 0, p == 8 || p == 16 else { return false }
            for (_, later) in rest[(index + 1)...] {
                switch later {
                case .wheel(_, _, _, let lm): return lm == 0
                case .phase(.idle): return true
                default: continue
                }
            }
            return true
        }

        take(nil)
        for (index, (t, event)) in rest.enumerated() {
            switch event {
            case .phase(let p):
                phase = p
                if p == .idle { endRun() } else if p == .tracking || p == .interacting, !inRun { startRun() }
            case .open:
                break  // the segment's own, read above
            case .window(_, let h):
                resize(hosted, height: max(1, CGFloat(h) - windowHeight + size.height))
                take(event)
            case .column(let w):
                resize(hosted, width: CGFloat(w))
                take(event)
            case let .wheel(deltaY, precise, p, m):
                if !inRun, p != 0 || m != 0 { startRun() }
                if inRun, let last = runLastT {
                    // The recorded spacing, at most 50 ms, sampling the height every 10 ms.
                    let gap = min(max(t - last, 0), 50)
                    for _ in 0..<max(gap / 10, 1) { spin(0.01); sample() }
                }
                // Ruling 15: lines become points; the remainder of a whole-point CGEvent field carries to the next wheel.
                let exact = pixels(deltaY: deltaY, precise: precise, lineHeight: hosted.scroll.verticalLineScroll) + residual
                let whole = exact.rounded()
                residual = exact - whole
                wheel(hosted, pixels: whole)
                sent.append((pixels: whole, precise: true))
                if inRun {
                    spin(0.01)
                    sample()
                    runLastT = t
                    runLastWheel = readings.count
                    take(event, settled: [runSamples.last ?? 0])
                    runWheels += 1
                    if closesRun(at: index) { endRun() }
                } else {
                    take(event)
                }
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
                let started = replyStarted(at: index)
                if let turn = replyTurn, sameStream || (lastKind == .reply && started == nil) {
                    model.apply(.textDelta(TextDelta(chat: chat, turn: turn, text: " " + text)))
                } else {
                    // A new reply: in the turn of the question just appended, else a turn of its own.
                    let turn: Int
                    if lastKind == .person, lastTurn > 0 { turn = lastTurn } else { turn = nextTurn; nextTurn += 1 }
                    model.apply(.textDelta(TextDelta(chat: chat, turn: turn, text: text)))
                    pendingReply = entriesNow().last?.id
                    // Named now by the shape that follows, so the step's reading maps it.
                    if let started, let synthetic = pendingReply {
                        names.pair(started, synthetic: synthetic)
                    }
                    lastTurn = turn
                    replyTurn = turn
                    lastKind = .reply
                }
                take(event)
            case .shape(let s):
                if known.contains(s.id) {
                    // A known entry re-shaped: deltas already grew it; its metrics are the newest.
                    if let synthetic = names.synthetic[s.id] { names.pair(s, synthetic: synthetic) }
                    notes["shape", default: 0] += 1
                    continue
                }
                known.insert(s.id)
                entries[s.kind, default: 0] += 1
                if s.kind == .reply, let synthetic = pendingReply {
                    names.pair(s, synthetic: synthetic)
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
                if let id = entriesNow().last?.id { names.pair(s, synthetic: id) }
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

        endRun()

        allReadings += readings
        for (kind, count) in notes { allNotes[kind, default: 0] += count }
        allSent += sent
        allRuns += runs
        allRunWheels += runWheels
        allEnvelopeFailed += envelopeFailed
        lastEntries = entries
        lastHostedWidth = hosted.host.frame.width
        lastLineHeight = Double(hosted.scroll.verticalLineScroll > 0 ? hosted.scroll.verticalLineScroll : 10)
        }

        lastReadings = allReadings
        lastRuns = (runs: allRuns, wheels: allRunWheels)
        lastNotes = allNotes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        lastSentWheels = allSent

        var evaluation = check(readings: allReadings)
        evaluation.appVersion = appVersion
        evaluation.macOS = macOS
        evaluation.phasesFire = probe.phased
        evaluation.phasesMove = abs(probe.moved) >= 1
        evaluation.recording = recording.lastPathComponent
        evaluation.started = started(from: recording)
        let replayed = chosen.map { segments[$0 - 1] }
        evaluation.lengthMs = (replayed.last?.last?.t ?? 0) - (replayed.first?.first?.t ?? 0)
        evaluation.segments = segments.count
        evaluation.replayed = chosen
        evaluation.entriesByKind = lastEntries
        evaluation.skipped = allNotes
        evaluation.envelope = allEnvelopeFailed > 0 ? "off (phases did not fire)" : "on (\(allRuns) gesture runs)"
        return evaluation
    }

    /// I3c: the steps a replay of `events` takes (an opening reading per segment, one per
    /// input it applies) and about how long, in seconds: the phase probe once (about 4 s),
    /// hosting per segment (about 2 s) and a settle per step (about 0.35 s).
    static func estimate(_ events: [(t: Int, event: RecordingEvent)]) -> (steps: Int, seconds: Int) {
        var steps = 0, segments = 0
        for (_, event) in events {
            switch event {
            case .open: segments += 1; steps += 1
            case .wheel, .key, .jump, .delta, .turnFinished, .window, .column: steps += 1
            default: continue
            }
        }
        return (steps, Int((4 + Double(segments) * 2 + Double(steps) * 0.35).rounded(.up)))
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

    /// I6: where a recording's evaluation goes, `<home>/diagnostics/evaluations/`, `<home>` being
    /// the first of: the home the recording sits in (`<home>/diagnostics/recordings/<file>`, its
    /// `diagnostics/` there); `PORTICO_HOME`; the folder the checkout's `.portico-home` names (read
    /// as the gateway's `StateDir` reads it). The home's `diagnostics/` must exist: it is never made
    /// here. None found: `Failure.noHome`.
    static func evaluationsDirectory(for recording: URL, environment: [String: String], checkout: URL?) throws -> URL {
        let fm = FileManager.default
        func exists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        let parent = recording.deletingLastPathComponent()
        if parent.lastPathComponent == "recordings", parent.deletingLastPathComponent().lastPathComponent == "diagnostics" {
            let diagnostics = parent.deletingLastPathComponent()
            if exists(diagnostics) { return diagnostics.appendingPathComponent("evaluations", isDirectory: true) }
        }
        var home: URL?
        if let named = environment["PORTICO_HOME"], !named.isEmpty {
            home = URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
        } else if let checkout, fm.fileExists(atPath: checkout.appendingPathComponent("bin/portico-gateway").path),
                  let line = try? String(contentsOf: checkout.appendingPathComponent(".portico-home"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            home = URL(fileURLWithPath: (line as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard let home, exists(home.appendingPathComponent("diagnostics", isDirectory: true)) else { throw Failure.noHome }
        return home.appendingPathComponent("diagnostics/evaluations", isDirectory: true)
    }

    /// The checkout this test target was built from (`app/Tests/PorticoTests/Diagnostics/` four up).
    static let checkout: URL? = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Writes the rendered evaluation to `<directory>/<recording-stem>.txt`, `directory` being a
    /// home's `diagnostics/evaluations/`. Never makes `diagnostics/` (I6); makes `evaluations/`
    /// 0700 when missing and tightens it to 0700 when it exists; the file is 0600, replacing an
    /// earlier one.
    @discardableResult
    static func write(_ evaluation: Evaluation, for recording: URL, in directory: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.deletingLastPathComponent().path) else { throw Failure.noHome }
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

    /// What the field entry point prints (I7): the evaluation file's name, never its folder, then the evaluation.
    static func fieldOutput(_ evaluation: Evaluation, file: URL) -> String {
        "PORTICO-EVALUATION \(file.lastPathComponent)\n\(evaluation.render())"
    }

    /// The field entry point: skips without `PORTICO_REPLAY`; otherwise replays the
    /// named recording and writes its evaluation. The caller fails on violations.
    static func replayFromEnvironment(_ environment: [String: String], checkout: URL? = checkout) throws -> (Evaluation, URL) {
        guard let path = environment[environmentKey], !path.isEmpty else {
            throw XCTSkip("set \(environmentKey)=<recording.jsonl> to replay a recording")
        }
        let recording = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        // Decided before the run (I6): a missing home fails before minutes of replay.
        let directory = try evaluationsDirectory(for: recording, environment: environment, checkout: checkout)
        let images = FileManager.default.temporaryDirectory.appendingPathComponent("portico-replay-images-\(UUID().uuidString)", isDirectory: true)
        // Removed only when made: XCTest reports the last error thrown, and a `try?` remove of a
        // folder never made would mask the replay's own error (found with a hand-written recording).
        defer { if FileManager.default.fileExists(atPath: images.path) { try? FileManager.default.removeItem(at: images) } }
        if let events = try? Recorder.read(recording) {
            let estimate = estimate(events)
            print("PORTICO-REPLAY \(recording.lastPathComponent): \(estimate.steps) steps, about \(estimate.seconds) s")
        }
        let evaluation = try run(recording: recording, images: images, segment: segment(from: environment))
        return (evaluation, try write(evaluation, for: recording, in: directory))
    }
}
