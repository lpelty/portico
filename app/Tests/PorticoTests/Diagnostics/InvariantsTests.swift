import CoreGraphics
import XCTest

@testable import Portico

/// v0.26.4 (D9): the replay invariants, each one the shape a field log already showed.
final class InvariantsTests: XCTestCase {
    private let row = RowInView(id: "assistant:A", kind: .reply, height: 100, minY: 0)

    private func reading(_ step: Int, input: RecordingEvent? = nil, offset: Double = 500, doc: Double = 5000,
                         clip: CGRect? = nil, rows: [RowInView]? = nil, hasRows: Bool = true,
                         settled: [Double] = []) -> Reading {
        Reading(step: step, input: input, offset: offset, documentHeight: doc,
                clip: clip ?? CGRect(x: 0, y: offset, width: 600, height: 800),
                rowsInView: rows ?? [row], phase: "idle", settledReadings: settled, hasRows: hasRows)
    }

    func testAlternationIsCaughtAndNamedWithTheStep() {
        let v = Invariants.check([reading(6), reading(7, settled: [3850, 4050, 3850, 4050, 3850])])
        XCTAssertEqual(v.map(\.rule), [.alternation])
        XCTAssertEqual(v.first?.step, 7)
        XCTAssertTrue(v[0].detail.contains("3850") && v[0].detail.contains("4050") && v[0].detail.contains("5"))
    }

    func testAlternationNeedsFourAndARealGap() {
        XCTAssertTrue(Invariants.check([reading(1, settled: [3850, 4050, 3850])]).isEmpty)
        XCTAssertTrue(Invariants.check([reading(1, settled: [3850, 3850.4, 3850, 3850.4, 3850])]).isEmpty)
        XCTAssertEqual(Invariants.check([reading(1, settled: [3850, 4050, 3850, 4050])]).map(\.rule), [.alternation])
    }

    func testAWheelThatDoesNotMoveIsAViolationUnlessAtAnEnd() {
        let wheel = RecordingEvent.wheel(deltaY: 100, precise: true, phase: 0, momentum: 0)
        let stuck = Invariants.check([reading(1, offset: 500), reading(2, input: wheel, offset: 500)])
        XCTAssertEqual(stuck.map(\.rule), [.wheelMoves])
        XCTAssertEqual(stuck.first?.step, 2)
        // Within tolerance: fine.
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: wheel, offset: 596)]).isEmpty)
        // Started at the top.
        XCTAssertTrue(Invariants.check([reading(1, offset: 0), reading(2, input: wheel, offset: 0)]).isEmpty)
        // Started at the bottom (5000 - 800 = 4200).
        XCTAssertTrue(Invariants.check([reading(1, offset: 4200), reading(2, input: wheel, offset: 4200)]).isEmpty)
        // Not a wheel: no rule.
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: .phase(.idle), offset: 500)]).isEmpty)
    }

    func testNoRowsInViewIsAViolation() {
        XCTAssertEqual(Invariants.check([reading(3, rows: [])]).map(\.rule), [.rowsInView])
        XCTAssertTrue(Invariants.check([reading(3, rows: [], hasRows: false)]).isEmpty)
    }

    func testPastEndUsesTheBlankSpaceSlack() {
        XCTAssertEqual(Invariants.pastEndSlack, TranscriptBlankSpace.slack)
        let at = reading(1, offset: 4200.5, doc: 5000)   // maxY 5000.5: inside the slack
        let past = reading(2, offset: 4202, doc: 5000)   // maxY 5002
        XCTAssertTrue(Invariants.check([at]).isEmpty)
        XCTAssertEqual(Invariants.check([past]).map(\.rule), [.pastEnd])
    }

    func testEstimateDriftAboveAQuarterIsAViolationOnlyWithoutNewContent() {
        let a = reading(1, doc: 5000), b = reading(2, input: .phase(.idle), doc: 6300)
        XCTAssertEqual(Invariants.check([a, b]).map(\.rule), [.estimateDrift])
        XCTAssertEqual(Invariants.check([a, b]).first?.step, 2)
        // Exactly a quarter is not above it.
        XCTAssertTrue(Invariants.check([a, reading(2, doc: 6250)]).isEmpty)
        for input in [RecordingEvent.delta(turn: 1, chars: 5), .shape(EntryShape(id: "x", kind: .reply)),
                      .imageLoaded(id: "x", index: 0, height: 10), .removed(id: "x")] {
            XCTAssertTrue(Invariants.check([a, reading(2, input: input, doc: 6300)]).isEmpty, "\(input)")
            XCTAssertTrue(Invariants.check([reading(1, input: input, doc: 5000), reading(2, doc: 6300)]).isEmpty, "\(input)")
        }
    }

    func testACleanRunHasNoViolations() {
        let wheel = RecordingEvent.wheel(deltaY: 100, precise: true, phase: 0, momentum: 0)
        let run = [reading(1, offset: 500), reading(2, input: wheel, offset: 600, settled: [5000, 5000]),
                   reading(3, input: wheel, offset: 700)]
        XCTAssertEqual(Invariants.check(run), [])
    }
}
