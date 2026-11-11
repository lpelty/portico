import CoreGraphics
import Foundation

/// v0.26.4 (D9): one step of a replay, taken after the view settled.
struct Reading: Equatable, Sendable {
    var step: Int
    /// The recording's segment (each `open` starts one), from 1; steps count from 0 in each (I4).
    var segment: Int = 1
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
    /// The replay's own remark on this step (harness fidelity, never a violation); counts and names only.
    var note: String? = nil
    /// False for a wheel read mid-gesture, before the run settles (I3): the view may stretch past
    /// an end there as AppKit's rubber band does, so `pastEnd` waits for the settled reading.
    var settled: Bool = true
}

struct RowInView: Equatable, Sendable {
    var id: String
    var kind: EntryShape.Kind
    var height: Double
    var minY: Double
    /// The recorded shape (I5: the window prints its metrics); nil for an unmapped row.
    var shape: EntryShape? = nil
}

struct Violation: Equatable, Sendable {
    enum Rule: String, Sendable { case alternation, wheelMoves, rowsInView, pastEnd, estimateDrift }
    var rule: Rule
    var step: Int
    /// One line of numbers; never content.
    var detail: String
    var segment: Int = 1
}

/// The failures the field logs already show, as checks over a replay's readings.
enum Invariants {
    static let wheelTolerance = 8.0
    static let pastEndSlack = Double(TranscriptBlankSpace.slack)
    static let driftFraction = 0.25
    /// Readings in an a, b, a, b, ... run before it counts.
    static let alternationLength = 4

    /// Each segment on its own (I4): a step is never compared with another segment's.
    static func check(_ readings: [Reading]) -> [Violation] {
        var out: [Violation] = []
        var start = readings.startIndex
        while start < readings.endIndex {
            let segment = readings[start].segment
            let end = readings[start...].firstIndex { $0.segment != segment } ?? readings.endIndex
            out += checkSegment(Array(readings[start..<end])).map { var v = $0; v.segment = segment; return v }
            start = end
        }
        return out
    }

    private static func checkSegment(_ readings: [Reading]) -> [Violation] {
        var out: [Violation] = []
        for (i, r) in readings.enumerated() {
            let previous = i > 0 ? readings[i - 1] : nil
            if let (a, b, run) = alternation(r.settledReadings) {
                out.append(Violation(rule: .alternation, step: r.step, detail: "document height flipped between \(n(a)) and \(n(b)) \(run - 1) times"))
            }
            if let previous, case .wheel(let deltaY, let precise, _, _) = r.input, !pushesIntoItsEnd(previous, deltaY: deltaY) {
                // Ruling 19: an unsettled reading (mid-gesture) may sit in AppKit's rubber band past an
                // end; clamped to the document, its direction and amount are still checked.
                let moved = clamped(r) - clamped(previous)
                if precise {
                    // I1: the movement the document allows (a wheel past an end stops at it).
                    let expected = min(max(previous.offset - deltaY, 0), maxOffset(previous)) - previous.offset
                    if abs(moved - expected) > wheelTolerance {
                        out.append(Violation(rule: .wheelMoves, step: r.step, detail: "wheel delta \(n(deltaY)) moved the offset \(n(moved)), expected \(n(expected))"))
                    }
                } else if deltaY != 0, abs(moved) < 1 || (moved > 0) == (deltaY > 0) {
                    // Ruling 12: a line wheel's delta is in lines (its points depend on the line
                    // height), so only the direction and some movement are checked.
                    out.append(Violation(rule: .wheelMoves, step: r.step, detail: "line wheel delta \(deltaY) moved the offset \(n(moved)), expected against it"))
                }
            }
            if r.hasRows, r.rowsInView.isEmpty {
                out.append(Violation(rule: .rowsInView, step: r.step, detail: "no rows in view at offset \(n(r.offset))"))
            }
            if r.settled, r.clip.maxY > r.documentHeight + pastEndSlack {
                out.append(Violation(rule: .pastEnd, step: r.step, detail: "clip.maxY \(n(Double(r.clip.maxY))) > doc \(n(r.documentHeight))"))
            }
            if let previous, !reflows(previous.input), !reflows(r.input),
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

    private static func maxOffset(_ p: Reading) -> Double { max(p.documentHeight - Double(p.clip.height), 0) }

    /// The offset, held to the document when the reading is unsettled (Ruling 19).
    private static func clamped(_ p: Reading) -> Double { p.settled ? p.offset : min(max(p.offset, 0), maxOffset(p)) }

    /// I1: a wheel into the end the view already is at (at the top with a positive delta,
    /// toward the top; at the bottom with a negative one) has nowhere to go: exempt.
    static func pushesIntoItsEnd(_ p: Reading, deltaY: Double) -> Bool {
        (p.offset <= 0 && deltaY > 0) || (p.offset >= maxOffset(p) - pastEndSlack && deltaY < 0)
    }

    /// Inputs across which the document's height may change by any amount: new content, and
    /// (I2) geometry, which re-wraps every row.
    private static func reflows(_ e: RecordingEvent?) -> Bool {
        switch e {
        case .delta, .shape, .imageLoaded, .removed: true
        case .column, .window, .textScale, .viewer, .sidebar: true
        default: false
        }
    }

    private static func n(_ v: Double) -> Int { Int(v.rounded()) }
}
