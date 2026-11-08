import Foundation

// MARK: - MCP servers in Settings (v0.18 §3.1, rulings 7–15)

/// What Settings → MCP servers holds: the gateway's last list, the rows
/// with a request out (`busy`, a spinner until its reply), and refusals.
/// The gateway answers every `mcp.*` request with `mcp.servers` (same id)
/// or an `error` with the id; an `mcp.servers` with no id (a sign-in that
/// finished) replaces the rows and ends no wait.
struct McpServersState: Equatable, Sendable {
    var rows: [McpServerRow] = []
    /// Whether status came from a running engine on Settings' folder.
    var live: Bool = false
    /// Server names with a request out.
    var busy: Set<String> = []
    /// A refusal or failure that names no row (an error with no id).
    var lastError: String? = nil
    /// A refusal for one row, shown under it until its next action.
    var rowErrors: [String: String] = [:]
    /// Whether a list has arrived since this gateway's hello.
    var loaded: Bool = false
    /// Request id -> the row it is for (`""` for the list itself).
    var pending: [String: String] = [:]
}

/// The tabs of Settings, in the window's order (AR1's toolbar).
enum SettingsTab: String, CaseIterable, Sendable {
    case general, gateway, mcpServers, plugins, voice, appearance, labs

    /// The tabs Settings shows: Labs, last, only while it has an item (v0.25 §2.1).
    static func visible(labs: Bool) -> [SettingsTab] {
        allCases.filter { $0 != .labs || labs }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .gateway: "Gateway"
        case .mcpServers: "MCP servers"
        case .plugins: "Plugins"
        case .voice: "Voice"
        case .appearance: "Appearance"
        case .labs: "Labs"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .gateway: "server.rack"
        case .mcpServers: "powerplug"
        case .plugins: "puzzlepiece.extension"
        case .voice: "waveform"
        case .appearance: "paintbrush"
        case .labs: "flask"
        }
    }

    /// The tab a typed `/mcp` or `/plugin` opens (ruling 15), matched the
    /// way the gateway reads a command: the word, then a blank or the end.
    static func command(in text: String) -> SettingsTab? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = trimmed.dropFirst().prefix { !$0.isWhitespace && !$0.isNewline }
        switch word {
        case "mcp": return .mcpServers
        case "plugin": return .plugins
        default: return nil
        }
    }
}

/// Remove asks first (ruling 11).
struct McpRemoveConfirmation: Equatable, Sendable, Identifiable {
    static let cancelLabel = "Cancel"
    static let removeLabel = "Remove"

    let name: String
    let title: String
    let message: String

    var id: String { name }

    init(row: McpServerRow, brand: String) {
        name = row.name
        title = "Remove \(McpServersPresentation.displayName(row, brand: brand))?"
        let tools = row.toolCount.map { "its \($0) \($0 == 1 ? "tool" : "tools")" } ?? "its tools"
        let reach = row.group == .local ? "\(tools) in \(brand)." : "\(tools), in any project."
        message = "The agent can no longer use \(reach) Claude Code loses it too: it's the same list. You can add it again later."
    }
}

/// What AR3's Add sheet holds while it is open.
struct McpAddDraft: Equatable, Sendable {
    enum ConnectsBy: String, CaseIterable, Sendable {
        case web, program

        var label: String {
            switch self {
            case .web: "A web address"
            case .program: "A program on this Mac"
            }
        }
    }

    static let invalidName = "Use letters, numbers, - and _ only"

    var name: String = ""
    var connectsBy: ConnectsBy = .web
    var address: String = ""
    var command: String = ""
    var scope: McpAdd.Where = .user

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTarget: String {
        (connectsBy == .web ? address : command).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line under Name: nothing while it is empty (Add is off then).
    func nameError(existing: [String]) -> String? {
        let name = trimmedName
        guard !name.isEmpty else { return nil }
        guard name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return Self.invalidName }
        if existing.contains(name) { return "There's already a server called \(name)" }
        return nil
    }

    func canAdd(existing: [String]) -> Bool {
        !trimmedName.isEmpty && nameError(existing: existing) == nil && !trimmedTarget.isEmpty
    }

    func message(id: String) -> McpAdd {
        switch connectsBy {
        case .web: McpAdd(name: trimmedName, transport: .http, url: trimmedTarget, where: scope, id: id)
        case .program: McpAdd(name: trimmedName, transport: .stdio, command: trimmedTarget, where: scope, id: id)
        }
    }
}

extension AppModel {
    /// The gateway can manage MCP servers (`mcp.v1` in hello).
    var mcpAvailable: Bool { hello?.capabilities.contains(McpCapability.name) == true }

    /// Settings at `tab`: the tab is chosen here and the main window's
    /// `openSettings` brings the window forward (it watches the count).
    func openSettings(at tab: SettingsTab) {
        settingsTab = tab
        settingsOpenRequests += 1
    }

    /// `/mcp` or `/plugin` typed in a composer: Settings opens at that tab
    /// and nothing is sent. Returns whether `text` was one of them.
    @discardableResult
    func runSettingsCommand(_ text: String) -> Bool {
        guard let tab = SettingsTab.command(in: text) else { return false }
        openSettings(at: tab)
        return true
    }

