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
                rowsInView: rows ?? [row], phase: .idle, settledReadings: settled, hasRows: hasRows)
    }

    func testAlternationIsCaughtAndNamedWithTheStep() {
        let v = Invariants.check([reading(6), reading(7, settled: [3850, 4050, 3850, 4050, 3850])])
        XCTAssertEqual(v.map(\.rule), [.alternation])
        XCTAssertEqual(v.first?.step, 7)
        XCTAssertTrue(v[0].detail.contains("3850") && v[0].detail.contains("4050") && v[0].detail.contains("4 times"))
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
        // The wrong way (the offset grew with a positive delta) is a violation too.
        XCTAssertEqual(Invariants.check([reading(1, offset: 500), reading(2, input: wheel, offset: 600)]).map(\.rule), [.wheelMoves])
        // Moved against the delta, within tolerance: fine.
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: wheel, offset: 404)]).isEmpty)
        // Started at the top, pushed further into it.
        XCTAssertTrue(Invariants.check([reading(1, offset: 0), reading(2, input: wheel, offset: 0)]).isEmpty)
        // I1: started at the bottom (5000 - 800 = 4200), a wheel up (positive) must move: checked.
        XCTAssertEqual(Invariants.check([reading(1, offset: 4200), reading(2, input: wheel, offset: 4200)]).map(\.rule), [.wheelMoves])
        // Not a wheel: no rule.
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: .phase(.idle), offset: 500)]).isEmpty)
    }

    /// I1: the expected movement is clamped to the document; only a wheel pushing into the
    /// end the view is already at is exempt (at the top with a positive delta, at the bottom
    /// with a negative one; positive is toward the top, ruling 10).
    func testAWheelAtAnEndIsExemptOnlyWhenItPushesIntoThatEnd() {
        func wheel(_ dy: Double) -> RecordingEvent { .wheel(deltaY: dy, precise: true, phase: 0, momentum: 0) }
        // At the bottom (4200): a negative delta pushes into it, no movement is fine.
        XCTAssertTrue(Invariants.check([reading(1, offset: 4200), reading(2, input: wheel(-100), offset: 4200)]).isEmpty)
        // At the bottom: a positive delta is checked; it moved up by it, clean; it did not move, a violation.
        XCTAssertTrue(Invariants.check([reading(1, offset: 4200), reading(2, input: wheel(100), offset: 4100)]).isEmpty)
        let stuck = Invariants.check([reading(1, offset: 4200), reading(2, input: wheel(100), offset: 4200)])
        XCTAssertEqual(stuck.map(\.rule), [.wheelMoves])
        XCTAssertEqual(stuck.first?.detail, "wheel delta 100 moved the offset 0, expected -100")
        // A wheel up from the bottom snapped back (moved 100, then put back to 4196): a violation.
        XCTAssertEqual(Invariants.check([reading(1, offset: 4200), reading(2, input: wheel(100), offset: 4196)]).map(\.rule), [.wheelMoves])
        // A wheel up that lands at the top partway: 120 asked, 30 moved, clean (clamped).
        XCTAssertTrue(Invariants.check([reading(1, offset: 30), reading(2, input: wheel(120), offset: 0)]).isEmpty)
        // ... but stopping short of the top is not.
        XCTAssertEqual(Invariants.check([reading(1, offset: 30), reading(2, input: wheel(120), offset: 20)]).map(\.rule), [.wheelMoves])
        // A wheel down that lands at the bottom partway: 150 asked, 50 moved, clean.
        XCTAssertTrue(Invariants.check([reading(1, offset: 4150), reading(2, input: wheel(-150), offset: 4200)]).isEmpty)
        // At the top, a negative delta is checked.
        XCTAssertEqual(Invariants.check([reading(1, offset: 0), reading(2, input: wheel(-100), offset: 0)]).map(\.rule), [.wheelMoves])
        // A line wheel up from the bottom that did not move: a violation (Ruling 12 still checks its direction).
        let lineUp = RecordingEvent.wheel(deltaY: 1, precise: false, phase: 0, momentum: 0)
        XCTAssertEqual(Invariants.check([reading(1, offset: 4200), reading(2, input: lineUp, offset: 4200)]).map(\.rule), [.wheelMoves])
        let lineDown = RecordingEvent.wheel(deltaY: -1, precise: false, phase: 0, momentum: 0)
        XCTAssertTrue(Invariants.check([reading(1, offset: 4200), reading(2, input: lineDown, offset: 4200)]).isEmpty)
    }

    /// Ruling 12: a line wheel (`precise == false`) is in lines, so only its direction and
    /// some movement are checked, never the magnitude.
    func testALineWheelIsCheckedByDirectionAndMovementOnly() {
        let up = RecordingEvent.wheel(deltaY: 1, precise: false, phase: 0, momentum: 0)
        let down = RecordingEvent.wheel(deltaY: -0.4, precise: false, phase: 0, momentum: 0)
        // One line moved 10 pt (or 40): toward the top, so the offset falls. No violation.
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: up, offset: 490)]).isEmpty)
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: up, offset: 460)]).isEmpty)
        XCTAssertTrue(Invariants.check([reading(1, offset: 500), reading(2, input: down, offset: 504)]).isEmpty)
        // The wrong way, or not at all: a violation.
        XCTAssertEqual(Invariants.check([reading(1, offset: 500), reading(2, input: up, offset: 510)]).map(\.rule), [.wheelMoves])
        XCTAssertEqual(Invariants.check([reading(1, offset: 500), reading(2, input: down, offset: 500)]).map(\.rule), [.wheelMoves])
        XCTAssertEqual(Invariants.check([reading(1, offset: 500), reading(2, input: down, offset: 499.5)]).map(\.rule), [.wheelMoves])
        // At an end: exempt, as for a precise wheel.
        XCTAssertTrue(Invariants.check([reading(1, offset: 0), reading(2, input: up, offset: 0)]).isEmpty)
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
        let run = [reading(1, offset: 500), reading(2, input: wheel, offset: 400, settled: [5000, 5000]),
                   reading(3, input: wheel, offset: 300)]
        XCTAssertEqual(Invariants.check(run), [])
    }
}
