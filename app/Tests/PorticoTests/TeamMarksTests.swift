import Foundation
import XCTest

@testable import Portico

/// Team knowledge on a file row (v0.27, Bill's ZJ4 and ZJ1): the mark's
/// hover in each state, what a click and the menu offer, and what they send.
@MainActor
final class TeamMarksTests: XCTestCase {
    private let priya = TeamPerson(name: "Priya Raman", short: "Priya")
    private let jordan = TeamPerson(name: "Jordan Okonkwo-Fitzwilliam", short: "Jordan")

    /// A fixed clock: every stamp reads as its own text, "today" is any stamp on the 17th.
    private func words(minutes: Int? = 9) -> TeamMarkPresentation.Words {
        TeamMarkPresentation.Words(
            time: { "t(\($0.dropFirst(11).prefix(5)))" },
            day: { "d(\($0.prefix(10)))" },
            isToday: { $0.hasPrefix("2026-11-17") },
            minutesUntil: { _ in minutes })
    }

    private func file(_ direction: TeamFile.Direction, _ change: (inout TeamFile) -> Void = { _ in }) -> TeamFile {
        var file = TeamFile(path: "_team/a.md", direction: direction, rev: "r-3", sharedBy: priya, sharedAt: "2026-11-10T09:00:00Z")
        change(&file)
        return file
    }

    private func state(_ files: [TeamFile] = [], reach: TeamState.Reach = .ok) -> TeamState {
        TeamState(
            reach: reach, lastOkAt: "2026-11-17T20:14:00Z", nextCheckAt: "2026-11-17T20:30:00Z", intervalMinutes: 15,
            files: files)
    }

    private func mark(_ file: TeamFile, reach: TeamState.Reach = .ok, minutes: Int? = 9) -> TeamMarkPresentation {
        TeamMarkPresentation.make(file, state: state(reach: reach), words: words(minutes: minutes))
    }

    func testEachStatesHover() {
        let out = mark(file(.out) { $0.sentAt = "2026-11-17T20:14:00Z" })
        XCTAssertEqual([out.icon, out.title, out.detail], ["arrow.up.right", "Shared with the team", "Since d(2026-11-10) · last sent today t(20:14)"])
        XCTAssertEqual(out.tone, .grey)

        let going = mark(file(.out) { $0.pending = .init(since: "2026-11-17T20:21:00Z") })
        XCTAssertEqual([going.title, going.detail], ["Goes to the team in 9 min", "Changed t(20:21) · click to send now or pause"])
        XCTAssertEqual(going.tone, .accent)
        XCTAssertEqual(going.click, .sendOrPause)
        XCTAssertEqual(mark(file(.out) { $0.pending = .init(since: "2026-11-17T20:21:00Z") }, minutes: nil).title,
                       "Goes to the team at the next check", "the check's time is past")

        let paused = mark(file(.out) {
            $0.paused = .init(since: "2026-11-17T20:24:00Z")
            $0.pending = .init(since: "2026-11-17T20:31:00Z")
        })
        XCTAssertEqual([paused.icon, paused.title, paused.detail],
                       ["pause", "Paused by you since t(20:24)", "Changes waiting since t(20:31) · click to resume"])
        XCTAssertEqual(paused.click, .resume)
        XCTAssertEqual(mark(file(.out) { $0.paused = .init(since: "2026-11-17T20:24:00Z") }).detail, "Nothing waiting · click to resume")

        let unread = mark(file(.in) {
            $0.unread = true
            $0.changedBy = jordan
            $0.changedAt = "2026-11-17T20:31:00Z"
        })
        XCTAssertEqual([unread.icon, unread.title, unread.detail],
                       ["arrow.down.left", "Changed by Jordan Okonkwo-Fitzwilliam", "Today t(20:31) · first shared by Priya, d(2026-11-10)"])
        XCTAssertEqual(unread.tone, .accent)

        let inStep = mark(file(.in) { $0.changedAt = "2026-11-12T10:00:00Z"; $0.changedBy = jordan })
        XCTAssertEqual([inStep.title, inStep.detail], ["From Priya Raman", "Shared d(2026-11-10) · last change d(2026-11-12)"])
        XCTAssertEqual(inStep.tone, .grey)

        let two = mark(file(.in) { $0.conflict = .init(id: "c-1", mine: .init(path: "_team/.mine/a.md", at: "2026-11-17T20:24:00Z")) })
        XCTAssertEqual([two.icon, two.title, two.detail],
                       ["doc.on.doc", "Your version and the team's differ", "Yours is saved on this Mac · open to choose"])
        XCTAssertEqual(two.tone, .wait)
        XCTAssertEqual(two.click, .open)
    }