    /// The tab came on screen: ask for the servers as they stand.
    func mcpTabAppeared() {
        settingsTabsShowing.insert(.mcpServers)
        guard mcpAvailable, settingsConnected else { return }
        let id = Self.requestId()
        mcpServers.pending[id] = ""
        send(.mcpList(McpList(id: id)))
    }

    func mcpTabDisappeared() {
        settingsTabsShowing.remove(.mcpServers)
    }

    private func mcpRow(_ name: String) -> McpServerRow? {
        mcpServers.rows.first { $0.name == name }
    }

    /// One request for one row: none while that row already has one out.
    private func mcpRequest(for name: String, _ make: (String) -> ClientMessage) {
        guard mcpAvailable, settingsConnected, !mcpServers.busy.contains(name) else { return }
        let id = Self.requestId()
        mcpServers.busy.insert(name)
        mcpServers.pending[id] = name
        mcpServers.rowErrors[name] = nil
        mcpServers.lastError = nil
        send(make(id))
    }

    func mcpToggle(_ name: String, enabled: Bool) {
        guard mcpRow(name)?.canToggle == true else { return }
        mcpRequest(for: name) { .mcpToggle(McpToggle(name: name, enabled: enabled, id: $0)) }
    }

    func mcpSignIn(_ name: String) {
        mcpRequest(for: name) { .mcpSignIn(McpSignIn(name: name, id: $0)) }
    }

    func mcpSignOut(_ name: String) {
        guard mcpRow(name)?.canSignOut == true else { return }
        mcpRequest(for: name) { .mcpSignOut(McpSignOut(name: name, id: $0)) }
    }

    func mcpReconnect(_ name: String) {
        mcpRequest(for: name) { .mcpReconnect(McpReconnect(name: name, id: $0)) }
    }

    func mcpSetPolicy(server: String, tool: String, policy: McpToolRow.Policy?) {
        guard let row = mcpRow(server), row.group != .core else { return }
        mcpRequest(for: server) { .mcpToolPolicy(McpToolPolicy(server: server, tool: tool, policy: policy, id: $0)) }
    }

    /// Remove… : asks first; only user and local rows offer it.
    func askToRemoveMcp(_ name: String) {
        guard let row = mcpRow(name), row.canRemove, !mcpServers.busy.contains(name) else { return }
        mcpRemoving = McpRemoveConfirmation(row: row, brand: brand.name)
    }

    func cancelMcpRemove() {
        mcpRemoving = nil
    }

    func confirmMcpRemove() {
        guard let ask = mcpRemoving else { return }
        mcpRemoving = nil
        mcpRequest(for: ask.name) { .mcpRemove(McpRemove(name: ask.name, id: $0)) }
    }

    /// Add (AR3): the sheet stays open, Adding…, until the reply; a
    /// refusal keeps it open with the gateway's reason.
    func mcpAdd(_ draft: McpAddDraft) {
        guard mcpAvailable, settingsConnected, mcpAdding == nil, draft.canAdd(existing: mcpServers.rows.map(\.name)) else { return }
        let id = Self.requestId()
        mcpAdding = id
        mcpAddError = nil
        mcpServers.lastError = nil
        send(.mcpAdd(draft.message(id: id)))
    }

    /// Cancel is off while an Add is out (R-c25): its reply would land on a closed sheet.
    var mcpAddCanCancel: Bool { mcpAdding == nil }

    /// The Add sheet closed without adding.
    func mcpAddDismissed() {
        mcpAddError = nil
    }

    func applyMcpServers(_ list: McpServers) {
        mcpServers.rows = list.servers
        mcpServers.live = list.live
        mcpServers.loaded = true
        guard let id = list.id else { return }
        if let name = mcpServers.pending.removeValue(forKey: id), !name.isEmpty {
            mcpServers.busy.remove(name)
        }
        if id == mcpAdding {
            mcpAdding = nil
            mcpAddFinished += 1
        }
    }

    /// An `error` for an `mcp.*` request: under its row, or in the Add
    /// sheet. One with no id and an `mcp.` code is shown over the list.
    func applyMcpError(_ error: ErrorMessage) {
        guard let id = error.id else {
            if error.code.hasPrefix("mcp.") { mcpServers.lastError = error.message }
            return
        }
        if let name = mcpServers.pending.removeValue(forKey: id) {
            if name.isEmpty {
                mcpServers.lastError = error.message
            } else {
                mcpServers.busy.remove(name)
                mcpServers.rowErrors[name] = error.message
            }
        }
        if id == mcpAdding {
            mcpAdding = nil
            mcpAddError = error.message
        }
    }

    /// The connection went: nothing in flight will be answered (R-c25).
    /// The rows stay on screen, their controls off until it is back.
    func endMcpRequests() {
        mcpServers.busy = []
        mcpServers.pending = [:]
        mcpAdding = nil
    }

    /// After a hello: the tabs on screen ask for their lists again, so one
    /// asked of the gateway before isn't left "Loading…" (R-c25).
    func resumeSettingsLists() {
        if settingsTabsShowing.contains(.mcpServers) { mcpTabAppeared() }
        if settingsTabsShowing.contains(.plugins) { requestPluginsList(available: pluginsBrowseShowing) }
    }

    /// A new hello: the list is asked for afresh.
    func resetMcpServers() {
        mcpServers = McpServersState()
        mcpRemoving = nil
        mcpAdding = nil
        mcpAddError = nil
    }
}
