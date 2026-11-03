import Foundation
import XCTest

@testable import Portico

/// v0.18 §3.1 (screens AR1–AR3, rulings 7–15): Settings → MCP servers,
/// `/mcp` and `/plugin` opening Settings at a tab, and the tabs' selection.
@MainActor
final class McpSettingsTests: XCTestCase {

    private final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func model(brand: String = "Acme", capabilities: [String] = ["sessions", "mcp.v1"]) -> (AppModel, Sent) {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: "e",
            brand: Brand(name: brand, agentName: "Sam"), actions: [], roots: [], commands: [],
            capabilities: capabilities)))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 3, folder: "/tmp/acme", alias: nil, state: .idle, created: "2026-11-03T12:00:00Z"),
        ])))
        sent.frames = []
        return (model, sent)
    }

    private static func tool(_ name: String, readOnly: Bool = false) -> McpToolRow {
        McpToolRow(name: name, description: "Does \(name)", readOnly: readOnly, policy: readOnly ? .allow : .ask)
    }

    private static func row(
        _ name: String, title: String? = nil, group: McpServerRow.Group, status: McpServerRow.Status = .connected,
        detail: String = "Connected · 2 tools", transport: McpServerRow.Transport = .http, toolCount: Int? = 2,
        tools: [McpToolRow] = [], canToggle: Bool = true, canRemove: Bool = true, canSignOut: Bool = false
    ) -> McpServerRow {
        McpServerRow(
            name: name, title: title ?? name, group: group, transport: transport, status: status, detail: detail,
            toolCount: toolCount, tools: tools, account: nil, canToggle: canToggle, canRemove: canRemove,
            canSignOut: canSignOut)
    }

    private static let fixture: [McpServerRow] = [
        row("portico", group: .core, detail: "Connected · the viewer, files and screen · 9 tools", transport: .sdk,
            toolCount: 9, canToggle: false, canRemove: false),
        row("acme-tracker", title: "Acme Tracker", group: .user, toolCount: 8,
            tools: (0..<8).map { tool("tool_\($0)", readOnly: $0 < 2) }, canSignOut: true),
        row("acme-calendar", group: .user, status: .needsAuth, detail: "Needs you to sign in", toolCount: nil),
        row("docs", title: "Docs search", group: .user, status: .failed,
            detail: "Couldn't start: it stopped as soon as it opened", transport: .stdio, toolCount: nil),
        row("design-files", group: .shipped, status: .off, detail: "Off for you · it stays off through updates",
            transport: .stdio, toolCount: nil, canRemove: false),
    ]

    private func loaded(brand: String = "Acme") -> (AppModel, Sent) {
        let (model, sent) = model(brand: brand)
        model.apply(.mcpServers(McpServers(servers: Self.fixture, live: true)))
        return (model, sent)
    }

    // MARK: - tabs

    func testTabsInOrder() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["General", "Gateway", "MCP servers", "Plugins", "Voice", "Appearance"])
        let (model, _) = model()
        XCTAssertEqual(model.settingsTab, .general)
        model.openSettings(at: .plugins)
        XCTAssertEqual(model.settingsTab, .plugins)
        XCTAssertEqual(model.settingsOpenRequests, 1)
    }

    // MARK: - /mcp and /plugin

    func testSlashMcpOpensSettingsAndSendsNothing() {
        let (model, sent) = model()
        model.setDraft("/mcp", for: 3)
        model.sendMessage(chat: 3, text: model.draft(for: 3))
        XCTAssertEqual(model.settingsTab, .mcpServers)
        XCTAssertEqual(model.settingsOpenRequests, 1)
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(model.draft(for: 3), "")

        model.setDraft("/plugin ", for: 3)
        model.sendMessage(chat: 3, text: model.draft(for: 3))
        XCTAssertEqual(model.settingsTab, .plugins)
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(model.draft(for: 3), "")

        model.setDraft("/mcpfoo", for: 3)
        model.sendMessage(chat: 3, text: model.draft(for: 3))
        XCTAssertEqual(sent.types(), ["message.send"])
        guard case .messageSend(let message) = sent.frames.first else { return XCTFail("message.send") }
        XCTAssertEqual(message.text, "/mcpfoo")
        XCTAssertEqual(model.settingsOpenRequests, 2)
    }

    func testSlashListOffersBothInThePorticoGroup() {
        let names = SlashCompletion.porticoCommands.map(\.name)
        XCTAssertTrue(names.contains("mcp"))
        XCTAssertTrue(names.contains("plugin"))
        XCTAssertEqual(SlashCompletion.porticoCommands.first { $0.name == "mcp" }?.description, "Manage MCP servers")
        XCTAssertEqual(SlashCompletion.porticoCommands.first { $0.name == "plugin" }?.description, "Manage plugins")
        XCTAssertEqual(SettingsTab.command(in: "/mcp"), .mcpServers)
        XCTAssertEqual(SettingsTab.command(in: " /plugin\n"), .plugins)
        XCTAssertNil(SettingsTab.command(in: "/mcpfoo"))
        XCTAssertNil(SettingsTab.command(in: "tell me about /mcp"))
    }

    func testStartComposerSlashMcpOpensSettings() {
        let (model, sent) = model()
        model.startDraft = "/mcp"
        XCTAssertTrue(model.runSettingsCommand(model.startDraft))
        XCTAssertEqual(model.settingsTab, .mcpServers)
        XCTAssertEqual(sent.frames, [])
    }

    // MARK: - AR1: groups and copy

    func testGroupsAndCopy() {
        let (model, _) = loaded()
        let sections = McpServersPresentation.sections(model.mcpServers, brand: "Acme")
        XCTAssertEqual(sections.map(\.title), ["All your projects", "Acme only", "Built into Acme"])
        XCTAssertEqual(sections.first?.trailing, "User scope")
        XCTAssertEqual(sections[1].trailing, nil)

        let shipped = try! XCTUnwrap(sections[1].rows.first)
        XCTAssertEqual(shipped.badge, "Ships with Acme")
        XCTAssertTrue(shipped.showsSwitch)

        let core = try! XCTUnwrap(sections[2].rows.first)
        XCTAssertEqual(core.title, "Acme", "the built-in portico row reads as the brand")
        XCTAssertEqual(core.initial, "A")
        XCTAssertTrue(core.builtIn)
        XCTAssertEqual(McpServersPresentation.builtInLabel, "Built in")
        XCTAssertFalse(core.showsSwitch)
        XCTAssertFalse(core.showsMore)
        XCTAssertFalse(core.canRemove)

        XCTAssertEqual(sections[0].rows.map(\.title), ["Acme Tracker", "acme-calendar", "Docs search"])
        XCTAssertEqual(sections[0].rows.map(\.initial), ["A", "A", "D"])
        XCTAssertEqual(sections[0].rows.map(\.status), ["Connected · 2 tools", "Needs you to sign in", "Couldn't start: it stopped as soon as it opened"])
        XCTAssertEqual(sections[0].rows.map(\.tone), [.connected, .waiting, .failed])
        XCTAssertEqual(sections[1].rows[0].tone, .off)
        XCTAssertFalse(sections[1].rows[0].isOn)
        XCTAssertEqual(sections[0].rows[1].primary, .signIn)
        XCTAssertEqual(sections[0].rows[2].primary, .reconnect)
        XCTAssertNil(sections[0].rows[0].primary)

        XCTAssertEqual(McpServersPresentation.intro, "Tools the agent can use. Servers you add in Claude Code show up here too.")
        XCTAssertEqual(McpServersPresentation.addLabel, "Add server…")
        XCTAssertEqual(
            McpServersPresentation.footer(brand: "Acme"),
            "Built-in servers are how Acme works, so they can't be turned off. A server that ships with Acme can be turned off for you, and stays off through updates. A change applies to new chats; an open chat picks it up when it reconnects.")
        XCTAssertEqual(McpServersPresentation.unsupported, "This gateway can't manage MCP servers")
    }

    func testAccountGroupIsLastAndToggleOnly() {
        let rows = [
            Self.row("portico", group: .core, transport: .sdk, canToggle: false, canRemove: false),
            Self.row("claude-ai-drive", title: "Drive", group: .account, canRemove: false),
            Self.row("sales", group: .local),
        ]
        let state = McpServersState(rows: rows, live: true)
        let sections = McpServersPresentation.sections(state, brand: "Acme")
        XCTAssertEqual(sections.map(\.title), ["Acme only", "Built into Acme", "From your Claude account"])
        let account = sections[2].rows[0]
        XCTAssertTrue(account.showsSwitch)
        XCTAssertFalse(account.canRemove)
    }

    func testCoreRowWithNoEngineKeepsTheGatewaysDetail() {
        let rows = [Self.row("portico", group: .core, status: .unknown, detail: "The viewer, files and screen",
                             transport: .sdk, toolCount: nil, canToggle: false, canRemove: false)]
        let row = McpServersPresentation.sections(McpServersState(rows: rows, live: false), brand: "Acme")[0].rows[0]
        XCTAssertEqual(row.status, "The viewer, files and screen")
        XCTAssertEqual(row.title, "Acme")
    }

    func testTabWithoutCapabilityRequestsNothing() {
        let (model, sent) = model(capabilities: ["sessions"])
        XCTAssertFalse(model.mcpAvailable)
        model.mcpTabAppeared()
        XCTAssertEqual(sent.frames, [])
    }

    // MARK: - row actions

    func testRowActionsSendFrames() {
        let (model, sent) = loaded()
        model.mcpToggle("acme-tracker", enabled: false)
        model.mcpSignIn("acme-calendar")
        model.mcpReconnect("docs")
        XCTAssertEqual(sent.types(), ["mcp.toggle", "mcp.sign_in", "mcp.reconnect"])
        guard case .mcpToggle(let toggle) = sent.frames[0] else { return XCTFail("mcp.toggle") }
        XCTAssertEqual(toggle.name, "acme-tracker")
        XCTAssertFalse(toggle.enabled)
        XCTAssertNotNil(toggle.id)
        XCTAssertEqual(model.mcpServers.busy, ["acme-tracker", "acme-calendar", "docs"])

        // A busy row shows a spinner and its controls are off; a second click sends nothing.
        let busyRow = McpServersPresentation.sections(model.mcpServers, brand: "Acme")[0].rows[0]
        XCTAssertTrue(busyRow.busy)
        XCTAssertFalse(busyRow.controlsEnabled)
        model.mcpToggle("acme-tracker", enabled: true)
        XCTAssertEqual(sent.frames.count, 3)

        // The reply (same id) ends the wait; rows are replaced.
        var after = Self.fixture
        after[1].status = .off
        after[1].detail = "Off"
        model.apply(.mcpServers(McpServers(servers: after, live: true, id: toggle.id)))
        XCTAssertFalse(model.mcpServers.busy.contains("acme-tracker"))
        XCTAssertTrue(model.mcpServers.busy.contains("docs"))
        let row = McpServersPresentation.sections(model.mcpServers, brand: "Acme")[0].rows[0]
        XCTAssertFalse(row.busy)
        XCTAssertTrue(row.controlsEnabled)
        XCTAssertFalse(row.isOn)
        XCTAssertEqual(row.status, "Off")
    }

    func testAnErrorWithTheIdShowsUnderTheRow() {
        let (model, sent) = loaded()
        model.mcpReconnect("docs")
        guard case .mcpReconnect(let reconnect) = sent.frames.last else { return XCTFail("mcp.reconnect") }
        model.apply(.error(ErrorMessage(code: "mcp.refused", message: "There's no server called docs", id: reconnect.id)))
        XCTAssertFalse(model.mcpServers.busy.contains("docs"))
        XCTAssertEqual(model.mcpServers.rowErrors["docs"], "There's no server called docs")
        let row = McpServersPresentation.sections(model.mcpServers, brand: "Acme")[0].rows[2]
        XCTAssertEqual(row.error, "There's no server called docs")
        // A built-in row offers no switch, so the model sends no toggle for it.
        model.mcpToggle("portico", enabled: false)
        XCTAssertEqual(sent.types(), ["mcp.reconnect"])
        // An error with no id (a sign-in that failed later) is shown over the list.
        model.apply(.error(ErrorMessage(code: "mcp.failed", message: "Sign-in was cancelled")))
        XCTAssertEqual(model.mcpServers.lastError, "Sign-in was cancelled")
    }

    // MARK: - Remove asks first

    func testRemoveAsksFirst() throws {
        let (model, sent) = loaded()
        model.askToRemoveMcp("acme-tracker")
        let ask = try XCTUnwrap(model.mcpRemoving)
        XCTAssertEqual(ask.title, "Remove Acme Tracker?")
        XCTAssertEqual(
            ask.message,
            "The agent can no longer use its 8 tools, in any project. Claude Code loses it too: it's the same list. You can add it again later.")
        XCTAssertEqual(McpRemoveConfirmation.cancelLabel, "Cancel")
        XCTAssertEqual(McpRemoveConfirmation.removeLabel, "Remove")
        model.cancelMcpRemove()
        XCTAssertNil(model.mcpRemoving)
        XCTAssertEqual(sent.frames, [])

        model.askToRemoveMcp("acme-tracker")
        model.confirmMcpRemove()
        XCTAssertNil(model.mcpRemoving)
        XCTAssertEqual(sent.types(), ["mcp.remove"])
        guard case .mcpRemove(let remove) = sent.frames[0] else { return XCTFail("mcp.remove") }
        XCTAssertEqual(remove.name, "acme-tracker")
        XCTAssertTrue(model.mcpServers.busy.contains("acme-tracker"))

        // Shipped and core rows have no Remove; asking does nothing.
        let sections = McpServersPresentation.sections(model.mcpServers, brand: "Acme")
        XCTAssertFalse(sections[1].rows[0].canRemove)
        XCTAssertFalse(sections[2].rows[0].canRemove)
        model.askToRemoveMcp("design-files")
        model.askToRemoveMcp("portico")
        XCTAssertNil(model.mcpRemoving)
    }

    func testRemoveCopyForLocalAndWithoutStatus() {
        let local = Self.row("sales", title: "Sales data", group: .local, toolCount: 1)
        XCTAssertEqual(
            McpRemoveConfirmation(row: local, brand: "Acme").message,
            "The agent can no longer use its 1 tool in Acme. Claude Code loses it too: it's the same list. You can add it again later.")
        let quiet = Self.row("sales", group: .user, status: .unknown, toolCount: nil)
        XCTAssertEqual(
            McpRemoveConfirmation(row: quiet, brand: "Acme").message,
            "The agent can no longer use its tools, in any project. Claude Code loses it too: it's the same list. You can add it again later.")
    }

    // MARK: - AR3: Add

    func testAddSheetValidatesAndSends() throws {
        var draft = McpAddDraft()
        XCTAssertFalse(draft.canAdd(existing: []))
        draft.name = "acme tracker"
        draft.address = "https://mcp.acme.example/"
        XCTAssertEqual(draft.nameError(existing: []), "Use letters, numbers, - and _ only")
        XCTAssertFalse(draft.canAdd(existing: []))
        draft.name = "acme-tracker"
        XCTAssertNil(draft.nameError(existing: []))
        XCTAssertEqual(draft.nameError(existing: ["acme-tracker"]), "There's already a server called acme-tracker")
        XCTAssertTrue(draft.canAdd(existing: []))
        draft.address = "  "
        XCTAssertFalse(draft.canAdd(existing: []))

        let (model, sent) = loaded()
        var web = McpAddDraft(name: "acme-tasks", address: " https://mcp.acme.example/ ")
        web.scope = .local
        model.mcpAdd(web)
        guard case .mcpAdd(let add) = sent.frames.last else { return XCTFail("mcp.add") }
        XCTAssertEqual(add.name, "acme-tasks")
        XCTAssertEqual(add.transport, .http)
        XCTAssertEqual(add.url, "https://mcp.acme.example/")
        XCTAssertNil(add.command)
        XCTAssertEqual(add.where, .local)
        XCTAssertNotNil(model.mcpAdding)

        // The reply closes the sheet; an error keeps it open with the reason.
        model.apply(.error(ErrorMessage(code: "mcp.failed", message: "There's already a server called acme-tasks", id: add.id)))
        XCTAssertNil(model.mcpAdding)
        XCTAssertEqual(model.mcpAddError, "There's already a server called acme-tasks")

        var program = McpAddDraft(name: "docs-search")
        program.connectsBy = .program
        program.command = "npx -y acme-docs --port 3000"
        XCTAssertTrue(program.canAdd(existing: []))
        model.mcpAdd(program)
        guard case .mcpAdd(let stdio) = sent.frames.last else { return XCTFail("mcp.add") }
        XCTAssertEqual(stdio.transport, .stdio)
        XCTAssertEqual(stdio.command, "npx -y acme-docs --port 3000")
        XCTAssertNil(stdio.url)
        XCTAssertEqual(stdio.where, .user)
        XCTAssertNil(model.mcpAddError)
        model.apply(.mcpServers(McpServers(servers: Self.fixture, live: true, id: stdio.id)))
        XCTAssertNil(model.mcpAdding)
        XCTAssertTrue(model.mcpAddFinished > 0)

        XCTAssertEqual(McpAddPresentation.title, "Add an MCP server")
        XCTAssertEqual(McpAddPresentation.nameLabel, "Name")
        XCTAssertEqual(McpAddPresentation.connectsByLabel, "Connects by")
        XCTAssertEqual(McpAddDraft.ConnectsBy.web.label, "A web address")
        XCTAssertEqual(McpAddDraft.ConnectsBy.program.label, "A program on this Mac")
        XCTAssertEqual(McpAddPresentation.addressLabel, "Address")
        XCTAssertEqual(McpAddPresentation.whereLabel, "Where it works")
        XCTAssertEqual(McpAddPresentation.scopeTitle(.user, brand: "Acme"), "All your projects")
        XCTAssertEqual(McpAddPresentation.scopeTitle(.local, brand: "Acme"), "Acme only")
        XCTAssertEqual(McpAddPresentation.scopeHelp(.user, brand: "Acme"), "You, anywhere on this Mac. Claude Code uses it too.")
        XCTAssertEqual(
            McpAddPresentation.scopeHelp(.local, brand: "Acme"),
            "You, only when you work with Acme. Nothing is written into Acme's own files.")
        XCTAssertEqual(
            McpAddPresentation.signInNote(brand: "Acme"),
            "If the server needs you to sign in, Acme opens your browser after you add it.")
    }

    // MARK: - AR2: details

    func testDetailsShowsToolsAndPolicy() throws {
        let (model, sent) = loaded()
        let row = try XCTUnwrap(model.mcpServers.rows.first { $0.name == "acme-tracker" })
        let details = McpDetailsPresentation(row: row, brand: "Acme", expanded: false)
        XCTAssertEqual(details.toolsTitle, "Tools · 8")
        XCTAssertEqual(details.tools.count, 5)
        XCTAssertEqual(details.moreText, "+ 3 more.")
        XCTAssertEqual(McpDetailsPresentation.toolsNote, "Tools that only read run without asking unless you change them here.")
        XCTAssertEqual(details.tools[0].policyLabel, "Runs without asking")
        XCTAssertEqual(details.tools[2].policyLabel, "Asks first")
        XCTAssertEqual(McpToolRow.Policy.allCases.map(\.label), ["Runs without asking", "Asks first"])
        XCTAssertEqual(details.header, "Connected · All your projects")
        XCTAssertEqual(McpDetailsPresentation.backLabel, "MCP servers")
        XCTAssertTrue(details.showsSignOut)
        XCTAssertTrue(details.showsRemove)
        XCTAssertEqual(details.toggleLabel, "Turn off")

        let open = McpDetailsPresentation(row: row, brand: "Acme", expanded: true)
        XCTAssertEqual(open.tools.count, 8)
        XCTAssertNil(open.moreText)

        model.mcpSetPolicy(server: "acme-tracker", tool: "tool_2", policy: .allow)
        XCTAssertEqual(sent.types(), ["mcp.tool_policy"])
        guard case .mcpToolPolicy(let policy) = sent.frames[0] else { return XCTFail("mcp.tool_policy") }
        XCTAssertEqual(policy.server, "acme-tracker")
        XCTAssertEqual(policy.tool, "tool_2")
        XCTAssertEqual(policy.policy, .allow)
    }

    func testDetailsHeaderNamesTheAccountAndBuiltInsCannotChangeTools() {
        var row = Self.row("acme-tracker", title: "Acme Tracker", group: .user, tools: [Self.tool("list_tasks", readOnly: true)])
        row.account = "sam@acme.example"
        XCTAssertEqual(
            McpDetailsPresentation(row: row, brand: "Acme", expanded: false).header,
            "Connected · All your projects · signed in as sam@acme.example")
        let core = Self.row("knowledge", group: .core, tools: [Self.tool("search", readOnly: true)], canToggle: false, canRemove: false)
        let details = McpDetailsPresentation(row: core, brand: "Acme", expanded: false)
        XCTAssertFalse(details.policyEditable)
        XCTAssertEqual(details.header, "Connected · Built into Acme")
        XCTAssertNil(details.toggleLabel)
        XCTAssertEqual(details.tools.count, 1)
        XCTAssertNil(details.moreText)
    }

    // MARK: - the list

    func testListIsRequestedOnAppear() {
        let (model, sent) = model()
        model.mcpTabAppeared()
        XCTAssertEqual(sent.types(), ["mcp.list"])
        guard case .mcpList(let list) = sent.frames[0] else { return XCTFail("mcp.list") }
        XCTAssertNotNil(list.id)
        XCTAssertFalse(model.mcpServers.loaded)
        model.apply(.mcpServers(McpServers(servers: Self.fixture, live: true, id: list.id)))
        XCTAssertTrue(model.mcpServers.loaded)
        XCTAssertEqual(model.mcpServers.rows.count, 5)
        XCTAssertTrue(model.mcpServers.live)
    }

    func testPushedListReplacesRows() {
        let (model, _) = loaded()
        model.mcpSignIn("acme-calendar")
        var signedIn = Self.fixture
        signedIn[2].status = .connected
        signedIn[2].detail = "Connected · 4 tools"
        // A pushed list (no id) replaces the rows but ends no wait.
        model.apply(.mcpServers(McpServers(servers: signedIn, live: false)))
        XCTAssertEqual(model.mcpServers.rows[2].status, .connected)
        XCTAssertFalse(model.mcpServers.live)
        XCTAssertTrue(model.mcpServers.busy.contains("acme-calendar"))
    }

    func testANewHelloForgetsTheList() {
        let (model, _) = loaded()
        model.mcpReconnect("docs")
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: "e2",
            brand: Brand(name: "Acme", agentName: "Sam"), actions: [], roots: [], commands: [],
            capabilities: ["mcp.v1"])))
        XCTAssertEqual(model.mcpServers, McpServersState())
    }

    // MARK: - R-c25: in flight, the connection, a hello before the list

    func testAddCancelWaitsForTheReply() {
        let (model, sent) = loaded()
        XCTAssertTrue(model.mcpAddCanCancel)
        model.mcpAdd(McpAddDraft(name: "acme-tasks", address: "https://mcp.acme.example/"))
        guard case .mcpAdd(let add) = sent.frames.last else { return XCTFail("mcp.add") }
        XCTAssertFalse(model.mcpAddCanCancel, "Cancel is off while the Add is out")
        model.apply(.mcpServers(McpServers(servers: Self.fixture, live: true, id: add.id)))
        XCTAssertTrue(model.mcpAddCanCancel)
    }

    func testRequestsEndWhenTheConnectionGoes() throws {
        let (model, sent) = loaded()
        model.mcpReconnect("docs")
        model.mcpAdd(McpAddDraft(name: "acme-tasks", address: "https://mcp.acme.example/"))
        XCTAssertFalse(model.mcpServers.busy.isEmpty)
        model.setConnection(.disconnected)
        XCTAssertTrue(model.mcpServers.busy.isEmpty)
        XCTAssertTrue(model.mcpServers.pending.isEmpty)
        XCTAssertNil(model.mcpAdding)
        XCTAssertTrue(model.mcpAddCanCancel)
        XCTAssertEqual(model.mcpServers.rows.count, 5, "the rows stay on screen")

        // Controls are off, and nothing is sent, until it is back.
        let offline = McpServersPresentation.sections(model.mcpServers, brand: "Acme", connected: false)[0].rows[0]
        XCTAssertFalse(offline.controlsEnabled)
        sent.frames = []
        model.mcpReconnect("docs")
        model.mcpTabAppeared()
        XCTAssertEqual(sent.frames, [])

        model.setConnection(.connected)
        model.mcpReconnect("docs")
        XCTAssertEqual(sent.types(), ["mcp.reconnect"])
        model.setConnection(.failed("gone"))
        XCTAssertTrue(model.mcpServers.busy.isEmpty)
    }

    func testAHelloBeforeTheFirstListAsksAgain() {
        let (model, sent) = model()
        model.mcpTabAppeared()
        XCTAssertEqual(sent.types(), ["mcp.list"])
        sent.frames = []
        // The gateway restarted before answering: the tab must not stay "Loading…".
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: "e2",
            brand: Brand(name: "Acme", agentName: "Sam"), actions: [], roots: [], commands: [],
            capabilities: ["mcp.v1"])))
        XCTAssertEqual(sent.types().filter { $0 == "mcp.list" }.count, 1)
        XCTAssertEqual(model.mcpServers.pending.count, 1)

        model.mcpTabDisappeared()
        sent.frames = []
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: "e3",
            brand: Brand(name: "Acme", agentName: "Sam"), actions: [], roots: [], commands: [],
            capabilities: ["mcp.v1"])))
        XCTAssertFalse(sent.types().contains("mcp.list"))
    }
}
