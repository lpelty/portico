import CoreGraphics
import Foundation

/// v0.26.4 (D10): the only artefact that leaves the machine where a recording
/// was made. Text with counts and opaque ids only: never message text, names,
/// paths or titles.
struct Evaluation: Equatable, Sendable {
    var appVersion: String
    var macOS: String
    /// Whether synthesized phased wheels reach SwiftUI's phase handler, and whether they move the view, on this Mac.
    var phasesFire: Bool
    var phasesMove: Bool
    /// File name only.
    var recording: String
    var started: String
    var lengthMs: Int
    /// Each `open` in a recording starts a segment.
    var segments: Int
    var entriesByKind: [EntryShape.Kind: Int]
    /// Bucket start (50 pt buckets) to count.
    var heightHistogram: [Int: Int]
    var violations: [Violation]
    /// The failing step and its neighbours, or the last three.
    var window: [Reading]
    /// Readings taken (one per applied input, plus the opening one).
    var steps: Int = 0
    /// Key steps, and those that moved the view (ruling 13: the replay's keys may not move it as a person's do).
    var keysStepped: Int = 0
    var keysMoved: Int = 0
    /// Recording event kinds the replay did not apply, and how many.
    var skipped: [String: Int] = [:]
    /// The segments replayed (from 1); empty for readings checked on their own.
    var replayed: [Int] = []
    /// Whether the replay's zero-delta began/ended envelope put SwiftUI's phase out of idle
    /// around each gesture run (Ruling 16): `on (N gesture runs)` or `off (phases did not fire)`.
    var envelope: String = "on (0 gesture runs)"
    /// The text scale the recording was made at, and whether the replay drew at it (I8).
    var textScale: Double = 1
    var textScaleApplied = true
    /// Lines dropped from the recording's end (a half-written last line, I9).
    var truncated = 0

    /// Skipped kinds that are inputs the replay could not apply (I8); re-shapes, image loads,
    /// tool rows and the cap marker are covered otherwise and do not count.
    static let skippedInputs: Set<String> = ["viewer", "sidebar", "jump", "removed", "card"]

    /// Ruling 17: `red` with violations; `inconclusive (<reasons>)` when a key step did not move
    /// the view, the text scale was not applied, the envelope's phases did not fire, or more than
    /// a tenth of the steps' worth of inputs were skipped; `green` otherwise.
    var verdict: String {
        if !violations.isEmpty { return "red" }
        var reasons: [String] = []
        if keysMoved < keysStepped { reasons.append("\(keysStepped - keysMoved) of \(keysStepped) key steps did not move the view") }
        if textScale != 1, !textScaleApplied { reasons.append("text scale \(textScale) not applied") }
        if envelope.hasPrefix("off") { reasons.append("the envelope's phases did not fire") }
        let skippedInputs = skipped.filter { Self.skippedInputs.contains($0.key) }.values.reduce(0, +)
        if Double(skippedInputs) > 0.1 * Double(steps) { reasons.append("\(skippedInputs) inputs skipped of \(steps) steps") }
        return reasons.isEmpty ? "green" : "inconclusive (\(reasons.joined(separator: "; ")))"
    }

