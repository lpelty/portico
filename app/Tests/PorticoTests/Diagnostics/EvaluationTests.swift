import CoreGraphics
import XCTest

@testable import Portico

/// v0.26.4 (D10): the one artefact that leaves the machine; text with counts and opaque ids only.
final class EvaluationTests: XCTestCase {
    private func make() -> Evaluation {
        let r = Reading(step: 7, input: .wheel(deltaY: -40, precise: true, phase: 4, momentum: 0), offset: 1234.4,
                        documentHeight: 9000.6, clip: CGRect(x: 0, y: 1234, width: 600, height: 800),
                        rowsInView: [RowInView(id: "assistant:ZEBRA", kind: .reply, height: 120, minY: 1200,
                                               shape: EntryShape(id: "assistant:ZEBRA", kind: .reply, paragraphs: [300, 12], codeBlocks: [4],
                                                                 tables: [[3, 2]])),
                                     RowInView(id: "user:Q", kind: .person, height: 40, minY: 1320,
                                               shape: EntryShape(id: "user:Q", kind: .person, images: [[160, 90]])),
                                     RowInView(id: "tool-run:t", kind: .toolRun, height: 30, minY: 1360,
                                               shape: EntryShape(id: "tool-run:t", kind: .toolRun, toolRows: 3, folded: true))],
                        phase: .decelerating, settledReadings: [], hasRows: true)
        let quiet = Reading(step: 8, input: .key(.pageUp), offset: 0, documentHeight: 10, clip: CGRect(x: 0, y: 0, width: 5, height: 5),
                            rowsInView: [], phase: .idle, settledReadings: [], hasRows: true, note: "key-not-moved")
        return Evaluation(appVersion: "0.26.4", macOS: "27.0", phasesFire: true, phasesMove: false,
                          recording: "/Users/someone/recordings/12-2026-11-10T21-05-00.250Z.jsonl", started: "2026-11-10T21:05:00Z", lengthMs: 4200,
                          segments: 2, entriesByKind: [.reply: 30, .person: 30, .tool: 4],
                          heightHistogram: [150: 3, 0: 12],
                          violations: [Violation(rule: .pastEnd, step: 7, detail: "clip.maxY 9100 > doc 9000")],
                          window: [r, quiet], steps: 9, keysStepped: 2, keysMoved: 1,
                          skipped: ["removed": 3, "capped": 1], envelope: "on (2 gesture runs)")
    }

