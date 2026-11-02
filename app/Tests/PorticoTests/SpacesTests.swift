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

    private func space(_ id: String, title: String? = nil, updated: String = "2026-10-31T12:00:00Z") -> SpaceInfo {
        SpaceInfo(id: id, title: title ?? id, icon: "doc.text", order: nil, location: "/tmp/\(id).md", media: "markdown",
                  updated: updated)
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func hello(_ capabilities: [String]) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.12.0", epoch: "e1",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: capabilities)
    }

    private func fileArtifact(_ id: String, space: String? = nil, open: Bool = true) -> Artifact {
        Artifact(id: id, kind: .file, location: "/tmp/\(id).md", media: .markdown, title: id, source: .text, open: open, space: space)
    }

    @MainActor final class FakeNotifier: SpaceNotifying {
        var posted: [(space: String, title: String, body: String)] = []
        func post(space: String, title: String, body: String) { posted.append((space, title, body)) }
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
        XCTAssertEqual(ToolbarLayout.brandToSwitcherGap, 26)
        // The real toolbar is drawn from these items and these gaps.
        XCTAssertEqual(ToolbarLayout.gap(after: .brand, next: .switcher), 26)
        XCTAssertEqual(ToolbarLayout.gap(after: .sidebarToggle, next: .brand), 12)
        XCTAssertEqual(ToolbarLayout.gap(after: .brand, next: .spacer), 12)
        XCTAssertEqual(ToolbarLayout.gap(after: .spacer, next: .viewerToggle), 0)
    }

    func test_switcher_always_shows() {
        XCTAssertTrue(ToolbarLayout.showsSwitcher)
        XCTAssertTrue(ToolbarLayout.items(showSwitcher: ToolbarLayout.showsSwitcher, showViewerToggle: false).contains(.switcher))
        XCTAssertFalse(ToolbarLayout.items(showSwitcher: false, showViewerToggle: true).contains(.switcher))
    }

    func test_new_space_needs_spaces_v1() {
        XCTAssertTrue(SpacesPresentation.canCreateSpace(capabilities: ["spaces.v1"]))
        XCTAssertTrue(SpacesPresentation.canCreateSpace(capabilities: ["files", "spaces.v1", "spaces.refresh"]))
        XCTAssertFalse(SpacesPresentation.canCreateSpace(capabilities: ["files"]), "an older gateway: New space… is dimmed")
        XCTAssertFalse(SpacesPresentation.canCreateSpace(capabilities: nil))
    }

    func test_empty_menu_and_too_old_copy() {
        XCTAssertEqual(SpacesPresentation.noSpacesText, "No spaces yet")
        XCTAssertEqual(SpacesPresentation.tooOldHelp, "This Portico gateway is too old for spaces.")
        XCTAssertTrue(SpacesPresentation.showsEmptyNote(spaces: [], query: ""))
        XCTAssertFalse(SpacesPresentation.showsEmptyNote(spaces: [], query: "x"), "a typed filter shows No match, not the empty note")
        XCTAssertFalse(SpacesPresentation.showsEmptyNote(spaces: [space("brief")], query: ""))
        // With no spaces the menu still offers Work and New space….
        XCTAssertEqual(SpaceMenuState().visible([]), [.work, .newSpace])
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

    // MARK: - New space… lands in the composer on screen (v0.14 test fix, issue 4)

    /// Single presentation, Session 2 ended and Session 3 live, listed.
    private func singleWithSessions() -> AppModel {
        let (model, _) = model(spaces: [space("a")])
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.14.0", epoch: "e1",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [], commands: [],
            capabilities: ["sessions", SpacesList.capability], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 2, folder: "/tmp/d", alias: nil, state: .stopped, created: "2026-10-31T09:00:00Z", ended: "2026-10-31T17:00:00Z"),
            ChatSummary(chat: 3, folder: "/tmp/d", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z"),
        ])))
        return model
    }

    /// The welcome continuing the live session (Y1, the launch screen with
    /// one) shows the start composer: "New space: " goes there, not into
    /// the live session's own draft, which no composer on screen shows.
    func test_new_space_on_the_welcome_continuing_a_session_fills_the_welcome_composer() {
        let model = singleWithSessions()
        XCTAssertEqual(model.mainScreen, .continuing(3))
        model.beginNewSpace()
        XCTAssertEqual(model.startDraft, "New space: ", "the composer on screen")
        XCTAssertEqual(model.draft(for: 3), "", "not the live session's hidden draft")
        XCTAssertEqual(model.composerFocusRequests, 1)
    }

    /// An earlier session is read-only (no composer): New space… goes back
    /// to the live session and fills its composer.
    func test_new_space_on_an_earlier_session_goes_to_the_live_sessions_composer() {
        let model = singleWithSessions()
        model.open(chat: 2)
        XCTAssertTrue(model.showsEarlierBar(chat: 2))
        model.beginNewSpace()
        XCTAssertEqual(model.mainScreen, .conversation(3), "the live session, where a composer is")
        XCTAssertEqual(model.draft(for: 3), "New space: ")
        XCTAssertEqual(model.draft(for: 2), "")
        XCTAssertEqual(model.composerFocusRequests, 1)
    }

    /// The document view has the shown chat's composer: it gets it there.
    func test_new_space_in_the_document_view_fills_its_composer() {
        let model = singleWithSessions()
        model.open(chat: 3)
        model.documentMode = true
        model.beginNewSpace()
        XCTAssertEqual(model.draft(for: 3), "New space: ")
        XCTAssertTrue(model.documentMode, "the document view stays")
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
        XCTAssertFalse(model.hasNew("a"), "first sight: no dot")
        // Both change after the app first saw them.
        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: later), space("b", updated: later)])))
        XCTAssertTrue(model.spaces.contains { model.hasNew($0.id) })
        model.setOpenSpace("a")
        model.setOpenSpace("b")
        XCTAssertFalse(model.spaces.contains { model.hasNew($0.id) })
    }

    func test_new_space_keeps_an_existing_draft() {
        XCTAssertEqual(SpacesPresentation.newSpaceDraft(existing: ""), "New space: ")
        XCTAssertEqual(SpacesPresentation.newSpaceDraft(existing: "  \n"), "New space: ")
        XCTAssertEqual(SpacesPresentation.newSpaceDraft(existing: "fix the bug"), "New space: fix the bug")
        XCTAssertEqual(SpacesPresentation.newSpaceDraft(existing: "New space: a brief"), "New space: a brief")
        let (model, _) = model(spaces: [space("a")])
        model.startDraft = "half a thought"
        model.beginNewSpace()
        XCTAssertEqual(model.startDraft, "New space: half a thought")
    }

    func test_escape_clears_the_filter_then_closes() {
        let spaces = [space("a", title: "Alpha")]
        var menu = SpaceMenuState()
        menu.setQuery("alp", spaces: spaces)
        XCTAssertFalse(menu.escape(spaces: spaces))
        XCTAssertEqual(menu.query, "")
        XCTAssertEqual(menu.selection, .space("a"), "the selection survives the clear")
        XCTAssertTrue(menu.escape(spaces: spaces))
    }

    func test_title_is_capped_and_list_scrolls_past_nine_rows() {
        XCTAssertEqual(ToolbarLayout.switcherTitleMaxWidth, 160)
        XCTAssertEqual(SpacesPresentation.listMaxHeight, 450)
    }

    // MARK: - a space open (A5)

    func test_artifact_space_switches_not_opens_file() {
        let (model, _) = model(spaces: [space("brief")])
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: fileArtifact("brief.md", space: "brief"))))
        XCTAssertEqual(model.openSpace, "brief")
        XCTAssertNil(model.current[1], "not opened as a file")
        XCTAssertTrue(model.artifacts[1]?.isEmpty ?? true, "not in the chat's history either")

        // Its row not listed yet: the switch waits for the list.
        let (late, _) = self.model()
        late.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: fileArtifact("brief.md", space: "brief"))))
        XCTAssertNil(late.openSpace)
        late.apply(.spacesList(SpacesList(spaces: [space("brief")])))
        XCTAssertEqual(late.openSpace, "brief")
        XCTAssertNil(late.current[1])
    }

    func test_close_restores_previous_viewer() {
        let (model, _) = model(spaces: [space("brief")])
        let before = fileArtifact("notes.md")
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: before)))
        XCTAssertEqual(model.current[1], before)
        model.openSpaceAt(1)
        XCTAssertEqual(model.shownArtifact(for: 1)?.id, "space:brief")
        XCTAssertEqual(model.shownArtifact(for: 1)?.location, "/tmp/brief.md")
        XCTAssertEqual(model.current[1], before, "the chat's own viewer is untouched")
        model.openSpaceAt(0)
        XCTAssertEqual(model.shownArtifact(for: 1), before)

        // Collapsed before: still collapsed after.
        model.setViewer(visible: false, for: 1)
        model.openSpaceAt(1)
        XCTAssertTrue(model.isViewerShown(for: 1), "a space opens the column")
        model.setOpenSpace(nil)
        XCTAssertFalse(model.isViewerShown(for: 1))
    }

    func test_space_belongs_to_the_window_not_a_chat() {
        let (model, _) = model(spaces: [space("brief")])
        model.openSpaceAt(1)
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/a", alias: nil, state: .idle, created: "2026-10-28T12:00:00Z"),
            ChatSummary(chat: 2, folder: "/tmp/b", alias: nil, state: .idle, created: "2026-10-28T12:00:00Z")])))
        model.selected = 1
        XCTAssertEqual(model.shownArtifact(for: 1)?.id, "space:brief")
        model.selected = 2
        XCTAssertEqual(model.openSpace, "brief")
        XCTAssertEqual(model.shownArtifact(for: 2)?.id, "space:brief")
    }

    func test_ordinary_file_while_a_space_is_open_goes_back_to_work() {
        let (model, _) = model(spaces: [space("brief")])
        model.openSpaceAt(1)
        let file = fileArtifact("report.md")
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: file)))
        XCTAssertNil(model.openSpace)
        XCTAssertEqual(model.shownArtifact(for: 1), file)
    }

    func test_refresh_hidden_without_capability() {
        let (model, _) = model()
        model.apply(.hello(hello(["spaces.v1"])))
        XCTAssertFalse(model.spacesCanRefresh)
        model.apply(.hello(hello(["spaces.v1", "spaces.refresh"])))
        XCTAssertTrue(model.spacesCanRefresh)
    }

    func test_stale_list_cleared_by_a_gateway_without_spaces() {
        let (model, _) = model(spaces: [space("brief")])
        model.openSpaceAt(1)
        model.apply(.hello(hello(["spaces.v1"])))
        XCTAssertEqual(model.spaces.map(\.id), ["brief"], "spaces.v1: the list stands until the next one")
        model.apply(.hello(hello(["files"])))
        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertNil(model.openSpace)
    }

    func test_first_sight_stamps_and_later_change_is_new() {
        let (model, _) = model()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.now = { start }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(-3600)))])))
        XCTAssertEqual(model.settings.spacesFirstSeen["a"], start)
        XCTAssertFalse(model.hasNew("a"), "older than first sight")
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(60)))])))
        XCTAssertTrue(model.hasNew("a"))
        model.now = { start.addingTimeInterval(120) }
        model.setOpenSpace("a")
        XCTAssertFalse(model.hasNew("a"))
        XCTAssertEqual(model.settings.spacesFirstSeen["a"], start, "stamped once")
    }

    func test_notify_only_when_inactive_and_enabled() {
        let (model, _) = model()
        let notifier = FakeNotifier()
        model.spaceNotifier = notifier
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.now = { start.addingTimeInterval(120) }
        model.apply(.spacesList(SpacesList(spaces: [space("a", title: "Meeting prep", updated: iso(start))])))
        XCTAssertTrue(notifier.posted.isEmpty, "the first list is not news")

        func change(_ seconds: TimeInterval) {
            model.apply(.spacesList(SpacesList(spaces: [space("a", title: "Meeting prep", updated: iso(start.addingTimeInterval(seconds)))])))
        }
        model.isAppActive = { true }
        change(10)
        XCTAssertTrue(notifier.posted.isEmpty, "active: no notification")

        model.isAppActive = { false }
        model.settings.spacesNotify = false
        change(20)
        XCTAssertTrue(notifier.posted.isEmpty, "setting off: none")

        model.settings.spacesNotify = true
        change(20)
        XCTAssertTrue(notifier.posted.isEmpty, "not advanced: none")
        change(30)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.space, "a")
        XCTAssertEqual(notifier.posted.first?.title, "Meeting prep")
        XCTAssertTrue(notifier.posted.first?.body.hasPrefix("Updated — ") == true)
    }

    func test_notify_off_hides_dot() {
        let (model, _) = model()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.now = { start }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start))])))
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(60)))])))
        XCTAssertTrue(model.hasNew("a"))
        model.settings.spacesNotify = false
        XCTAssertFalse(model.hasNew("a"))
    }

    func test_space_column_is_700_where_the_window_allows() {
        XCTAssertEqual(ColumnWidths.viewerDefault(for: .space), 700)
        let wide = ColumnWidths.fit(sidebar: 260, viewer: 700, window: 1600)
        XCTAssertEqual(wide.viewer, 700)
        let narrow = ColumnWidths.fit(sidebar: 260, viewer: 700, window: 1100)
        XCTAssertEqual(narrow.viewer, 700 - (260 + 700 + ColumnWidths.conversationMinimum - 1100))
    }

    // MARK: - fix round 1

    private func history(_ events: [ServerMessage], chat: Int = 1) -> ServerMessage {
        .chatHistory(ChatHistory(chat: chat, events: events, truncated: false))
    }

    func test_replay_never_opens_a_space() {
        let (model, _) = model(spaces: [space("brief")])
        model.apply(history([.artifactCreated(ArtifactCreated(chat: 1, artifact: fileArtifact("brief.md", space: "brief"), seq: 1))]))
        XCTAssertNil(model.openSpace, "history replay does not drive the window's space")
        XCTAssertNil(model.current[1])
    }

    func test_replayed_auto_open_keeps_the_open_space() {
        let (model, _) = model(spaces: [space("brief")])
        model.openSpaceAt(1)
        model.apply(history([.artifactCreated(ArtifactCreated(chat: 1, artifact: fileArtifact("old.md"), seq: 1))]))
        XCTAssertEqual(model.openSpace, "brief", "a replayed auto-open does not close the person's space")
    }

    func test_space_shows_with_no_chat_shown() {
        let (model, _) = model(spaces: [space("brief")])
        XCTAssertNil(model.shownChat)
        XCTAssertFalse(model.viewerColumnShown)
        model.openSpaceAt(1)
        XCTAssertTrue(model.viewerColumnShown, "the column is drawn for a space on the welcome screen")
        model.setViewer(visible: false, for: 1)
        XCTAssertFalse(model.viewerColumnShown, "collapsible by hand")
        model.openSpaceAt(0)
        XCTAssertFalse(model.viewerColumnShown)
    }

    func test_markdown_properties_hide_the_space_keys_only() throws {
        let source = "---\ntitle: Brief\nicon: doc.text\norder: 2\nstatus: draft\n---\n# Brief\n"
        let hidden = try MarkdownPage.html(source: source, title: "brief.md", hiding: SpacesPresentation.hiddenFrontMatterKeys)
        XCTAssertFalse(hidden.contains("<span class=\"fm-key\">title</span>"))
        XCTAssertFalse(hidden.contains("<span class=\"fm-key\">icon</span>"))
        XCTAssertFalse(hidden.contains("<span class=\"fm-key\">order</span>"))
        XCTAssertTrue(hidden.contains("<span class=\"fm-key\">status</span>"), "other keys still show")

        let onlyOwn = try MarkdownPage.html(source: "---\ntitle: Brief\nicon: doc.text\n---\n# Brief\n", title: "b.md", hiding: SpacesPresentation.hiddenFrontMatterKeys)
        XCTAssertFalse(onlyOwn.contains("<details class=\"fm\""), "nothing left: no block at all")

        let plain = try MarkdownPage.html(source: source, title: "brief.md")
        XCTAssertTrue(plain.contains("<span class=\"fm-key\">title</span>"), "an ordinary note keeps its title")

        // The open space's artifact loads with the hidden keys; a file does not.
        let spaceFile = ArtifactPresentation(artifact: Artifact(id: "space:brief", kind: .file, location: "/tmp/brief.md", media: .markdown, title: "Brief", source: .text, open: true))
        XCTAssertEqual(WebPane.Load(spaceFile), .markdown(URL(fileURLWithPath: "/tmp/brief.md"), hiding: SpacesPresentation.hiddenFrontMatterKeys))
        let ordinary = ArtifactPresentation(artifact: fileArtifact("notes"))
        XCTAssertEqual(WebPane.Load(ordinary), .markdown(URL(fileURLWithPath: "/tmp/notes.md"), hiding: []))
    }

    func test_notification_time_is_time_only() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try! Date("2026-10-31T07:02:00Z", strategy: .iso8601)
        XCTAssertEqual(SpacesPresentation.notificationBody(date, calendar: calendar, locale: Locale(identifier: "en_US")), "Updated — 7:02\u{202F}AM")
    }

    func test_update_to_the_open_space_while_active_leaves_no_dot() {
        let (model, _) = model()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        model.now = { start }
        model.isAppActive = { true }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start))])))
        model.setOpenSpace("a")
        model.now = { start.addingTimeInterval(100) }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(90)))])))
        XCTAssertFalse(model.hasNew("a"), "being looked at")
        // Another space, or the app in the background, still shows it.
        model.now = { start.addingTimeInterval(80) }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(90))), space("b", updated: iso(start))])))
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(90))), space("b", updated: iso(start.addingTimeInterval(95)))])))
        XCTAssertTrue(model.hasNew("b"))
        model.isAppActive = { false }
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: iso(start.addingTimeInterval(99))), space("b", updated: iso(start.addingTimeInterval(95)))])))
        XCTAssertTrue(model.hasNew("a"), "inactive: not being looked at")
    }

    func test_pending_switch_clears_on_a_list_without_it() {
        let (model, _) = model()
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: fileArtifact("brief.md", space: "brief"))))
        model.apply(.spacesList(SpacesList(spaces: [space("other")])))
        XCTAssertNil(model.openSpace)
        model.apply(.spacesList(SpacesList(spaces: [space("other"), space("brief")])))
        XCTAssertNil(model.openSpace, "the stale pending switch is gone")
    }

    func test_file_re_reads_when_updated_advances() {
        let (model, _) = model(spaces: [space("a", updated: "2026-10-31T12:00:00Z")])
        model.openSpaceAt(1)
        let before = model.openSpaceContentKey
        XCTAssertNotNil(before)
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: "2026-10-31T12:05:00Z")])))
        XCTAssertNotEqual(model.openSpaceContentKey, before, "a new `updated` reloads the pane")
        let same = model.openSpaceContentKey
        model.apply(.spacesList(SpacesList(spaces: [space("a", updated: "2026-10-31T12:05:00Z")])))
        XCTAssertEqual(model.openSpaceContentKey, same, "an unchanged list does not")
    }
}
