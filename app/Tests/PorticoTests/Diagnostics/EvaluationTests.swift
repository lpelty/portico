import CoreGraphics
import XCTest

@testable import Portico

/// v0.26.4 (D10): the one artefact that leaves the machine; text with counts and opaque ids only.
final class EvaluationTests: XCTestCase {
    private func make() -> Evaluation {
        let r = Reading(step: 7, input: .wheel(deltaY: -40, precise: true, phase: 0, momentum: 0), offset: 1234.4,
                        documentHeight: 9000.6, clip: CGRect(x: 0, y: 1234, width: 600, height: 800),
                        rowsInView: [RowInView(id: "assistant:ZEBRA", kind: .reply, height: 120, minY: 1200),
                                     RowInView(id: "user:Q", kind: .person, height: 40, minY: 1320)],
                        phase: .decelerating, settledReadings: [], hasRows: true)
        let quiet = Reading(step: 8, input: nil, offset: 0, documentHeight: 10, clip: CGRect(x: 0, y: 0, width: 5, height: 5),
                            rowsInView: [], phase: .idle, settledReadings: [], hasRows: true)
        return Evaluation(appVersion: "0.26.4", macOS: "27.0", phasesFire: true, phasesMove: false,
                          recording: "/Users/someone/recordings/12-2026-11-10T21-05-00.250Z.jsonl", started: "2026-11-10T21:05:00Z", lengthMs: 4200,
                          segments: 2, entriesByKind: [.reply: 30, .person: 30, .tool: 4],
                          heightHistogram: [150: 3, 0: 12],
                          violations: [Violation(rule: .pastEnd, step: 7, detail: "clip.maxY 9100 > doc 9000")],
                          window: [r, quiet])
    }

    func testRenderCarriesHeaderHistogramViolationsAndWindowWithoutContent() {
        let lines = make().render().components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(7)), [
            "app: 0.26.4", "macOS: 27.0", "recording: 12-2026-11-10T21-05-00.250Z.jsonl",
            "started: 2026-11-10T21:05:00Z", "length: 4200 ms", "phases: fire=true move=false", "segments: 2",
        ])
        XCTAssertEqual(Array(lines[7...]), [
            "entries:", "person: 30", "reply: 30", "tool: 4",
            "heights:", "0-49: 12", "150-199: 3",
            "violations: 1", "step 7 pastEnd: clip.maxY 9100 > doc 9000",
            "window:",
            "step 7 input=wheel offset=1234 doc=9001 clip=1234..2034 phase=decelerating rows=[assistant:ZEBRA:reply:120,user:Q:person:40]",
            "step 8 input=none offset=0 doc=10 clip=0..5 phase=idle rows=[]",
        ])
    }

    func testRenderHasNoContentKeys() {
        let text = make().render()
        XCTAssertFalse(text.contains("text"))
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("/"))
    }

    func testAnEmptyEvaluationRendersExactly() {
        let e = Evaluation(appVersion: "1", macOS: "2", phasesFire: false, phasesMove: false, recording: "a.jsonl", started: "s",
                           lengthMs: 0, segments: 0, entriesByKind: [:], heightHistogram: [:], violations: [], window: [])
        XCTAssertEqual(e.render(), "app: 1\nmacOS: 2\nrecording: a.jsonl\nstarted: s\nlength: 0 ms\nphases: fire=false move=false\nsegments: 0\nentries:\nheights:\nviolations: 0\nwindow:")
    }
}
