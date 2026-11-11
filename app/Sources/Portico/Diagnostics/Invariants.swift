import CoreGraphics
import Foundation

/// v0.26.4 (D9): one step of a replay, taken after the view settled.
struct Reading: Equatable, Sendable {
    var step: Int
    var input: RecordingEvent?
    var offset: Double
    var documentHeight: Double
    var clip: CGRect
    var rowsInView: [RowInView]
    var phase: ScrollPhaseName
    /// Document heights sampled while settling, in order.
    var settledReadings: [Double]
    /// Whether the conversation has entries to draw.
    var hasRows: Bool = true
}

struct RowInView: Equatable, Sendable {
    var id: String
    var kind: EntryShape.Kind
    var height: Double
    var minY: Double
}

struct Violation: Equatable, Sendable {
    enum Rule: String, Sendable { case alternation, wheelMoves, rowsInView, pastEnd, estimateDrift }
    var rule: Rule
    var step: Int
    /// One line of numbers; never content.
    var detail: String
}

/// The failures the field logs already show, as checks over a replay's readings.
enum Invariants {
    static let wheelTolerance = 8.0
    static let pastEndSlack = Double(TranscriptBlankSpace.slack)
    static let driftFraction = 0.25
    /// Readings in an a, b, a, b, ... run before it counts.
    static let alternationLength = 4

    static func check(_ readings: [Reading]) -> [Violation] {
        var out: [Violation] = []
        for (i, r) in readings.enumerated() {
            let previous = i > 0 ? readings[i - 1] : nil
            if let (a, b, run) = alternation(r.settledReadings) {
                out.append(Violation(rule: .alternation, step: r.step, detail: "document height flipped between \(n(a)) and \(n(b)) \(run - 1) times"))
            }
            if let previous, case .wheel(let deltaY, _, _, _) = r.input, !startedAtAnEnd(previous) {
                let moved = r.offset - previous.offset
                if abs(moved + deltaY) > wheelTolerance {
                    out.append(Violation(rule: .wheelMoves, step: r.step, detail: "wheel delta \(n(deltaY)) moved the offset \(n(moved)), expected \(n(-deltaY))"))
                }
            }
            if r.hasRows, r.rowsInView.isEmpty {
                out.append(Violation(rule: .rowsInView, step: r.step, detail: "no rows in view at offset \(n(r.offset))"))
            }
            if r.clip.maxY > r.documentHeight + pastEndSlack {
                out.append(Violation(rule: .pastEnd, step: r.step, detail: "clip.maxY \(n(Double(r.clip.maxY))) > doc \(n(r.documentHeight))"))
            }
            if let previous, !addsContent(previous.input), !addsContent(r.input),
               abs(r.documentHeight - previous.documentHeight) > driftFraction * previous.documentHeight {
                out.append(Violation(rule: .estimateDrift, step: r.step, detail: "doc \(n(previous.documentHeight)) -> \(n(r.documentHeight)) with no new content"))
            }
        }
        return out
    }

    /// The longest a, b, a, b run (length, the two values), when it reaches `alternationLength`.
    private static func alternation(_ h: [Double]) -> (Double, Double, Int)? {
        var best: (Double, Double, Int)?
        var start = 0
        for i in 1..<max(h.count, 1) {
            guard abs(h[i] - h[i - 1]) >= 1 else { start = i; continue }
            if i - start >= 2, abs(h[i] - h[i - 2]) >= 1 { start = i - 1 }
            let run = i - start + 1
            if run >= alternationLength, run > (best?.2 ?? 0) { best = (h[start], h[start + 1], run) }
        }
        return best
    }

    private static func startedAtAnEnd(_ p: Reading) -> Bool {
        p.offset <= 0 || p.offset >= p.documentHeight - Double(p.clip.height) - pastEndSlack
    }

    private static func addsContent(_ e: RecordingEvent?) -> Bool {
        switch e {
        case .delta, .shape, .imageLoaded, .removed: true
        default: false
        }
    }

    private static func n(_ v: Double) -> Int { Int(v.rounded()) }
}