    func render() -> String {
        var lines = [
            "verdict: \(verdict)",
            "app: \(appVersion)", "macOS: \(macOS)", "recording: \(URL(fileURLWithPath: recording).lastPathComponent)", "started: \(started)",
            "length: \(lengthMs) ms", "phases: fire=\(phasesFire) move=\(phasesMove)", "envelope: \(envelope)",
            "textScale: \(textScale) " + (textScaleApplied ? "applied" : "not applied"), "truncated: \(truncated)", "segments: \(segments)",
            "steps: \(steps)", "keys: \(keysStepped) stepped, \(keysMoved) moved",
            "skipped: " + (skipped.isEmpty ? "none" : skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")),
            "entries:",
        ]
        for (kind, count) in entriesByKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { lines.append("\(kind.rawValue): \(count)") }
        lines.append("heights:")
        for (bucket, count) in heightHistogram.sorted(by: { $0.key < $1.key }) { lines.append("\(bucket)-\(bucket + 49): \(count)") }
        lines.append("violations: \(violations.count)")
        // I4: per segment replayed (or, for readings checked on their own, per segment seen).
        var bySegment: [Int: Int] = Dictionary(uniqueKeysWithValues: replayed.map { ($0, 0) })
        for v in violations { bySegment[v.segment, default: 0] += 1 }
        if !bySegment.isEmpty {
            lines.append("per segment: " + bySegment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        if !violations.isEmpty {
            var byRule: [String: Int] = [:]
            for v in violations { byRule[v.rule.rawValue, default: 0] += 1 }
            lines.append("per rule: " + byRule.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        for v in violations.prefix(Self.violationsShown) { lines.append("step \(v.segment).\(v.step) \(v.rule.rawValue): \(v.detail)") }
        if violations.count > Self.violationsShown { lines.append("… and \(violations.count - Self.violationsShown) more") }
        lines.append("window:")
        for r in window {
            let rows = r.rowsInView.map(Self.render(row:)).joined(separator: ",")
            lines.append("step \(r.segment).\(r.step) input=\(Self.render(input: r.input)) offset=\(Int(r.offset.rounded())) doc=\(Int(r.documentHeight.rounded())) "
                + "clip=\(Int(r.clip.minY.rounded()))..\(Int(r.clip.maxY.rounded())) phase=\(r.phase.rawValue) rows=[\(rows)]" + (r.note.map { " note=\($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The violations listed in full; the rest are counted (I5).
    static let violationsShown = 20

    /// A row: `<id>:<kind>:<height>`, then its recorded metrics that are not empty (I5).
    static func render(row: RowInView) -> String {
        let head = "\(row.id):\(row.kind.rawValue):\(Int(row.height.rounded()))"
        guard let s = row.shape else { return head }
        func list(_ v: [Int]) -> String { "[" + v.map(String.init).joined(separator: ",") + "]" }
        func lists(_ v: [[Int]]) -> String { "[" + v.map(list).joined(separator: ",") + "]" }
        var fields: [String] = []
        if !s.paragraphs.isEmpty { fields.append("paragraphs=\(list(s.paragraphs))") }
        if !s.codeBlocks.isEmpty { fields.append("code=\(list(s.codeBlocks))") }
        if !s.images.isEmpty { fields.append("images=\(lists(s.images))") }
        if !s.tables.isEmpty { fields.append("tables=\(lists(s.tables))") }
        if s.toolRows > 0 { fields.append("toolRows=\(s.toolRows)") }
        return fields.isEmpty ? head : head + "{" + fields.joined(separator: " ") + "}"
    }

    /// An input with its fields (I5); never content (a viewer's shown id is left out).
    static func render(input: RecordingEvent?) -> String {
        guard let input else { return "none" }
        switch input {
        case let .open(chat, _, _, window, column, _, _, _, _, _, _, _, _): return "open(chat=\(chat) window=\(window.map(String.init).joined(separator: "x")) column=\(column))"
        case .shape(let s): return "shape(\(s.id):\(s.kind.rawValue))"
        case .removed(let id): return "removed(\(id))"
        case let .imageLoaded(id, index, height): return "imageLoaded(\(id) index=\(index) height=\(height))"
        case let .window(width, height): return "window(\(width)x\(height))"
        case .column(let width): return "column(\(width))"
        case let .viewer(visible, width, _): return "viewer(visible=\(visible) width=\(width))"
        case .sidebar(let visible): return "sidebar(visible=\(visible))"
        case .textScale(let v): return "textScale(\(v))"
        case let .wheel(deltaY, precise, phase, momentum):
            return "wheel(deltaY=\(deltaY) precise=\(precise) phase=\(phaseName(phase))" + (momentum != 0 ? " momentum=\(phaseName(momentum))" : "") + ")"
        case .key(let k): return "key(\(k.rawValue))"
        case .jump(let id): return "jump(\(id))"
        case .phase(let p): return "phase(\(p.rawValue))"
        case let .delta(turn, chars): return "delta(turn=\(turn) chars=\(chars))"
        case .turnFinished(let turn): return "turnFinished(\(turn))"
        case .toolRow(let id): return "toolRow(\(id))"
        case let .card(id, docked): return "card(\(id) docked=\(docked))"
        case .capped(let bytes): return "capped(\(bytes))"
        }
    }

    /// `NSEvent.Phase` raw values by name.
    private static func phaseName(_ raw: Int) -> String {
        switch raw {
        case 0: "none"
        case 1: "began"
        case 2: "stationary"
        case 4: "changed"
        case 8: "ended"
        case 16: "cancelled"
        case 32: "mayBegin"
        default: "\(raw)"
        }
    }
}
