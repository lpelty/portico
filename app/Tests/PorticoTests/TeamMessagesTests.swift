import XCTest

@testable import Portico

/// Team knowledge (v0.27): the one mark a row shows is derived from separate facts, in the protocol's order.
final class TeamMessagesTests: XCTestCase {
    private func file(
        _ direction: TeamFile.Direction = .out, unread: Bool = false, pending: Bool = false, paused: Bool = false,
        conflict: Bool = false
    ) -> TeamFile {
        let who = TeamPerson(name: "Priya Raman", short: "Priya")
        return TeamFile(
            path: "a.md", direction: direction, rev: "r-1", sharedBy: who, sharedAt: "2026-11-17T20:00:00Z",
            unread: unread,
            pending: pending ? .init(since: "2026-11-17T20:21:00Z") : nil,
            paused: paused ? .init(since: "2026-11-17T20:24:00Z") : nil,
            conflict: conflict ? .init(id: "c-1", mine: .init(path: ".mine/a.md", at: "2026-11-17T20:24:00Z")) : nil)
    }

    func testTheMarkFollowsTheProtocolsOrder() {
        XCTAssertEqual(file(.in).mark, .inStep(.in))
        XCTAssertEqual(file(.out).mark, .inStep(.out))
        XCTAssertEqual(file(unread: true).mark, .unread)
        XCTAssertEqual(file(unread: true, pending: true).mark, .goingOut)
        XCTAssertEqual(file(unread: true, pending: true, paused: true).mark, .paused)
        XCTAssertEqual(file(unread: true, pending: true, paused: true, conflict: true).mark, .twoVersions)
    }

    func testAPauseSurvivesAConflictInTheFacts() {
        // Clara's finding: the mark may hide the pause, the facts must not.
        let row = file(paused: true, conflict: true)
        XCTAssertEqual(row.mark, .twoVersions)
        XCTAssertNotNil(row.paused)
    }

    func testTwoVersionsIsCountedFromTheRows() {
        let state = TeamState(
            reach: .ok, nextCheckAt: "2026-11-17T20:30:00Z", intervalMinutes: 15,
            files: [file(conflict: true), file(.in), file(.in, conflict: true)])
        XCTAssertEqual(state.twoVersions, 2)
    }

    func testARowWithoutItsDefaultsStillDecodes() throws {
        let row = try JSONDecoder().decode(
            TeamFile.self,
            from: Data(#"{"path":"a.md","direction":"in","rev":"r","shared_by":{"name":"A B","short":"A"},"shared_at":"t"}"#.utf8))
        XCTAssertFalse(row.unread)
        XCTAssertNil(row.pending)
    }
}
