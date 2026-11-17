import Foundation
import XCTest

@testable import Portico

/// Team knowledge in the strip (v0.27, Bill's ZJ3): what each notice says,
/// how the notices fold as the strip narrows, and what a click sends.
@MainActor
final class TeamStripTests: XCTestCase {
    private let priya = TeamPerson(name: "Priya Raman", short: "Priya")
    private let sam = TeamPerson(name: "Sam Ortiz", short: "Sam")
    private let hello = TeamHello(label: "Team knowledge", folder: "_team", intervals: [15, 30, 60])

    private func state(
        reach: TeamState.Reach = .ok, waiting: [TeamShare] = [], getting: [String]? = nil, latest: TeamLatest? = nil,
        files: [TeamFile] = []
    ) -> TeamState {
        TeamState(
            reach: reach, reachReason: reach == .ok ? nil : "The team source did not answer.",
            lastOkAt: "2026-11-17T20:00:00Z", nextCheckAt: "2026-11-17T20:30:00Z", intervalMinutes: 15,
            waiting: waiting, getting: getting, latest: latest, files: files)
    }

    private func strip(_ state: TeamState, quietGone: String? = nil) -> TeamStripPresentation {
        TeamStripPresentation.make(state: state, team: hello, quietGone: quietGone) { _ in "2:31 PM" }
    }

    private func share(_ id: String, _ by: TeamPerson, _ files: [String], note: String? = nil) -> TeamShare {
        TeamShare(id: id, by: by, files: files, note: note)
    }

    private func changed(_ by: [TeamPerson], _ files: [String], id: String = "a-2") -> TeamLatest {
        TeamLatest(id: id, kind: .changed, at: "2026-11-17T20:31:00Z", summary: "_team/_summary.md", files: files, by: by)
    }

    private func conflicted(_ path: String) -> TeamFile {
        TeamFile(
            path: path, direction: .in, rev: "r-2", sharedBy: priya, sharedAt: "2026-11-17T20:00:00Z",
            conflict: .init(id: "c-1", mine: .init(path: "_team/.mine/a.md", at: "2026-11-17T20:24:00Z")))
    }

    // MARK: - words

    func testNothingShowsWithoutHelloTeamOrBeforeASnapshot() {
        XCTAssertTrue(TeamStripPresentation.make(state: nil, team: hello, quietGone: nil).notices.isEmpty)
        let waiting = state(waiting: [share("s-1", priya, ["a.md"])])
        XCTAssertTrue(TeamStripPresentation.make(state: waiting, team: nil, quietGone: nil).notices.isEmpty)
        XCTAssertTrue(strip(state()).notices.isEmpty, "in step: the strip says nothing")
    }

    func testTheGetNoticeCountsFilesAndNamesPeopleByFirstName() {
        let one = strip(state(waiting: [share("s-1", priya, ["Research plan.md", "interview-guide.md"], note: "For Thursday")]))
        XCTAssertEqual(one.notices.map(\.kind), [.get])
        XCTAssertEqual(one.notices[0].full, "Team knowledge · 2 new from Priya")
        XCTAssertEqual(one.notices[0].short, "2 new from team")
        XCTAssertEqual(one.notices[0].button, "Get")
        XCTAssertEqual(one.notices[0].helpDetail, "Research plan.md, interview-guide.md · click to get\n“For Thursday”")

        let two = strip(state(waiting: [share("s-1", priya, ["a.md", "b.md"]), share("s-2", sam, ["c.md"])]))
        XCTAssertEqual(two.notices[0].full, "Team knowledge · 3 new from Priya and Sam")
        let third = TeamPerson(name: "Ana Ruiz", short: "Ana")
        let three = strip(state(waiting: [
            share("s-1", priya, ["a.md", "b.md"]), share("s-2", sam, ["c.md"]), share("s-3", third, ["d.md", "e.md"]),
        ]))
        XCTAssertEqual(three.notices[0].full, "Team knowledge · 5 new from 3 people")
    }

    func testGettingKeepsThePlaceAndLosesTheButton() {
        let getting = strip(state(waiting: [share("s-1", priya, ["a.md", "b.md"])], getting: ["s-1"]))
        XCTAssertEqual(getting.notices.map(\.kind), [.getting])
        XCTAssertEqual(getting.notices[0].full, "Getting 2 files…")
        XCTAssertNil(getting.notices[0].button)
    }