    func testRenderCarriesHeaderHistogramViolationsAndWindowWithoutContent() {
        let lines = make().render().components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(11)), [
            "verdict: red",
            "app: 0.26.4", "macOS: 27.0", "recording: 12-2026-11-10T21-05-00.250Z.jsonl",
            "started: 2026-11-10T21:05:00Z", "length: 4200 ms", "phases: fire=true move=false", "envelope: on (2 gesture runs)",
            "textScale: 1.0 applied", "truncated: 0", "segments: 2",
        ])
        XCTAssertEqual(Array(lines[11...]), [
            "steps: 9", "keys: 2 stepped, 1 moved", "wheels: 0 with room, 0 moved", "skipped: capped 1, removed 3",
            "entries:", "person: 30", "reply: 30", "tool: 4",
            "heights:", "0-49: 12", "150-199: 3",
            "violations: 1", "per segment: 1=1", "per rule: pastEnd=1", "step 1.7 pastEnd: clip.maxY 9100 > doc 9000",
            "window:",
            "step 1.7 input=wheel(deltaY=-40.0 precise=true phase=changed) offset=1234 doc=9001 clip=1234..2034 phase=decelerating "
                + "rows=[assistant:ZEBRA:reply:120{paragraphs=[300,12] code=[4] tables=[[3,2]]},user:Q:person:40{images=[[160,90]]},tool-run:t:toolRun:30{toolRows=3}]",
            "step 1.8 input=key(pageUp) offset=0 doc=10 clip=0..5 phase=idle rows=[] note=key-not-moved",
        ])
    }

    /// I8 (Ruling 17): the first line is the verdict Daedalus acts on.
    func testTheVerdictIsRedGreenOrInconclusiveWithItsReason() {
        func e(_ change: (inout Evaluation) -> Void) -> String {
            var x = Evaluation(appVersion: "1", macOS: "2", phasesFire: true, phasesMove: true, recording: "a.jsonl", started: "s",
                               lengthMs: 0, segments: 1, entriesByKind: [:], heightHistogram: [:], violations: [], window: [], steps: 20)
            change(&x)
            return x.render().components(separatedBy: "\n")[0]
        }
        XCTAssertEqual(e { _ in }, "verdict: green")
        XCTAssertEqual(e { $0.violations = [Violation(rule: .wheelMoves, step: 3, detail: "d")]; $0.keysStepped = 1 }, "verdict: red",
                       "violations are red, whatever else")
        XCTAssertEqual(e { $0.keysStepped = 2; $0.keysMoved = 1 }, "verdict: inconclusive (1 of 2 key steps did not move the view)")
        XCTAssertEqual(e { $0.textScale = 1.3; $0.textScaleApplied = false }, "verdict: inconclusive (text scale 1.3 not applied)")
        XCTAssertEqual(e { $0.textScale = 1.3 }, "verdict: green", "a text scale applied")
        XCTAssertEqual(e { $0.placesNotRestored = 1 }, "verdict: inconclusive (1 scrolled-up place not restored)")
        XCTAssertEqual(e { $0.envelope = "off (phases did not fire)" }, "verdict: inconclusive (the envelope's phases did not fire)")
        XCTAssertEqual(e { $0.skipped = ["viewer": 2, "shape": 40] }, "verdict: green", "2 of 20: not over a tenth; re-shapes are not inputs")
        XCTAssertEqual(e { $0.skipped = ["viewer": 2, "sidebar": 1] }, "verdict: inconclusive (3 inputs skipped of 20 steps)")
        XCTAssertEqual(e { $0.keysStepped = 1; $0.envelope = "off (phases did not fire)" },
                       "verdict: inconclusive (1 of 1 key steps did not move the view; the envelope's phases did not fire)")
    }

    /// I5: each input renders with its fields.
    func testInputsRenderWithTheirFields() {
        let cases: [(RecordingEvent?, String)] = [
            (nil, "none"),
            (.wheel(deltaY: -120, precise: true, phase: 4, momentum: 0), "wheel(deltaY=-120.0 precise=true phase=changed)"),
            (.wheel(deltaY: 0.4, precise: false, phase: 0, momentum: 2), "wheel(deltaY=0.4 precise=false phase=none momentum=stationary)"),
            (.key(.pageUp), "key(pageUp)"), (.column(width: 620), "column(620)"), (.window(width: 900, height: 700), "window(900x700)"),
            (.jump(id: "user:3"), "jump(user:3)"), (.delta(turn: 31, chars: 120), "delta(turn=31 chars=120)"),
            (.shape(EntryShape(id: "assistant:31", kind: .reply)), "shape(assistant:31:reply)"), (.turnFinished(turn: 31), "turnFinished(31)"),
            (.textScale(1.25), "textScale(1.25)"), (.sidebar(visible: false), "sidebar(visible=false)"),
            (.viewer(visible: true, width: 400, shown: "local-1"), "viewer(visible=true width=400)"),
        ]
        for (event, text) in cases { XCTAssertEqual(Evaluation.render(input: event), text) }
    }

    /// I5: the violations list stops at 20, says how many more, and counts each rule.
    func testViolationsAreCappedAtTwentyWithCounts() {
        var e = make()
        e.violations = (0..<23).map { Violation(rule: $0 < 21 ? .wheelMoves : .pastEnd, step: $0, detail: "d") }
        let lines = e.render().components(separatedBy: "\n")
        let start = try! XCTUnwrap(lines.firstIndex(of: "violations: 23"))
        XCTAssertEqual(lines[start + 1], "per segment: 1=23")
        XCTAssertEqual(lines[start + 2], "per rule: pastEnd=2, wheelMoves=21")
        XCTAssertEqual(lines[start + 3], "step 1.0 wheelMoves: d")
        XCTAssertEqual(lines[start + 22], "step 1.19 wheelMoves: d")
        XCTAssertEqual(lines[start + 23], "… and 3 more")
        XCTAssertEqual(lines[start + 24], "window:")
    }

    func testRenderHasNoContentKeys() {
        let text = make().render()
        // The one header named for the text scale (I8, `textScale: X applied`) aside, no "text" anywhere.
        XCTAssertEqual(text.components(separatedBy: "textScale").count, 2, "the header only")
        XCTAssertFalse(text.replacingOccurrences(of: "\ntextScale: ", with: "\n").contains("text"))
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("/"))
    }

    func testAnEmptyEvaluationRendersExactly() {
        let e = Evaluation(appVersion: "1", macOS: "2", phasesFire: false, phasesMove: false, recording: "a.jsonl", started: "s",
                           lengthMs: 0, segments: 0, entriesByKind: [:], heightHistogram: [:], violations: [], window: [])
        XCTAssertEqual(e.render(), "verdict: green\napp: 1\nmacOS: 2\nrecording: a.jsonl\nstarted: s\nlength: 0 ms\nphases: fire=false move=false\nenvelope: on (0 gesture runs)\ntextScale: 1.0 applied\ntruncated: 0\nsegments: 0\nsteps: 0\nkeys: 0 stepped, 0 moved\nwheels: 0 with room, 0 moved\nskipped: none\nentries:\nheights:\nviolations: 0\nwindow:")
    }
}
