import Foundation
import XCTest

@testable import Portico

/// The Files pane's Shared tab (v0.27, Bill's ZJ1): what it lists, in what order.
final class TeamSharedListTests: XCTestCase {
    private let priya = TeamPerson(name: "Priya Raman", short: "Priya")

    private func file(
        _ name: String, _ direction: TeamFile.Direction, unread: Bool = false, changedAt: String? = nil,
        sharedAt: String = "2026-11-10T09:00:00Z"
    ) -> TeamFile {
        var file = TeamFile(
            path: direction == .in ? "_team/\(name)" : "notes/\(name)", direction: direction, rev: "r-1", sharedBy: priya,
            sharedAt: sharedAt)
        file.unread = unread
        file.changedAt = changedAt
        return file
    }

    private func state(_ files: [TeamFile]) -> TeamState {
        TeamState(reach: .ok, nextCheckAt: "2026-11-17T20:45:00Z", intervalMinutes: 15, files: files)
    }

    func testFilesNotYetOpenedComeFirstThenTheLatestChange() {
        let list = TeamSharedList.make(state: state([
            file("staging-accounts.md", .in, changedAt: "2026-11-12T10:00:00Z"),
            file("review-template.md", .in),
            file("release-calendar.md", .in, unread: true, changedAt: "2026-11-17T20:31:00Z"),
            file("pricing-checklist.md", .in, unread: true, changedAt: "2026-11-17T21:00:00Z"),
            file("Research plan.md", .out),
            file("brand-voice.md", .out),
        ]))
        XCTAssertEqual(
            list.fromTeam.map(\.path),
            ["_team/pricing-checklist.md", "_team/release-calendar.md", "_team/staging-accounts.md", "_team/review-template.md"])
        XCTAssertEqual(list.newText, "2 new")
        XCTAssertEqual(list.fromYou.map(\.path), ["notes/Research plan.md", "notes/brand-voice.md"])
        XCTAssertNil(list.allText(folder: "_team"), "all of them show: no link")
    }

    func testALongListIsCutWithALinkToTheFolderAndAFilterSearchesAllOfIt() {
        let many = (1...38).map { file(String(format: "file-%02d.md", $0), .in) }
        let list = TeamSharedList.make(state: state(many))
        XCTAssertEqual(list.fromTeam.count, TeamSharedList.fromTeamMax)
        XCTAssertEqual(list.allText(folder: "_team"), "All 38 in _team")
        XCTAssertNil(list.newText)
        let found = TeamSharedList.make(state: state(many), filter: "file-3")
        XCTAssertEqual(found.fromTeam.count, 9, "file-30 to file-38: the filter is not cut")
    }

    func testNothingSharedIsItsOwnState() {
        XCTAssertTrue(TeamSharedList.make(state: state([])).isEmpty)
        XCTAssertTrue(TeamSharedList.make(state: nil).isEmpty)
        XCTAssertEqual(TeamSharedList.emptyTitle, "Nothing shared yet.")
    }
}
