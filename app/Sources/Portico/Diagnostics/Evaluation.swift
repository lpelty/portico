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

    func render() -> String {
        var lines = [
            "app: \(appVersion)", "macOS: \(macOS)", "recording: \(URL(fileURLWithPath: recording).lastPathComponent)", "started: \(started)",
            "length: \(lengthMs) ms", "phases: fire=\(phasesFire) move=\(phasesMove)", "envelope: \(envelope)", "segments: \(segments)",
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
        for v in violations { lines.append("step \(v.segment).\(v.step) \(v.rule.rawValue): \(v.detail)") }
        lines.append("window:")
        for r in window {
            let rows = r.rowsInView.map { "\($0.id):\($0.kind.rawValue):\(Int($0.height.rounded()))" }.joined(separator: ",")
            lines.append("step \(r.segment).\(r.step) input=\(Self.kind(of: r.input)) offset=\(Int(r.offset.rounded())) doc=\(Int(r.documentHeight.rounded())) "
                + "clip=\(Int(r.clip.minY.rounded()))..\(Int(r.clip.maxY.rounded())) phase=\(r.phase.rawValue) rows=[\(rows)]" + (r.note.map { " note=\($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The event's kind name (its recording `kind`), read from its encoding so the case list lives in one place.
    private static func kind(of event: RecordingEvent?) -> String {
        guard let event, let data = try? JSONEncoder().encode(event),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return "none" }
        return kind
    }
}
