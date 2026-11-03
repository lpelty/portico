import Foundation
import XCTest

@testable import Portico

/// v0.18 §3 (screen AR4, rulings 16–19): Settings → Plugins — Installed and
/// Browse, the marketplaces, a row's menu, Uninstall asking first, Configure
/// sending only what changed, and requests that end when the connection does.
@MainActor
final class PluginSettingsTests: XCTestCase {

    private final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
        /// What the person's actions sent: the options each new row is asked for are left out.
        func actions() -> [ClientMessage] { frames.filter { $0.type != PluginsOptionsRequest.messageType } }
    }

    private static func hello(_ epoch: String = "e", capabilities: [String] = ["sessions", "plugins.v1"]) -> ServerMessage {
        .hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: epoch,
            brand: Brand(name: "Acme", agentName: "Sam"), actions: [], roots: [], commands: [],
            capabilities: capabilities))
    }

    private func model(capabilities: [String] = ["sessions", "plugins.v1"]) -> (AppModel, Sent) {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(Self.hello(capabilities: capabilities))
        sent.frames = []
        return (model, sent)
    }

    private static let installed: [PluginRow] = [
        PluginRow(
            id: "design-review@acme", name: "design-review", version: "1.4.0", scope: "local", enabled: true,
            description: "Critiques a screen against your design system", marketplace: "acme", updateTo: "1.5.0"),
        PluginRow(
            id: "meeting-notes@claude-plugins-official", name: "meeting-notes", version: "2.1.0", scope: "user",
            enabled: true, description: "Turns a recording into notes and follow-ups",
            marketplace: "claude-plugins-official"),
        PluginRow(
            id: "release-helper@acme", name: "release-helper", version: "0.9.2", scope: "user", enabled: false,
            description: "Drafts release notes from merged work", marketplace: "acme"),
    ]

    private static let marketplaces: [PluginMarketplace] = [
        PluginMarketplace(name: "claude-plugins-official", sourceLabel: nil, pluginCount: 42, checked: "today"),
        PluginMarketplace(name: "acme", sourceLabel: "github.com/acme/plugins", pluginCount: 6, checked: "today"),
    ]

    private static let available: [AvailablePlugin] = [
        AvailablePlugin(id: "budget-watch@claude-plugins-official", name: "budget-watch",
                        description: "Watches spend against a budget", marketplace: "claude-plugins-official"),
        AvailablePlugin(id: "design-review@acme", name: "design-review",
                        description: "Critiques a screen against your design system", marketplace: "acme",
                        version: "1.5.0", installed: true),
        AvailablePlugin(id: "meeting-notes@claude-plugins-official", name: "meeting-notes",
                        description: "Turns a recording into notes and follow-ups",
                        marketplace: "claude-plugins-official", version: "2.1.0", installed: true),
        AvailablePlugin(id: "standup-bot@acme", name: "standup-bot",
                        description: "Summarises a meeting's standup", marketplace: "acme", version: "0.3.0"),
    ]

    private static let options: [PluginOption] = [
        PluginOption(key: "region", title: "Region", description: "Where your reviews are kept", sensitive: false,
                     set: true, value: "us"),
        PluginOption(key: "api_key", title: "API key", description: "Your Acme key", sensitive: true, set: true),
        PluginOption(key: "team", title: "Team", description: "", sensitive: false, set: false),
    ]

    /// The tab shown and its list answered; each row's options answered too
    /// (design-review has some, the others none).
    private func loaded() -> (AppModel, Sent) {
        let (model, sent) = model()
        model.pluginsTabAppeared()
        guard case .pluginsList(let list) = sent.frames.last else {
            XCTFail("plugins.list")
            return (model, sent)
        }
        model.apply(.pluginsState(PluginsStateMessage(
            installed: Self.installed, marketplaces: Self.marketplaces, id: list.id)))
        for frame in sent.frames {
            guard case .pluginsOptions(let ask) = frame else { continue }
            let options = ask.plugin == "design-review@acme" ? Self.options : []
            model.apply(.pluginsOptions(PluginsOptions(plugin: ask.plugin, options: options, id: ask.id)))
        }
        sent.frames = []
        return (model, sent)
    }

    private func row(_ model: AppModel, _ id: String) -> PluginRowPresentation? {
        PluginsPresentation.installed(model.plugins, connected: true).first { $0.id == id }
    }

    // MARK: - Installed

    func testInstalledRowsAndUpdateButton() throws {
        let (model, sent) = loaded()
        let rows = PluginsPresentation.installed(model.plugins, connected: true)
        XCTAssertEqual(rows.map(\.title), ["Design review", "Meeting notes", "Release helper"])
        XCTAssertEqual(rows.map(\.initial), ["D", "M", "R"])
        XCTAssertEqual(rows.map(\.version), ["1.4.0", "2.1.0", "0.9.2"])
        XCTAssertEqual(rows[0].subtitle, "Critiques a screen against your design system · from Acme")
        XCTAssertEqual(rows[1].subtitle, "Turns a recording into notes and follow-ups · from Claude plugins")
        XCTAssertEqual(rows.map(\.isOn), [true, true, false])
        XCTAssertEqual(PluginsPresentation.installedTitle(model.plugins), "Installed · 3")

        // The trailing button reads in the screen's form; only an update shows it.
        XCTAssertEqual(rows[0].updateLabel, "Update to 1.5")
        XCTAssertNil(rows[1].updateLabel)
        XCTAssertEqual(PluginsPresentation.shortVersion("2.0.0"), "2.0")
        XCTAssertEqual(PluginsPresentation.shortVersion("1.5.2"), "1.5.2")
        XCTAssertEqual(PluginsPresentation.shortVersion("1.0"), "1.0")

        // Display names are the app's (R-c11).
        XCTAssertEqual(PluginsPresentation.displayName("claude-plugins-official"), "Claude plugins")
        XCTAssertEqual(PluginsPresentation.displayName("acme-team-plugins"), "Acme team plugins")
        let bare = PluginRow(id: "x@acme", name: "x", version: "1", scope: "user", enabled: true, description: "",
                             marketplace: "acme")
        XCTAssertEqual(PluginRowPresentation(row: bare, state: model.plugins, connected: true).subtitle, "from Acme")

        model.pluginUpdate("design-review@acme")
        XCTAssertEqual(sent.types(), ["plugins.update"])
        guard case .pluginsUpdate(let update) = sent.frames[0] else { return XCTFail("plugins.update") }
        XCTAssertEqual(update.plugin, "design-review@acme")
        XCTAssertNotNil(update.id)
        XCTAssertNotEqual(update.id, update.plugin, "the request's id is its own (R-c10)")
        XCTAssertTrue(try XCTUnwrap(row(model, "design-review@acme")).busy)
        XCTAssertFalse(try XCTUnwrap(row(model, "design-review@acme")).controlsEnabled)
        // A second click while it is out sends nothing.
        model.pluginUpdate("design-review@acme")
        XCTAssertEqual(sent.frames.count, 1)

        var after = Self.installed
        after[0].version = "1.5.0"
        after[0].updateTo = nil
        model.apply(.pluginsState(PluginsStateMessage(installed: after, marketplaces: Self.marketplaces, id: update.id)))
        let done = try XCTUnwrap(row(model, "design-review@acme"))
        XCTAssertFalse(done.busy)
        XCTAssertNil(done.updateLabel)
        XCTAssertEqual(done.version, "1.5.0")

        // The switch turns a row on or off.
        model.pluginSetEnabled("release-helper@acme", enabled: true)
        guard case .pluginsSetEnabled(let toggle) = sent.frames.last else { return XCTFail("plugins.set_enabled") }
        XCTAssertEqual(toggle.plugin, "release-helper@acme")
        XCTAssertTrue(toggle.enabled)
    }

    func testListAsksForEachRowsOptionsOnce() {
        let (model, sent) = model()
        model.pluginsTabAppeared()
        XCTAssertEqual(sent.types(), ["plugins.list"])
        guard case .pluginsList(let list) = sent.frames[0] else { return XCTFail("plugins.list") }
        XCTAssertFalse(list.available, "Installed asks only for the installed list")
        model.apply(.pluginsState(PluginsStateMessage(installed: Self.installed, marketplaces: [], id: list.id)))
        XCTAssertTrue(model.plugins.loaded)
        let asked = sent.frames.compactMap { frame -> String? in
            if case .pluginsOptions(let ask) = frame { return ask.plugin }
            return nil
        }
        XCTAssertEqual(asked, Self.installed.map(\.id))
        // Another list asks for none again.
        sent.frames = []
        model.pluginsTabAppeared()
        guard case .pluginsList(let again) = sent.frames.last else { return XCTFail("plugins.list") }
        model.apply(.pluginsState(PluginsStateMessage(installed: Self.installed, marketplaces: [], id: again.id)))
        XCTAssertEqual(sent.types(), ["plugins.list"])
    }

    func testMenuItems() throws {
        let (model, _) = loaded()
        let configurable = try XCTUnwrap(row(model, "design-review@acme"))
        XCTAssertEqual(configurable.menuItems, [.details, .configure, .checkForUpdate, .uninstall])
        XCTAssertEqual(configurable.menuItems.map(\.label), ["Details", "Configure…", "Check for update", "Uninstall…"])
        let plain = try XCTUnwrap(row(model, "meeting-notes@claude-plugins-official"))
        XCTAssertEqual(plain.menuItems.map(\.label), ["Details", "Check for update", "Uninstall…"])
        XCTAssertEqual(plain.moreHelp, "More for Meeting notes")
    }

    func testDetailsSheet() throws {
        let (model, sent) = loaded()
        model.pluginShowDetails("design-review@acme")
        let sheet = try XCTUnwrap(model.plugins.details)
        XCTAssertEqual(sheet.title, "Design review")
        XCTAssertNil(sheet.text)
        guard case .pluginsDetails(let ask) = sent.frames.last else { return XCTFail("plugins.details") }
        XCTAssertEqual(ask.plugin, "design-review@acme")
        model.apply(.pluginsDetails(PluginsDetails(plugin: ask.plugin, text: "Skills (2): critique", id: ask.id)))
        XCTAssertEqual(model.plugins.details?.text, "Skills (2): critique")
        model.pluginDetailsClosed()
        XCTAssertNil(model.plugins.details)
    }

    // MARK: - Uninstall

    func testUninstallAsksFirst() throws {
        let (model, sent) = loaded()
        model.askToUninstallPlugin("release-helper@acme")
        let ask = try XCTUnwrap(model.plugins.uninstalling)
        XCTAssertEqual(ask.title, "Uninstall Release helper?")
        XCTAssertEqual(ask.message, "Its skills, commands and servers leave every project. Claude Code loses it too.")
        XCTAssertEqual(PluginUninstallConfirmation.cancelLabel, "Cancel")
        XCTAssertEqual(PluginUninstallConfirmation.uninstallLabel, "Uninstall")
        model.cancelPluginUninstall()
        XCTAssertNil(model.plugins.uninstalling)
        XCTAssertEqual(sent.frames, [])

        model.askToUninstallPlugin("release-helper@acme")
        model.confirmPluginUninstall()
        XCTAssertNil(model.plugins.uninstalling)
        XCTAssertEqual(sent.types(), ["plugins.uninstall"])
        guard case .pluginsUninstall(let uninstall) = sent.frames[0] else { return XCTFail("plugins.uninstall") }
        XCTAssertEqual(uninstall.plugin, "release-helper@acme")
        XCTAssertTrue(model.plugins.busy.contains("release-helper@acme"))
    }

    // MARK: - Browse

    func testBrowseFilterAndInstall() throws {
        let (model, sent) = loaded()
        XCTAssertNil(model.plugins.available)
        model.pluginsBrowseShown()
        XCTAssertEqual(sent.types(), ["plugins.list"])
        guard case .pluginsList(let browse) = sent.frames[0] else { return XCTFail("plugins.list") }
        XCTAssertTrue(browse.available)
        // Shown again while it is out, or after it came: asked only once.
        model.pluginsBrowseShown()
        XCTAssertEqual(sent.frames.count, 1)
        model.apply(.pluginsState(PluginsStateMessage(
            installed: Self.installed, available: Self.available, marketplaces: Self.marketplaces, id: browse.id)))
        model.pluginsBrowseShown()
        XCTAssertEqual(sent.actions().count, 1)
        XCTAssertEqual(PluginsPresentation.filterPrompt, "Filter plugins")

        let all = PluginsPresentation.browse(model.plugins, filter: "", connected: true)
        XCTAssertEqual(all.map(\.title), ["Budget watch", "Design review", "Meeting notes", "Standup bot"])
        XCTAssertEqual(all.map(\.installed), [false, true, true, false])
        XCTAssertEqual(all[0].subtitle, "Watches spend against a budget · from Claude plugins")
        // "meet" keeps the names and descriptions that match, either case.
        let meet = PluginsPresentation.browse(model.plugins, filter: " Meet", connected: true)
        XCTAssertEqual(meet.map(\.id), ["meeting-notes@claude-plugins-official", "standup-bot@acme"])

        sent.frames = []
        model.pluginInstall("budget-watch@claude-plugins-official")
        XCTAssertEqual(sent.types(), ["plugins.install"])
        guard case .pluginsInstall(let install) = sent.frames[0] else { return XCTFail("plugins.install") }
        XCTAssertEqual(install.plugin, "budget-watch@claude-plugins-official")
        XCTAssertTrue(PluginsPresentation.browse(model.plugins, filter: "budget", connected: true)[0].busy)

        // A refusal shows its message under the row, and the list is asked for again.
        let refusal = "This plugin runs a command to install. Install it in Claude Code, where you can read the command first."
        model.apply(.error(ErrorMessage(code: "plugins.refused", message: refusal, id: install.id)))
        let refused = PluginsPresentation.browse(model.plugins, filter: "budget", connected: true)[0]
        XCTAssertFalse(refused.busy)
        XCTAssertEqual(refused.error, refusal)
        XCTAssertEqual(sent.types(), ["plugins.install", "plugins.list"])
        guard case .pluginsList(let relist) = sent.frames[1] else { return XCTFail("plugins.list") }
        XCTAssertTrue(relist.available, "Browse has been shown: the re-list keeps it fresh")
    }

    func testAChangesErrorShowsUnderTheRowAndRelists() throws {
        let (model, sent) = loaded()
        model.pluginSetEnabled("meeting-notes@claude-plugins-official", enabled: false)
        guard case .pluginsSetEnabled(let toggle) = sent.frames.last else { return XCTFail("plugins.set_enabled") }
        // A synced plugin: the gateway's own words are shown (R-c12).
        let words = "This plugin comes with your Claude account; change it in Claude Code"
        model.apply(.error(ErrorMessage(code: "plugins.refused", message: words, id: toggle.id)))
        let refused = try XCTUnwrap(row(model, "meeting-notes@claude-plugins-official"))
        XCTAssertEqual(refused.error, words)
        XCTAssertFalse(refused.busy)
        XCTAssertEqual(sent.types(), ["plugins.set_enabled", "plugins.list"])
        guard case .pluginsList(let relist) = sent.frames[1] else { return XCTFail("plugins.list") }
        XCTAssertFalse(relist.available)
        // The re-list's answer keeps the row's message until its next action.
        model.apply(.pluginsState(PluginsStateMessage(installed: Self.installed, marketplaces: Self.marketplaces, id: relist.id)))
        XCTAssertEqual(row(model, "meeting-notes@claude-plugins-official")?.error, words)
        model.pluginUpdate("meeting-notes@claude-plugins-official")
        XCTAssertNil(row(model, "meeting-notes@claude-plugins-official")?.error)
    }

    // MARK: - Configure

    func testConfigureSheet() throws {
        let (model, sent) = loaded()
        model.pluginConfigure("design-review@acme")
        guard case .pluginsOptions(let ask) = sent.frames.last else { return XCTFail("plugins.options") }
        XCTAssertEqual(model.plugins.configuring?.title, "Configure Design review")
        XCTAssertNil(model.plugins.configuring?.options, "fresh options are asked for first")
        model.apply(.pluginsOptions(PluginsOptions(plugin: ask.plugin, options: Self.options, id: ask.id)))
        let options = try XCTUnwrap(model.plugins.configuring?.options)

        let fields = options.map(PluginOptionField.init)
        XCTAssertEqual(fields.map(\.secure), [false, true, false])
        XCTAssertEqual(fields[1].placeholder, "Saved", "a sensitive option that is set")
        XCTAssertEqual(fields[2].placeholder, "")
        XCTAssertEqual(fields.map(\.label), ["Region", "API key", "Team"])

        var draft = PluginConfigureDraft(options: options)
        XCTAssertEqual(draft.text["region"], "us")
        XCTAssertEqual(draft.text["api_key"], "", "a sensitive value never reaches the app")
        XCTAssertEqual(draft.changed(options), [:])
        XCTAssertFalse(draft.canSave(options))
        draft.text["team"] = "Design"
        XCTAssertEqual(draft.changed(options), ["team": "Design"], "the key left alone is not sent")
        draft.text["api_key"] = "sk-new"
        draft.text["region"] = "us"
        XCTAssertEqual(draft.changed(options), ["team": "Design", "api_key": "sk-new"])

        sent.frames = []
        model.pluginSaveConfiguration(draft.changed(options))
        XCTAssertEqual(sent.types(), ["plugins.configure"])
        guard case .pluginsConfigure(let save) = sent.frames[0] else { return XCTFail("plugins.configure") }
        XCTAssertEqual(save.plugin, "design-review@acme")
        XCTAssertEqual(save.values, ["team": "Design", "api_key": "sk-new"])
        XCTAssertNotNil(model.plugins.configuring?.saving)
        XCTAssertFalse(model.plugins.configuring?.canCancel ?? true, "Cancel waits for the reply (R-c25)")

        // An error keeps the sheet open with the reason, and re-lists.
        model.apply(.error(ErrorMessage(code: "plugins.invalid", message: "Each value has to fit on one line", id: save.id)))
        XCTAssertEqual(model.plugins.configuring?.error, "Each value has to fit on one line")
        XCTAssertNil(model.plugins.configuring?.saving)
        XCTAssertEqual(model.plugins.configuring?.canCancel, true)
        XCTAssertEqual(sent.types(), ["plugins.configure", "plugins.list"])

        // The answer closes it and refreshes what Configure… knows.
        model.pluginSaveConfiguration(["team": "Design"])
        guard case .pluginsConfigure(let again) = sent.frames.last else { return XCTFail("plugins.configure") }
        let finished = model.plugins.configureFinished
        model.apply(.pluginsOptions(PluginsOptions(plugin: again.plugin, options: Self.options, id: again.id)))
        XCTAssertNil(model.plugins.configuring)
        XCTAssertEqual(model.plugins.configureFinished, finished + 1)

        // Nothing changed: nothing is sent.
        model.pluginConfigure("design-review@acme")
        guard case .pluginsOptions(let reopen) = sent.frames.last else { return XCTFail("plugins.options") }
        model.apply(.pluginsOptions(PluginsOptions(plugin: reopen.plugin, options: Self.options, id: reopen.id)))
        let count = sent.frames.count
        model.pluginSaveConfiguration([:])
        XCTAssertEqual(sent.frames.count, count)
    }

    // MARK: - Marketplaces

    func testMarketplaceRowsAndCheckForUpdates() throws {
        let (model, sent) = loaded()
        let rows = PluginsPresentation.marketplaces(model.plugins, connected: true)
        XCTAssertEqual(rows.map(\.title), ["Claude plugins", "Acme"])
        XCTAssertEqual(rows[0].subtitle, "42 plugins · checked today")
        XCTAssertEqual(rows[1].subtitle, "6 plugins · github.com/acme/plugins · checked today")
        XCTAssertEqual(PluginsPresentation.marketplacesTitle(model.plugins), "Marketplaces · 2")
        XCTAssertEqual(PluginsPresentation.checkForUpdatesLabel, "Check for updates")
        // `checked` may be "" (R-c12): no "· checked …" then; one plugin is singular.
        let quiet = PluginMarketplace(name: "acme-tools", sourceLabel: "/Users/sam/plugins", pluginCount: 1, checked: "")
        XCTAssertEqual(
            PluginMarketplaceRowPresentation(marketplace: quiet, state: model.plugins, connected: true).subtitle,
            "1 plugin · /Users/sam/plugins")

        model.pluginMarketplaceUpdate("acme")
        XCTAssertEqual(sent.types(), ["plugins.marketplace_update"])
        guard case .pluginsMarketplaceUpdate(let update) = sent.frames[0] else { return XCTFail("plugins.marketplace_update") }
        XCTAssertEqual(update.name, "acme")
        XCTAssertTrue(PluginsPresentation.marketplaces(model.plugins, connected: true)[1].busy)
        model.pluginMarketplaceUpdate("acme")
        XCTAssertEqual(sent.frames.count, 1)
        model.apply(.pluginsState(PluginsStateMessage(installed: Self.installed, marketplaces: Self.marketplaces, id: update.id)))
        XCTAssertFalse(PluginsPresentation.marketplaces(model.plugins, connected: true)[1].busy)
    }

    func testAddMarketplaceSheet() {
        let (model, sent) = loaded()
        XCTAssertEqual(PluginsPresentation.addMarketplaceLabel, "Add marketplace…")
        XCTAssertFalse(PluginMarketplaceAddDraft(source: "  ").canAdd)
        model.pluginMarketplaceAdd(PluginMarketplaceAddDraft(source: " acme/plugins "))
        XCTAssertEqual(sent.types(), ["plugins.marketplace_add"])
        guard case .pluginsMarketplaceAdd(let add) = sent.frames[0] else { return XCTFail("plugins.marketplace_add") }
        XCTAssertEqual(add.source, "acme/plugins")
        XCTAssertFalse(model.plugins.canCancelMarketplaceAdd, "Cancel waits for the reply (R-c25)")
        model.apply(.error(ErrorMessage(code: "plugins.failed", message: "Couldn't reach github.com", id: add.id)))
        XCTAssertEqual(model.plugins.marketplaceAddError, "Couldn't reach github.com")
        XCTAssertTrue(model.plugins.canCancelMarketplaceAdd)
        XCTAssertEqual(sent.types(), ["plugins.marketplace_add", "plugins.list"])

        model.pluginMarketplaceAdd(PluginMarketplaceAddDraft(source: "acme/plugins"))
        guard case .pluginsMarketplaceAdd(let again) = sent.frames.last else { return XCTFail("plugins.marketplace_add") }
        XCTAssertNil(model.plugins.marketplaceAddError)
        let finished = model.plugins.marketplaceAddFinished
        model.apply(.pluginsState(PluginsStateMessage(installed: Self.installed, marketplaces: Self.marketplaces, id: again.id)))
        XCTAssertEqual(model.plugins.marketplaceAddFinished, finished + 1)
        XCTAssertTrue(model.plugins.canCancelMarketplaceAdd)
    }

    // MARK: - copy

    func testFooterCopy() {
        XCTAssertEqual(
            PluginsPresentation.footer,
            "Plugins add skills, commands and MCP servers. Plugins you install in Claude Code show up here too; a change applies to new chats.")
        XCTAssertEqual(PluginsPresentation.Segment.allCases.map(\.title), ["Installed", "Browse"])
        XCTAssertEqual(PluginsPresentation.unsupported, "This gateway can't manage plugins")
    }

    func testTabWithoutCapabilityRequestsNothing() {
        let (model, sent) = model(capabilities: ["sessions"])
        XCTAssertFalse(model.pluginsAvailable)
        model.pluginsTabAppeared()
        model.pluginsBrowseShown()
        XCTAssertEqual(sent.frames, [])
    }

    // MARK: - the connection (R-c25)

    func testRequestsEndWhenTheConnectionGoes() throws {
        let (model, sent) = loaded()
        model.pluginUpdate("design-review@acme")
        model.pluginMarketplaceUpdate("acme")
        model.pluginMarketplaceAdd(PluginMarketplaceAddDraft(source: "acme/plugins"))
        XCTAssertFalse(model.plugins.busy.isEmpty)
        model.setConnection(.disconnected)
        XCTAssertTrue(model.plugins.busy.isEmpty)
        XCTAssertTrue(model.plugins.busyMarketplaces.isEmpty)
        XCTAssertTrue(model.plugins.pending.isEmpty)
        XCTAssertNil(model.plugins.addingMarketplace)
        XCTAssertTrue(model.plugins.canCancelMarketplaceAdd)
        // Controls are off and nothing is sent until it is back.
        let offline = try XCTUnwrap(PluginsPresentation.installed(model.plugins, connected: false).first)
        XCTAssertFalse(offline.controlsEnabled)
        XCTAssertFalse(PluginsPresentation.marketplaces(model.plugins, connected: false)[0].controlsEnabled)
        sent.frames = []
        model.pluginUpdate("design-review@acme")
        model.pluginsTabAppeared()
        XCTAssertEqual(sent.frames, [])

        model.setConnection(.connected)
        model.pluginUpdate("design-review@acme")
        model.setConnection(.failed("gone"))
        XCTAssertTrue(model.plugins.busy.isEmpty)
    }

    func testAHelloWhileTheTabIsShownAsksAgain() {
        let (model, sent) = model()
        model.pluginsTabAppeared()
        model.pluginsBrowseShown()
        XCTAssertEqual(sent.types(), ["plugins.list", "plugins.list"])
        // The gateway restarted before answering: the list must not stay "Loading…".
        sent.frames = []
        model.apply(Self.hello("e2"))
        XCTAssertFalse(model.plugins.loaded)
        let lists = sent.frames.compactMap { frame -> PluginsList? in
            if case .pluginsList(let list) = frame { return list }
            return nil
        }
        XCTAssertEqual(lists.map(\.available), [true], "Browse is showing: one list with what's available")
        XCTAssertEqual(model.plugins.pending.count, 1)

        // Gone from screen: a hello asks for nothing.
        model.pluginsTabDisappeared()
        sent.frames = []
        model.apply(Self.hello("e3"))
        XCTAssertFalse(sent.types().contains("plugins.list"))
    }
}