    func testWhileTheTeamCannotBeReachedAHoverSaysWhenItWasLastChecked() {
        XCTAssertEqual(mark(file(.in), reach: .unreachable).detail, "Shared d(2026-11-10) · last checked today t(20:14)")
        XCTAssertEqual(mark(file(.out), reach: .refused).detail, "Since d(2026-11-10) · last checked today t(20:14)")
        XCTAssertEqual(mark(file(.out), reach: .unreachable).tone, .grey, "marks keep their colour")
    }

    func testTheMenuOffersOnlyWhatApplies() {
        XCTAssertEqual(TeamFileMenu.make(file(.out)), TeamFileMenu(sendNow: false, pause: true, resume: false, stop: true))
        XCTAssertEqual(TeamFileMenu.make(file(.out) { $0.pending = .init(since: "t") }).sendNow, true)
        let paused = TeamFileMenu.make(file(.out) { $0.paused = .init(since: "t"); $0.pending = .init(since: "t") })
        XCTAssertEqual(paused, TeamFileMenu(sendNow: false, pause: false, resume: true, stop: true), "a paused row offers Resume, not Send")
        let two = TeamFileMenu.make(file(.in) { $0.conflict = .init(id: "c", mine: .init(path: "m", at: "t")) })
        XCTAssertEqual(two, TeamFileMenu(sendNow: false, pause: false, resume: false, stop: true))
    }

    func testTheGeneralTabHasTheDeploymentsSectionOnlyWithTeamKnowledge() {
        XCTAssertEqual(GeneralSettingsPresentation.sectionTitles(capabilities: ["spaces.v1"], team: "Team knowledge"),
                       ["Folder", "Viewer", "Team knowledge", "Spaces"])
        XCTAssertEqual(GeneralSettingsPresentation.sectionTitles(capabilities: []), ["Folder", "Viewer"])
        XCTAssertEqual(GeneralSettingsPresentation.teamIntervalLabel(30), "30 min")
        XCTAssertEqual(GeneralSettingsPresentation.teamCheckNote(brand: "Acme"),
                       "How often Acme looks for changes from the team and sends yours. Send now on a file skips the wait.")
    }

    // MARK: - what a click sends

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model(_ files: [TeamFile]) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.teamDefaults = UserDefaults(suiteName: "team-marks-tests-\(UUID().uuidString)")!
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
        model.apply(.teamState(state(files)))
        return (model, sent)
    }

    func testARowIsFoundByItsPlaceOnThisMac() {
        let (model, _) = model([file(.in)])
        XCTAssertEqual(model.teamFile(at: "/Users/someone/work/_team/a.md")?.rev, "r-3")
        XCTAssertNil(model.teamFile(at: "/Users/someone/work/other.md"), "an ordinary file has no mark")
    }

    func testSendNowPauseResumeStopAndTheInterval() {
        let pending = file(.out) { $0.pending = .init(since: "t") }
        let (model, sent) = model([pending])
        model.teamSendNow(pending)
        guard case .teamSendNow(let now)? = sent.frames.last else { return XCTFail("expected team.send_now") }
        XCTAssertEqual(now.paths, ["_team/a.md"])
        XCTAssertNotNil(now.id)
        model.teamSetPaused(pending, true)
        guard case .teamSendingSet(let pause)? = sent.frames.last else { return XCTFail("expected team.sending.set") }
        XCTAssertTrue(pause.paused)
        model.teamStop(pending)
        guard case .teamStop(let stop)? = sent.frames.last else { return XCTFail("expected team.stop") }
        XCTAssertEqual(stop.paths, ["_team/a.md"])
        model.teamSetInterval(60)
        guard case .teamIntervalSet(let interval)? = sent.frames.last else { return XCTFail("expected team.interval.set") }
        XCTAssertEqual(interval.minutes, 60)
    }

    func testStopOnAFileWithTwoVersionsOpensItInsteadAndSaysWhy() {
        let two = file(.in) { $0.conflict = .init(id: "c-1", mine: .init(path: "_team/.mine/a.md", at: "t")) }
        let (model, sent) = model([two])
        let before = sent.frames.count
        model.teamStop(two)
        XCTAssertEqual(sent.frames.count, before, "nothing is sent: the person chooses first")
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/_team/a.md")
        let notices = (model.transcripts[1] ?? []).compactMap { if case .notice(_, let text) = $0 { text } else { nil } }
        XCTAssertEqual(notices, ["Team knowledge · Choose a version first"])
    }

    func testOpeningAnUnreadFileSaysWhichVersionWasOpened() {
        let (model, sent) = model([file(.in) { $0.unread = true }])
        model.teamOpened(absolutePath: "/Users/someone/work/_team/a.md")
        guard case .teamSeen(let seen)? = sent.frames.last else { return XCTFail("expected team.seen") }
        XCTAssertEqual([seen.path, seen.rev], ["_team/a.md", "r-3"])
    }
}