    func testTheQuietLineForAnArrival() {
        let new = TeamLatest(
            id: "a-1", kind: .new, at: "2026-11-17T20:31:00Z", summary: "_team/_summary.md",
            files: ["_team/a.md", "_team/b.md"], shares: [share("s-1", priya, ["_team/a.md", "_team/b.md"])])
        let ready = strip(state(latest: new)).notices[0]
        XCTAssertEqual(ready.full, "2 new files from Priya are ready")
        XCTAssertEqual(ready.link, "See what's new")
        XCTAssertNil(ready.button)

        let one = strip(state(latest: changed([priya], ["_team/a.md"]))).notices[0]
        XCTAssertEqual(one.full, "Priya changed 1 file · 2:31 PM")
        XCTAssertEqual(one.link, "See what changed")
        XCTAssertEqual(one.short, "1 team change")
        XCTAssertEqual(one.helpDetail, "a.md", "the line never carries a file name; the hover lists them")
        let several = strip(state(latest: changed([priya, sam], ["_team/a.md", "_team/b.md", "_team/c.md"]))).notices[0]
        XCTAssertEqual(several.full, "3 team changes · 2:31 PM")
    }

    func testTwoVersionsAndUnreachableNeedThePerson() {
        let two = strip(state(files: [conflicted("_team/a.md")])).notices[0]
        XCTAssertEqual([two.full, two.button, two.helpDetail], ["1 file has two versions", "Review", "a.md · click to review"])
        let both = strip(state(files: [conflicted("_team/a.md"), conflicted("_team/b.md")])).notices[0]
        XCTAssertEqual(both.full, "2 files have two versions")

        let down = strip(state(reach: .unreachable)).notices[0]
        XCTAssertEqual([down.full, down.button], ["Can't reach team knowledge", "Try again"])
        XCTAssertEqual(down.helpDetail, "The team source did not answer. · Last checked 2:31 PM")
        XCTAssertEqual(strip(state(reach: .refused)).notices.map(\.kind), [.unreachable])
    }

    func testTheQuietLineShowsBesideANoticeThatNeedsThePersonAndLeavesOnceGone() {
        let busy = state(
            waiting: [share("s-1", priya, ["a.md"])], latest: changed([sam], ["_team/b.md"]),
            files: [conflicted("_team/c.md")])
        XCTAssertEqual(strip(busy).notices.map(\.kind), [.latest, .twoVersions, .get])
        XCTAssertEqual(strip(busy, quietGone: "a-2").notices.map(\.kind), [.twoVersions, .get])
        XCTAssertEqual(strip(busy, quietGone: "a-1").notices.map(\.kind), [.latest, .twoVersions, .get], "a newer arrival shows again")
    }

    // MARK: - fit

    func testTheRestOfTheStripShortensFirstThenTheQuietLineThenTheWords() {
        let metrics = StatusStripPresentation.Metrics(text: { CGFloat($0.count * 7) }, symbol: { $0.size + 2 })
        var base = AppModel().statusStrip(gateway: .running(port: 1))
        base.modelText = "Claude Opus 5.5"
        let team = strip(state(waiting: [share("s-1", priya, ["a.md", "b.md"])], latest: changed([sam], ["_team/b.md"])))
        func layout(_ width: CGFloat) -> StatusStripPresentation.Layout {
            base.layout(width: width, restart: false, update: nil, team: team, metrics: metrics)
        }
        func needs(_ fit: StatusStripPresentation.Fit, _ teamFit: TeamStripPresentation.Fit) -> CGFloat {
            base.width(at: fit, restart: false, update: nil, team: team.widths(at: teamFit, metrics: metrics), metrics: metrics)
        }
        XCTAssertEqual(layout(needs(.full, .full)), .init(fit: .full, restartWords: true, team: .full))
        XCTAssertEqual(layout(needs(.full, .full) - 1), .init(fit: .compact, restartWords: true, team: .full))
        XCTAssertEqual(layout(needs(.minimal, .full) - 1), .init(fit: .minimal, restartWords: true, team: .quietIcon))
        XCTAssertEqual(layout(needs(.minimal, .quietIcon) - 1), .init(fit: .minimal, restartWords: true, team: .short))
        XCTAssertEqual(layout(needs(.minimal, .short) - 1), .init(fit: .minimal, restartWords: true, team: .icons))
        XCTAssertEqual(layout(10).team, .icons, "a notice never disappears")

        let get = team.notices[1], quiet = team.notices[0]
        XCTAssertEqual([get.words(at: .full), get.words(at: .quietIcon), get.words(at: .short), get.words(at: .icons)],
                       ["Team knowledge · 2 new from Priya", "Team knowledge · 2 new from Priya", "2 new from team", nil])
        XCTAssertEqual([quiet.words(at: .full), quiet.words(at: .quietIcon)], ["Sam changed 1 file · 2:31 PM", nil])
        XCTAssertEqual(base.layout(width: 10, restart: false, update: nil, metrics: metrics).team, TeamStripPresentation.Fit.full, "no team notices: nothing to fold")
    }

