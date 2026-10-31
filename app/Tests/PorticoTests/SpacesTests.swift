import Foundation
import XCTest

@testable import Portico

/// v0.12 A4: the spaces switcher and the new toolbar (spec 4.2, 4.4, 5).
@MainActor
final class SpacesTests: XCTestCase {

    private func isolatedSettings() -> Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Settings(defaults: defaults)
    }

    private func space(_ id: String, title: String? = nil) -> SpaceInfo {
        SpaceInfo(id: id, title: title ?? id, icon: "doc.text", order: nil, location: "/tmp/\(id).md", media: "markdown",
                  updated: "2026-10-31T12:00:00Z")
    }

    private func model(spaces: [SpaceInfo] = []) -> (AppModel, AppModelTests.Sent) {
        let model = AppModel(settings: isolatedSettings())
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.spacesList(SpacesList(spaces: spaces)))
        return (model, sent)
    }

    // MARK: - toolbar

    func test_toolbar_has_no_chat_title() {
        for showSwitcher in [true, false] {
            let items = ToolbarLayout.items(showSwitcher: showSwitcher, showViewerToggle: true)
            XCTAssertFalse(items.map(\.rawValue).contains("chatTitle"))
        }
        XCTAssertEqual(
            ToolbarLayout.items(showSwitcher: true, showViewerToggle: true),
            [.sidebarToggle, .brand, .switcher, .spacer, .viewerToggle])
        XCTAssertEqual(ToolbarLayout.brandToSwitcherGap, 6)
    }

    func test_no_switcher_without_spaces() {
        XCTAssertFalse(ToolbarLayout.showsSwitcher(spaces: [], capabilities: ["files"]))
        XCTAssertFalse(ToolbarLayout.showsSwitcher(spaces: [], capabilities: nil))
        XCTAssertTrue(ToolbarLayout.showsSwitcher(spaces: [space("brief")], capabilities: []))
        XCTAssertTrue(ToolbarLayout.showsSwitcher(spaces: [], capabilities: ["spaces.v1"]), "a folder with no files yet still offers New space")
        XCTAssertFalse(ToolbarLayout.items(showSwitcher: false, showViewerToggle: true).contains(.switcher))
    }

    func test_app_names_spaces_capability() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("spaces.v1"))
        XCTAssertTrue(HelloClient.appCapabilities.contains("viewer.v1"))
    }

    // MARK: - "Updated" text

    func test_relative_updated_formats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        func at(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }
        let now = at("2026-10-31T15:00:00Z")  // a Saturday
        func text(_ iso: String) -> String { SpacesPresentation.updatedText(at(iso), now: now, calendar: calendar, locale: locale) }

        XCTAssertEqual(text("2026-10-31T07:02:00Z"), "Updated 7:02\u{202F}AM", "today: the time")
        XCTAssertEqual(text("2026-10-30T17:40:00Z"), "Updated yesterday, 5:40\u{202F}PM")
        XCTAssertEqual(text("2026-10-26T08:04:00Z"), "Updated Mon 8:04\u{202F}AM", "this week: the weekday")
        XCTAssertEqual(text("2026-10-24T09:00:00Z"), "Updated Oct 24", "older: the date")
        XCTAssertEqual(text("2025-12-02T09:00:00Z"), "Updated Dec 2, 2025", "another year: with the year")
        XCTAssertEqual(SpacesPresentation.updatedText(nil, now: now, calendar: calendar, locale: locale), "Updated")
    }

    // MARK: - window-wide shortcuts

    func test_cmd_digit_opens_nth_space() {
        let (model, _) = model(spaces: [space("a"), space("b"), space("c")])
        model.openSpaceAt(2)
        XCTAssertEqual(model.openSpace, "b")
        model.openSpaceAt(1)
        XCTAssertEqual(model.openSpace, "a")
        model.openSpaceAt(9)
        XCTAssertEqual(model.openSpace, "a", "no ninth space: nothing changes")
        model.openSpaceAt(0)
        XCTAssertNil(model.openSpace, "0 is Work")
        XCTAssertEqual(SpacesPresentation.shortcutDigits, Array(0...9))
    }

    // MARK: - menu: filter, selection

    func test_filter_keeps_selection_visible() {
        let spaces = [space("brief", title: "Brief"), space("prep", title: "Meeting prep"), space("metrics", title: "Weekly metrics")]
        var menu = SpaceMenuState()
        XCTAssertEqual(menu.visible(spaces), [.work, .space("brief"), .space("prep"), .space("metrics"), .newSpace])
        menu.move(1, spaces: spaces)
        menu.move(1, spaces: spaces)
        XCTAssertEqual(menu.selection, .space("prep"))

        menu.setQuery("me", spaces: spaces)  // Meeting prep, Weekly metrics
        XCTAssertEqual(menu.visible(spaces), [.space("prep"), .space("metrics")])
        XCTAssertEqual(menu.selection, .space("prep"), "still matching: stays")

        menu.setQuery("metr", spaces: spaces)
        XCTAssertEqual(menu.visible(spaces), [.space("metrics")])
        XCTAssertEqual(menu.selection, .space("metrics"), "the old selection is gone: the first match")

        menu.setQuery("zzz", spaces: spaces)
        XCTAssertNil(menu.selection)
        menu.move(1, spaces: spaces)
        XCTAssertNil(menu.selection)

        menu.setQuery("", spaces: spaces)
        XCTAssertEqual(menu.selection, .work)
        menu.move(-1, spaces: spaces)
        XCTAssertEqual(menu.selection, .work, "up stops at the top")
        for _ in 0..<10 { menu.move(1, spaces: spaces) }
        XCTAssertEqual(menu.selection, .newSpace, "down stops at the bottom")
    }

    func test_menu_commit_picks_the_selection() {
        let (model, _) = model(spaces: [space("a")])
        SpaceMenuState.Entry.space("a").choose(on: model)
        XCTAssertEqual(model.openSpace, "a")
        SpaceMenuState.Entry.work.choose(on: model)
        XCTAssertNil(model.openSpace)
    }

    // MARK: - new space

    func test_new_space_prefills_composer() {
        let (model, _) = model(spaces: [space("a")])
        XCTAssertEqual(model.composerFocusRequests, 0)
        // Before any session: the start composer.
        model.beginNewSpace()
        XCTAssertEqual(model.startDraft, "New space: ")
        XCTAssertEqual(model.composerFocusRequests, 1, "asks the composer to take focus")

        // With a chat shown: that chat's composer.
        model.apply(.chatList(ChatList(chats: [ChatSummary(chat: 1, folder: "/tmp/d", alias: nil, state: .idle, created: "2026-10-28T12:00:00Z")])))
        model.selected = 1
        model.beginNewSpace()
        XCTAssertEqual(model.draft(for: 1), "New space: ")
        XCTAssertEqual(model.composerFocusRequests, 2)
    }

    // MARK: - rename, remove

    func test_remove_confirm_text() {
        XCTAssertEqual(
            SpacesPresentation.removeConfirmation(title: "Meeting prep"),
            "Remove Meeting prep? The agent stops keeping it up to date. The file moves to the Trash.")
    }

    func test_rename_and_remove_send_to_the_gateway() {
        let (model, sent) = model(spaces: [space("a")])
        model.renameSpace("a", to: "Morning brief")
        model.removeSpace("a")
        guard case .spaceRename(let rename)? = sent.frames.dropLast().last, case .spaceRemove(let remove)? = sent.frames.last else {
            return XCTFail("expected space.rename then space.remove")
        }
        XCTAssertEqual(rename.id, "a")
        XCTAssertEqual(rename.title, "Morning brief")
        XCTAssertEqual(remove.id, "a")
    }

    func test_rename_commit_trims_and_skips_blank_or_unchanged() {
        XCTAssertEqual(SpacesPresentation.renamedTitle("  Morning brief ", current: "Brief"), "Morning brief")
        XCTAssertNil(SpacesPresentation.renamedTitle("   ", current: "Brief"))
        XCTAssertNil(SpacesPresentation.renamedTitle("Brief", current: "Brief"))
    }

    func test_dot_on_the_switcher_when_any_space_has_something_new() {
        let (model, _) = model(spaces: [space("a"), space("b")])
        XCTAssertTrue(model.hasNew("a"), "never opened: new")
        model.setOpenSpace("a")
        model.setOpenSpace("b")
        XCTAssertFalse(model.spaces.contains { model.hasNew($0.id) })
    }
}
