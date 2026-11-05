import Foundation
import XCTest

@testable import Portico

/// v0.22 S1, S2, S4, S5: action links in a space's page, worded notices,
/// fixed spaces and the refreshing state (spec §2, §3, §5, §6).
@MainActor
final class SpaceActionsTests: XCTestCase {

    private func isolatedSettings() -> Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Settings(defaults: defaults)
    }

    private func space(
        _ id: String, title: String? = nil, updated: String = "2026-10-31T12:00:00Z",
        notice: String? = nil, target: String? = nil, removable: Bool = true
    ) -> SpaceInfo {
        SpaceInfo(id: id, title: title ?? id, icon: "doc.text", order: nil, location: "/tmp/\(id).md", media: "markdown",
                  updated: updated, notice: notice, noticeTarget: target, removable: removable)
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func hello(_ capabilities: [String]) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.22.0", epoch: "e1",
            brand: Brand(name: "Acme", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: capabilities)
    }

    private func model(spaces: [SpaceInfo] = [], capabilities: [String] = ["spaces.v1", "spaces.refresh", "spaces.act"])
        -> (AppModel, AppModelTests.Sent)
    {
        let model = AppModel(settings: isolatedSettings())
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.hello(hello(capabilities)))
        model.apply(.spacesList(SpacesList(spaces: spaces)))
        return (model, sent)
    }

    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    private func encodedObject(_ message: ClientMessage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    }

    @MainActor final class FakeNotifier: SpaceNotifying {
        var posted: [(space: String, title: String, body: String, target: String?)] = []
        var messages: [(id: String, title: String, body: String)] = []
        func post(space: String, title: String, body: String, target: String?) { posted.append((space, title, body, target)) }
        func postMessage(id: String, title: String, body: String) { messages.append((id, title, body)) }
    }

    // MARK: - S1: the link

    private func parse(_ string: String) -> SpaceActionLink.Parsed {
        SpaceActionLink.parse(URL(string: string)!)
    }

    func test_link_with_an_item_parses() {
        XCTAssertEqual(parse("space-action:mark-done?item=task-3"), .action(.init(action: "mark-done", item: "task-3")))
        XCTAssertEqual(parse("space-action:a.b_c:D-9?item=x:y.z"), .action(.init(action: "a.b_c:D-9", item: "x:y.z")))
    }

    func test_link_without_an_item_parses() {
        XCTAssertEqual(parse("space-action:refresh-all"), .action(.init(action: "refresh-all", item: nil)))
    }

    func test_the_scheme_is_matched_without_case() {
        XCTAssertEqual(parse("Space-Action:go"), .action(.init(action: "go", item: nil)))
    }

    func test_other_links_are_not_actions() {
        XCTAssertEqual(parse("https://example.com/space-action:x"), .notSpaceAction)
        XCTAssertEqual(parse("portico-view://abc/"), .notSpaceAction)
        XCTAssertEqual(parse("space-actions:x"), .notSpaceAction)
    }

    func test_anything_else_is_refused() {
        let bad = [
            "space-action:",  // no action
            "space-action:?item=a",  // no action
            "space-action:do%20it",  // percent-encoded: not in the set
            "space-action:do?item=",  // empty item
            "space-action:do?item=a&x=1",  // another key
            "space-action:do?other=a",  // not item
            "space-action:do?item=a#frag",  // a fragment
            "space-action:do#frag",
            "space-action://host/do",  // a host form
            "space-action:a/b",  // a slash
            "space-action:do?item=a?b",  // a second ?
            "space-action:" + String(repeating: "a", count: 129),
            "space-action:do?item=" + String(repeating: "b", count: 129),
        ]
        for link in bad {
            guard let url = URL(string: link) else { continue }
            guard case .invalid = SpaceActionLink.parse(url) else { return XCTFail("\(link) should be refused") }
        }
        // 128 is the longest allowed.
        XCTAssertEqual(
            parse("space-action:" + String(repeating: "a", count: 128)),
            .action(.init(action: String(repeating: "a", count: 128), item: nil)))
    }

    func test_space_act_encodes_as_the_spec_names_it() throws {
        let object = try encodedObject(.spaceAct(SpaceAct(id: "brief", action: "mark-done", item: "task-3", ts: "2026-11-05T12:00:00Z")))
        XCTAssertEqual(object["type"] as? String, "space.act")
        XCTAssertEqual(object["id"] as? String, "brief")
        XCTAssertEqual(object["action"] as? String, "mark-done")
        XCTAssertEqual(object["item"] as? String, "task-3")
        let bare = try encodedObject(.spaceAct(SpaceAct(id: "brief", action: "go")))
        XCTAssertNil(bare["item"], "no item: the key is left out")
        // And it decodes back.
        let data = try JSONEncoder().encode(ClientMessage.spaceAct(SpaceAct(id: "b", action: "go", item: "i", ts: "t")))
        XCTAssertEqual(try JSONDecoder().decode(ClientMessage.self, from: data), .spaceAct(SpaceAct(id: "b", action: "go", item: "i", ts: "t")))
    }

    func test_a_link_sends_space_act_when_the_gateway_can() {
        let (model, sent) = model(spaces: [space("brief")])
        model.spaceActionLinkActivated(URL(string: "space-action:mark-done?item=task-3")!, space: "brief")
        guard case .spaceAct(let act)? = sent.frames.last else { return XCTFail("no space.act: \(sent.frames)") }
        XCTAssertEqual(act.id, "brief")
        XCTAssertEqual(act.action, "mark-done")
        XCTAssertEqual(act.item, "task-3")
    }

    func test_a_link_is_ignored_without_the_capability() {
        let (model, sent) = model(spaces: [space("brief")], capabilities: ["spaces.v1", "spaces.refresh"])
        XCTAssertFalse(model.spacesCanAct)
        let before = sent.frames.count
        model.spaceActionLinkActivated(URL(string: "space-action:go")!, space: "brief")
        XCTAssertEqual(sent.frames.count, before)
    }

    func test_an_invalid_link_sends_nothing() {
        let (model, sent) = model(spaces: [space("brief")])
        let before = sent.frames.count
        model.spaceActionLinkActivated(URL(string: "space-action:do?item=a&b=c")!, space: "brief")
        model.spaceActionLinkActivated(URL(string: "space-action:go")!, space: "gone")
        XCTAssertEqual(sent.frames.count, before, "a bad link, or a space no longer listed, sends nothing")
    }

    func test_a_failed_action_shows_like_a_failed_refresh() {
        let (model, _) = model(spaces: [space("brief")])
        model.spaceActionLinkActivated(URL(string: "space-action:go")!, space: "brief")
        model.apply(.error(ErrorMessage(code: "space.act_failed", message: "no such task", id: "brief")))
        XCTAssertEqual(model.spaceErrors["brief"], "no such task")

        model.refreshSpace("brief")
        XCTAssertNil(model.spaceErrors["brief"], "the next request clears it")
        model.apply(.error(ErrorMessage(code: "space.refresh_failed", message: "exit 1: offline", id: "brief")))
        XCTAssertEqual(model.spaceErrors["brief"], "exit 1: offline")

        // A newer file clears it too.
        model.apply(.spacesList(SpacesList(spaces: [space("brief", updated: "2026-10-31T12:05:00Z")])))
        XCTAssertNil(model.spaceErrors["brief"])
    }

    func test_no_act_is_ignored() {
        let (model, _) = model(spaces: [space("brief")])
        model.spaceActionLinkActivated(URL(string: "space-action:go")!, space: "brief")
        model.apply(.error(ErrorMessage(code: "space.no_act", message: "this deployment has no act", id: "brief")))
        XCTAssertNil(model.spaceErrors["brief"])
    }

    func test_an_error_for_a_space_not_asked_about_is_not_its_error() {
        let (model, _) = model(spaces: [space("brief")])
        model.apply(.error(ErrorMessage(code: "space.refresh_failed", message: "x", id: "brief")))
        XCTAssertNil(model.spaceErrors["brief"])
    }

    // MARK: - S2: notices

    func test_space_info_decodes_the_v022_keys() throws {
        let message = try decode(#"""
            {"type":"spaces.list","ts":"2026-11-05T12:00:00Z","spaces":[
              {"id":"prep","title":"Prep","icon":"doc.text","location":"/s/prep.md","media":"markdown","updated":"2026-11-05T09:00:00Z",
               "notice":"Prep for your 10:00 is ready","notice_target":"meeting-1000","removable":false},
              {"id":"old","title":"Old","icon":"doc.text","location":"/s/old.md","media":"markdown","updated":"2026-11-05T09:00:00Z"}]}
            """#)
        guard case .spacesList(let list) = message else { return XCTFail("got \(message)") }
        XCTAssertEqual(list.spaces[0].notice, "Prep for your 10:00 is ready")
        XCTAssertEqual(list.spaces[0].noticeTarget, "meeting-1000")
        XCTAssertFalse(list.spaces[0].removable)
        XCTAssertNil(list.spaces[1].notice)
        XCTAssertNil(list.spaces[1].noticeTarget)
        XCTAssertTrue(list.spaces[1].removable, "absent means removable")
        // Encoded as the gateway sends it: removable only when false.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(list.spaces[1])) as? [String: Any])
        XCTAssertNil(raw["removable"])
        XCTAssertNil(raw["notice"])
        let fixed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(list.spaces[0])) as? [String: Any])
        XCTAssertEqual(fixed["removable"] as? Bool, false)
        XCTAssertEqual(fixed["notice_target"] as? String, "meeting-1000")
    }

    func test_notification_words() {
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        let worded = SpacesPresentation.notification(for: space("a", updated: iso(updated), notice: "Prep is ready", target: "m-1"))
        XCTAssertEqual(worded, .init(body: "Prep is ready", target: "m-1"))
        XCTAssertNil(SpacesPresentation.notification(for: space("a", updated: iso(updated), notice: "")), "empty: none")
        XCTAssertNil(SpacesPresentation.notification(for: space("a", updated: iso(updated), notice: "  \n")), "blank: none")
        let plain = SpacesPresentation.notification(for: space("a", updated: iso(updated)))
        XCTAssertEqual(plain?.body, SpacesPresentation.notificationBody(updated), "no key: as before")
        XCTAssertNil(plain?.target)
        XCTAssertNil(SpacesPresentation.notification(for: space("a", updated: iso(updated), target: ""))?.target, "an empty target is none")
    }

    func test_a_worded_notice_is_the_notification() {
        let (model, _) = model()
        let notifier = FakeNotifier()
        model.spaceNotifier = notifier
        model.isAppActive = { false }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.apply(.spacesList(SpacesList(spaces: [space("prep", title: "Prep", updated: iso(start))])))
        model.apply(.spacesList(SpacesList(spaces: [
            space("prep", title: "Prep", updated: iso(start.addingTimeInterval(60)), notice: "Prep for your 10:00 is ready", target: "meeting-1000"),
        ])))
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.title, "Prep")
        XCTAssertEqual(notifier.posted.first?.body, "Prep for your 10:00 is ready")
        XCTAssertEqual(notifier.posted.first?.target, "meeting-1000")

        model.apply(.spacesList(SpacesList(spaces: [space("prep", title: "Prep", updated: iso(start.addingTimeInterval(120)), notice: "")])))
        XCTAssertEqual(notifier.posted.count, 1, "an empty notice: no notification")

        model.apply(.spacesList(SpacesList(spaces: [space("prep", title: "Prep", updated: iso(start.addingTimeInterval(180)))])))
        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertTrue(notifier.posted.last?.body.hasPrefix("Updated — ") == true, "without the key, as today")
    }

    func test_opening_from_a_notice_asks_the_pane_to_scroll_once() {
        let (model, _) = model(spaces: [space("prep"), space("other")])
        model.openSpace("prep", scrollTo: "meeting-1000")
        XCTAssertEqual(model.openSpace, "prep")
        let request = try? XCTUnwrap(model.spaceScrollRequest)
        XCTAssertEqual(request?.space, "prep")
        XCTAssertEqual(request?.fragment, "meeting-1000")
        // A second click on the same notice asks again (a new request).
        model.openSpace("prep", scrollTo: "meeting-1000")
        XCTAssertNotEqual(model.spaceScrollRequest, request)
        // Any other opening forgets it, so the space does not jump on its next visit.
        model.setOpenSpace("other")
        XCTAssertNil(model.spaceScrollRequest)
        model.openSpace("prep", scrollTo: nil)
        XCTAssertNil(model.spaceScrollRequest)
    }

    func test_scroll_script_names_the_fragment_safely() {
        let script = WebPane.Coordinator.scrollToFragment("a'b\"</script>")
        XCTAssertTrue(script.contains(MarkdownPage.jsString("a'b\"</script>")))
        XCTAssertTrue(script.contains("scrollIntoView"))
    }

    func test_the_v022_keys_stay_out_of_the_properties_block() {
        for key in ["notice", "notice_target", "removable"] {
            XCTAssertTrue(SpacesPresentation.hiddenFrontMatterKeys.contains(key), key)
        }
    }

    // MARK: - S4: fixed spaces

    func test_a_fixed_space_offers_no_rename_or_remove() {
        XCTAssertEqual(SpacesPresentation.menuActions(for: space("a")), [.rename, .remove])
        XCTAssertEqual(SpacesPresentation.menuActions(for: space("a", removable: false)), [])
    }

    // MARK: - S5: refreshing

    func test_refreshing_ends_when_updated_changes() {
        var state = SpaceRefreshing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state.begin("a", updated: "2026-10-31T12:00:00Z", at: start)
        XCTAssertTrue(state.isRefreshing("a", now: start))
        XCTAssertFalse(state.isRefreshing("b", now: start))
        state.apply([space("a", updated: "2026-10-31T12:00:00Z")])
        XCTAssertTrue(state.isRefreshing("a", now: start), "same updated: still refreshing")
        state.apply([space("a", updated: "2026-10-31T12:01:00Z")])
        XCTAssertFalse(state.isRefreshing("a", now: start))
    }

    func test_refreshing_ends_after_five_minutes() {
        var state = SpaceRefreshing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state.begin("a", updated: "u", at: start)
        XCTAssertTrue(state.isRefreshing("a", now: start.addingTimeInterval(299)))
        XCTAssertFalse(state.isRefreshing("a", now: start.addingTimeInterval(300)))
        state.expire(now: start.addingTimeInterval(301))
        XCTAssertTrue(state.ids.isEmpty)
    }

    func test_refreshing_ends_for_a_space_gone_or_failed() {
        var state = SpaceRefreshing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        state.begin("a", updated: "u", at: start)
        state.begin("b", updated: "u", at: start)
        state.end("b")
        XCTAssertFalse(state.isRefreshing("b", now: start))
        state.apply([])
        XCTAssertFalse(state.isRefreshing("a", now: start))
    }

    func test_the_model_refreshes_until_the_file_changes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, sent) = model(spaces: [space("a", updated: iso(start))])
        model.now = { start }
        model.refreshSpace("a")
        guard case .spaceRefresh(let refresh)? = sent.frames.last else { return XCTFail("no space.refresh") }
        XCTAssertEqual(refresh.id, "a")
        XCTAssertTrue(model.isRefreshing("a"))
        // The command's own answer, with nothing new yet.
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start))])))
        XCTAssertTrue(model.isRefreshing("a"))
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(90)))])))
        XCTAssertFalse(model.isRefreshing("a"))
    }

    func test_the_model_stops_refreshing_on_failure_and_after_five_minutes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, _) = model(spaces: [space("a", updated: iso(start)), space("b", updated: iso(start))])
        model.now = { start }
        model.refreshSpace("a")
        model.apply(.error(ErrorMessage(code: "space.refresh_failed", message: "exit 2", id: "a")))
        XCTAssertFalse(model.isRefreshing("a"), "a failure ends it at once")
        XCTAssertEqual(model.spaceErrors["a"], "exit 2")

        model.refreshSpace("b")
        XCTAssertTrue(model.isRefreshing("b"))
        model.now = { start.addingTimeInterval(301) }
        XCTAssertFalse(model.isRefreshing("b"), "five minutes: done")
    }

    // MARK: - S5 review fixes

    func test_the_next_deadline_is_the_earliest_entrys() {
        var state = SpaceRefreshing()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(state.nextDeadline)
        state.begin("a", updated: "u", at: start)
        state.begin("b", updated: "u", at: start.addingTimeInterval(200))
        XCTAssertEqual(state.nextDeadline, start.addingTimeInterval(SpaceRefreshing.timeout))
        state.end("a")
        XCTAssertEqual(state.nextDeadline, start.addingTimeInterval(200 + SpaceRefreshing.timeout))
    }

    func test_the_expiry_waits_for_the_earliest_refresh_not_the_newest() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, _) = model(spaces: [space("a", updated: iso(start)), space("b", updated: iso(start))])
        XCTAssertNil(model.refreshingExpiryDelay)
        model.now = { start }
        model.refreshSpace("a")
        model.now = { start.addingTimeInterval(200) }
        model.refreshSpace("b")
        let delay = model.refreshingExpiryDelay
        XCTAssertNotNil(delay)
        XCTAssertLessThanOrEqual(delay ?? .infinity, 101, "a's five minutes end 100 s from now")
        XCTAssertGreaterThanOrEqual(delay ?? 0, 100)
        model.now = { start.addingTimeInterval(400) }
        XCTAssertEqual(model.refreshingExpiryDelay ?? -1, 0, accuracy: 1, "overdue: at once")
    }

    func test_a_rename_does_not_lose_the_refresh_in_flight() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, _) = model(spaces: [space("a", updated: iso(start))])
        model.now = { start }
        model.refreshSpace("a")
        model.renameSpace("a", to: "New name")
        model.apply(.error(ErrorMessage(code: "space.rename_failed", message: "read-only", id: "a")))
        XCTAssertTrue(model.isRefreshing("a"), "the rename's failure is not the refresh's")
        model.apply(.error(ErrorMessage(code: "space.refresh_failed", message: "exit 2", id: "a")))
        XCTAssertFalse(model.isRefreshing("a"), "the refresh's own failure still ends it")
        XCTAssertEqual(model.spaceErrors["a"], "exit 2")
    }

    func test_a_remove_does_not_lose_the_refresh_in_flight() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, _) = model(spaces: [space("a", updated: iso(start))])
        model.now = { start }
        model.refreshSpace("a")
        model.removeSpace("a")
        model.apply(.error(ErrorMessage(code: "space.fixed", message: "fixed", id: "a")))
        XCTAssertTrue(model.isRefreshing("a"))
        model.apply(.error(ErrorMessage(code: "space.refresh_failed", message: "exit 3", id: "a")))
        XCTAssertFalse(model.isRefreshing("a"))
    }

    // MARK: - S1 review fix: only the person's click in the space's own page

    private func takes(
        click: Bool = true, targetMain: Bool? = true, sourceMain: Bool = true, ownPage: Bool = true, agentActing: Bool = false
    ) -> Bool {
        WebPane.Coordinator.takesSpaceAction(
            linkActivated: click, targetIsMainFrame: targetMain, sourceIsMainFrame: sourceMain,
            showingOwnPage: ownPage, agentActing: agentActing)
    }

    func test_a_space_action_is_taken_only_from_the_persons_click_in_the_main_frame_of_its_own_page() {
        XCTAssertTrue(takes())
        XCTAssertFalse(takes(click: false), "a script's navigation is not a click")
        XCTAssertFalse(takes(targetMain: false), "a link in an iframe")
        XCTAssertFalse(takes(targetMain: nil), "a new window")
        XCTAssertFalse(takes(sourceMain: false), "a frame aiming at the top")
        XCTAssertFalse(takes(ownPage: false), "an outside site or another file")
        XCTAssertFalse(takes(agentActing: true), "the viewer agent is acting")
    }

    func test_the_own_page_is_the_space_file_itself() {
        let file = URL(fileURLWithPath: "/tmp/spaces/brief.md")
        XCTAssertTrue(WebPane.Coordinator.isSpaceFile(.markdown(file), away: false))
        XCTAssertTrue(WebPane.Coordinator.isSpaceFile(.html(file), away: false))
        XCTAssertFalse(WebPane.Coordinator.isSpaceFile(.markdown(file), away: true))
        XCTAssertFalse(WebPane.Coordinator.isSpaceFile(.url(URL(string: "https://example.com")!), away: false))
        XCTAssertFalse(WebPane.Coordinator.isSpaceFile(nil, away: false))
    }

    func test_header_note_prefers_refreshing_then_the_error() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SpacesPresentation.headerNote(refreshing: true, error: "x", updated: date), .refreshing)
        XCTAssertEqual(SpacesPresentation.headerNote(refreshing: false, error: "exit 1", updated: date), .error("exit 1"))
        XCTAssertEqual(SpacesPresentation.headerNote(refreshing: false, error: nil, updated: date), .updated(SpacesPresentation.updatedText(date)))
        XCTAssertEqual(SpacesPresentation.refreshingText, "Refreshing…")
    }
}