    // MARK: - the model

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model(team: Bool = true) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        let suite = "team-strip-tests-\(UUID().uuidString)"
        model.teamDefaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        model.setConnection(.connected)
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.27.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [],
            roots: [Root(name: "work", path: "/Users/someone/work")], commands: [], capabilities: [])
        hello.team = team ? self.hello : nil
        model.apply(.hello(hello))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-17T12:00:00Z"),
        ])))
        model.selected = 1
        return (model, sent)
    }

    private func notices(_ model: AppModel) -> [String] {
        (model.transcripts[1] ?? []).compactMap { if case .notice(_, let text) = $0 { text } else { nil } }
    }

    func testTheAppSaysItCanDrawTeamKnowledge() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("team.v1"))
    }

    func testGetSendsTheSharesThePersonWasShownAndTryAgainChecks() {
        let (model, sent) = model()
        model.apply(.teamState(state(waiting: [share("s-1", priya, ["a.md"]), share("s-2", sam, ["b.md"])])))
        model.teamAct(.get)
        guard case .teamGet(let get)? = sent.frames.last else { return XCTFail("expected team.get") }
        XCTAssertEqual(get.shares, ["s-1", "s-2"])
        XCTAssertNotNil(get.id, "its team.result answers by id")

        model.apply(.teamState(state(reach: .unreachable)))
        model.teamAct(.unreachable)
        guard case .teamCheck? = sent.frames.last else { return XCTFail("expected team.check") }
    }

    func testWithoutHelloTeamASnapshotShowsNothing() {
        let (model, _) = model(team: false)
        model.apply(.teamState(state(waiting: [share("s-1", priya, ["a.md"])], latest: changed([priya], ["_team/a.md"]))))
        XCTAssertTrue(model.teamStrip.notices.isEmpty)
        XCTAssertEqual(notices(model), [])
    }

    func testAnArrivalGetsOneConversationLineHoweverOftenItsSnapshotComes() {
        let (model, _) = model()
        let arrival = state(latest: changed([priya], ["_team/a.md"]))
        model.apply(.teamState(arrival))
        model.apply(.teamState(arrival))
        model.apply(.teamState(state(reach: .unreachable, latest: changed([priya], ["_team/a.md"]))))
        XCTAssertEqual(notices(model).count, 1)
        XCTAssertTrue(notices(model)[0].hasPrefix("Team knowledge · Priya changed 1 file"))
        model.apply(.teamState(state(latest: changed([sam], ["_team/b.md"], id: "a-3"))))
        XCTAssertEqual(notices(model).count, 2, "a new arrival is a new line")
    }

    func testTheQuietLineLeavesWhenTheNextMessageIsSent() {
        let (model, _) = model()
        model.apply(.teamState(state(latest: changed([priya], ["_team/a.md"]))))
        XCTAssertEqual(model.teamStrip.notices.map(\.kind), [.latest])
        model.sendMessage(chat: 1, text: "What changed in the calendar?")
        XCTAssertTrue(model.teamStrip.notices.isEmpty)
        model.apply(.teamState(state(latest: changed([sam], ["_team/b.md"], id: "a-3"))))
        XCTAssertEqual(model.teamStrip.notices.map(\.kind), [.latest], "the next arrival shows")
    }

    func testReviewOpensTheFileAndSeeWhatChangedOpensTheSummary() {
        let (model, sent) = model()
        var unread = TeamFile(path: "_team/a.md", direction: .in, rev: "r-4", sharedBy: priya, sharedAt: "2026-11-17T20:00:00Z")
        unread.unread = true
        model.apply(.teamState(state(latest: changed([priya], ["_team/a.md"]), files: [conflicted("notes/plan.md"), unread])))
        model.teamAct(.twoVersions)
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/notes/plan.md")
        model.teamAct(.latest)
        XCTAssertEqual(model.current[1]?.location, "/Users/someone/work/_team/_summary.md")
        model.teamOpen("_team/a.md")
        guard case .teamSeen(let seen)? = sent.frames.last else { return XCTFail("expected team.seen") }
        XCTAssertEqual([seen.path, seen.rev], ["_team/a.md", "r-4"], "opening an unread file says which version was opened")
    }

    func testARequestThatWasNotDoneSaysWhyInTheDeploymentsWords() {
        let (model, _) = model()
        model.apply(.teamResult(TeamResult(ok: true, id: "team-1")))
        XCTAssertEqual(notices(model), [])
        model.apply(.teamResult(TeamResult(
            ok: false, failed: [.init(share: "s-2", reason: "These files could not be brought in. Try again.")], id: "team-2")))
        XCTAssertEqual(notices(model), ["Team knowledge · These files could not be brought in. Try again."])
    }
}
