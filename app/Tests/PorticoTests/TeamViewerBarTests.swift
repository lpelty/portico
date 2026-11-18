import Foundation
import XCTest

@testable import Portico

/// The team bar over the viewer (v0.27, Bill's ZJ6 and ZJ1): two versions
/// with the choice, and a change that arrived by itself.
@MainActor
final class TeamViewerBarTests: XCTestCase {
    private let priya = TeamPerson(name: "Priya Raman", short: "Priya")
    private let words = TeamMarkPresentation.Words(
        time: { "t(\($0.dropFirst(11).prefix(5)))" }, day: { "d(\($0.prefix(10)))" },
        isToday: { $0.hasPrefix("2026-11-17") }, minutesUntil: { _ in 9 })

    private func file(_ change: (inout TeamFile) -> Void = { _ in }) -> TeamFile {
        var file = TeamFile(path: "notes/plan.md", direction: .out, rev: "r-3", sharedBy: priya, sharedAt: "2026-11-10T09:00:00Z")
        file.changedBy = priya
        file.changedAt = "2026-11-17T20:31:00Z"
        change(&file)
        return file
    }

    private func conflicted() -> TeamFile {
        file { $0.conflict = .init(id: "c-7", mine: .init(path: "_team/.mine/plan.md", at: "2026-11-17T20:24:00Z")) }
    }

    private func state(_ files: [TeamFile]) -> TeamState {
        TeamState(reach: .ok, nextCheckAt: "2026-11-17T20:45:00Z", intervalMinutes: 15, files: files)
    }

    func testTwoVersionsSaysWhichOneIsBeingRead() throws {
        let team = try XCTUnwrap(TeamViewerBar.make(path: "notes/plan.md", state: state([conflicted()]), words: words))
        XCTAssertEqual(team.kind, .twoVersions(readingMine: false))
        XCTAssertEqual(
            team.text,
            "This file has two versions. You are reading the team's version (Priya, t(20:31)). "
                + "Your version (t(20:24)) was not sent and is saved on this Mac.")
        let mine = try XCTUnwrap(TeamViewerBar.make(path: "_team/.mine/plan.md", state: state([conflicted()]), words: words))
        XCTAssertEqual(mine.kind, .twoVersions(readingMine: true))
        XCTAssertEqual(mine.file.path, "notes/plan.md", "the saved version's bar is about the same row")
    }

    func testAChangeThatArrivedByItselfIsSaidOnlyWhileItsSummaryIsKept() throws {
        let changed = try XCTUnwrap(TeamViewerBar.make(
            path: "notes/plan.md", state: state([file { $0.summary = "_team/_summary.md" }]), words: words))
        XCTAssertEqual(changed.kind, .changed)
        XCTAssertEqual(changed.text, "Priya changed this file today at t(20:31). It updated here by itself.")
        XCTAssertNil(TeamViewerBar.make(path: "notes/plan.md", state: state([file()]), words: words), "no summary kept: no bar")
        XCTAssertNil(TeamViewerBar.make(path: "other.md", state: state([conflicted()]), words: words), "an ordinary file has no bar")
        XCTAssertNil(TeamViewerBar.make(path: "notes/plan.md", state: nil, words: words))
    }

    // MARK: - the choice

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.teamDefaults = UserDefaults(suiteName: "team-bar-tests-\(UUID().uuidString)")!
        model.setConnection(.connected)
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.27.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [],
            roots: [Root(name: "work", path: "/Users/someone/work")], commands: [], capabilities: [])
        hello.team = TeamHello(label: "Team knowledge", folder: "_team", intervals: [15, 30, 60])
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-17T12:00:00Z"),
        ])))
        model.selected = 1
        model.apply(.teamState(state([conflicted()])))
        return (model, sent)
    }

    func testCompareGoesToTheOtherVersionAndBack() throws {
        let (model, _) = model()
        model.teamOpen("notes/plan.md")
        var bar = try XCTUnwrap(model.teamViewerBar(chat: 1))
        XCTAssertEqual(bar.kind, .twoVersions(readingMine: false))
        model.teamCompare(bar)
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/_team/.mine/plan.md")
        bar = try XCTUnwrap(model.teamViewerBar(chat: 1))
        XCTAssertEqual(bar.kind, .twoVersions(readingMine: true))
        model.teamCompare(bar)
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/notes/plan.md")
    }

    func testTheChoiceNamesTheConflictThePersonSaw() throws {
        let (model, sent) = model()
        model.teamOpen("_team/.mine/plan.md")
        let bar = try XCTUnwrap(model.teamViewerBar(chat: 1))
        model.teamResolve(bar.file, use: .mine)
        guard let resolve = sent.frames.compactMap({ if case .teamResolve(let r) = $0 { r } else { nil } }).last
        else { return XCTFail("expected team.resolve") }
        XCTAssertEqual([resolve.path, resolve.conflict], ["notes/plan.md", "c-7"])
        XCTAssertEqual(resolve.use, .mine)
        XCTAssertNotNil(resolve.id)
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/notes/plan.md", "the file at its own place is what remains")
    }
}
