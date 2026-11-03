import Foundation

// MARK: - Plugins in Settings (v0.18 §3, screen AR4, rulings 16–19)

/// What Settings → Plugins holds: the gateway's last lists, the requests out
/// (a spinner on their row until the reply), refusals, and the sheets. The
/// gateway answers the list and every change with `plugins.state` (same id),
/// details and options with their own frames, and a refusal with an `error`
/// carrying the id.
struct PluginsState: Equatable, Sendable {
    /// What a request id is waiting for.
    enum Request: Equatable, Sendable {
        case list(available: Bool)
        case plugin(String)
        case marketplace(String)
        case addMarketplace
        case details(String)
        case options(String)
        case configure(String)
    }

    var installed: [PluginRow] = []
    /// Browse's list; `nil` until Browse is first shown and answered.
    var available: [AvailablePlugin]? = nil
    var marketplaces: [PluginMarketplace] = []
    /// Whether a list has arrived since this gateway's hello.
    var loaded: Bool = false
    /// Options read by Configure…, per plugin, for this connection (empty: no settings, R-c29).
    var options: [String: [PluginOption]] = [:]
    /// Plugin ids with a change out.
    var busy: Set<String> = []
    /// Marketplace names with Check for updates out.
    var busyMarketplaces: Set<String> = []
    /// A refusal for one row (by plugin id), shown under it until its next action.
    var rowErrors: [String: String] = [:]
    var marketplaceErrors: [String: String] = [:]
    /// A refusal that names no row.
    var lastError: String? = nil
    /// Request id -> what it is for.
    var pending: [String: Request] = [:]
    /// Uninstall… asked first (ruling 17).
    var uninstalling: PluginUninstallConfirmation? = nil
    var details: PluginDetailsSheet? = nil
    var configuring: PluginConfigureSheet? = nil
    /// Counts saves answered: the Configure sheet closes on a change.
    var configureFinished: Int = 0
    /// The Add marketplace sheet's request out, by id.
    var addingMarketplace: String? = nil
    var marketplaceAddError: String? = nil
    /// Counts marketplace adds answered: the sheet closes on a change.
    var marketplaceAddFinished: Int = 0

    /// What a request that can't go (or won't be answered) says.
    static let notConnected = "Not connected"

    /// Cancel is off while an add is out (R-c25): a reply would land on nothing.
    var canCancelMarketplaceAdd: Bool { addingMarketplace == nil }

    /// Browse's list has come, or is on its way.
    var browseRequested: Bool {
        available != nil || pending.values.contains(.list(available: true))
    }
}

/// The Details sheet: the `claude plugin details` text, once it comes.
struct PluginDetailsSheet: Equatable, Sendable, Identifiable {
    let plugin: String
    let title: String
    var text: String? = nil
    var error: String? = nil
    var id: String { plugin }
}

/// The Configure sheet: fresh options are read first; Save waits for its reply.
struct PluginConfigureSheet: Equatable, Sendable, Identifiable {
    let plugin: String
    let title: String
    var options: [PluginOption]? = nil
    /// The save's request id while it is out.
    var saving: String? = nil
    var error: String? = nil
    var id: String { plugin }
    /// Cancel is off while a save is out (R-c25).
    var canCancel: Bool { saving == nil }
}

/// Uninstall asks first (ruling 17).
struct PluginUninstallConfirmation: Equatable, Sendable, Identifiable {
    static let cancelLabel = "Cancel"
    static let uninstallLabel = "Uninstall"
    static let message = "Its skills, commands and servers leave every project. Claude Code loses it too."

    let plugin: String
    let title: String
    var message: String { Self.message }
    var id: String { plugin }

    init(row: PluginRow) {
        plugin = row.id
        title = "Uninstall \(PluginsPresentation.displayName(row.name))?"
    }
}

/// What the Configure sheet's fields hold. Save sends only what changed: a
/// plain option whose text differs from its value, a sensitive one only when
/// typed into (its value never reaches the app).
struct PluginConfigureDraft: Equatable, Sendable {
    var text: [String: String]

    init(options: [PluginOption]) {
        var text: [String: String] = [:]
        for option in options { text[option.key] = option.sensitive ? "" : (option.value ?? "") }
        self.text = text
    }

    func changed(_ options: [PluginOption]) -> [String: String] {
        var out: [String: String] = [:]
        for option in options {
            let now = text[option.key] ?? ""
            if option.sensitive {
                if !now.isEmpty { out[option.key] = now }
            } else if now != (option.value ?? "") {
                out[option.key] = now
            }
        }
        return out
    }

    func canSave(_ options: [PluginOption]) -> Bool { !changed(options).isEmpty }
}

/// What the Add marketplace sheet holds.
struct PluginMarketplaceAddDraft: Equatable, Sendable {
    var source: String = ""
    var trimmed: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !trimmed.isEmpty }
}

extension AppModel {
    /// The gateway can manage plugins (`plugins.v1` in hello).
    var pluginsAvailable: Bool { hello?.capabilities.contains(PluginsCapability.name) == true }

    /// Requests go out only on a live connection (R-c25).
    var settingsConnected: Bool { connection == .connected }

    private var canSendPlugins: Bool { pluginsAvailable && settingsConnected }

    private func pluginRow(_ id: String) -> PluginRow? {
        plugins.installed.first { $0.id == id }
    }

    private func pluginsRequest(_ request: PluginsState.Request, _ make: (String) -> ClientMessage) {
        let id = Self.requestId()
        plugins.pending[id] = request
        send(make(id))
    }

    /// Ask for the lists; `available` adds Browse's.
    func requestPluginsList(available: Bool) {
        guard canSendPlugins else { return }
        pluginsRequest(.list(available: available)) { .pluginsList(PluginsList(available: available, id: $0)) }
    }

    /// The tab came on screen: the installed plugins and the marketplaces.
    func pluginsTabAppeared() {
        settingsTabsShowing.insert(.plugins)
        requestPluginsList(available: false)
    }

    func pluginsTabDisappeared() {
        settingsTabsShowing.remove(.plugins)
        pluginsBrowseShowing = false
    }

    /// Browse came on screen: what the marketplaces offer, asked for the first time only.
    func pluginsBrowseShown() {
        pluginsBrowseShowing = true
        guard !plugins.browseRequested else { return }
        requestPluginsList(available: true)
    }

    func pluginsInstalledShown() {
        pluginsBrowseShowing = false
    }

    /// One change for one plugin: none while that plugin already has one out.
    private func pluginChange(_ plugin: String, _ make: (String) -> ClientMessage) {
        guard canSendPlugins, !plugins.busy.contains(plugin) else { return }
        plugins.busy.insert(plugin)
        plugins.rowErrors[plugin] = nil
        plugins.lastError = nil
        pluginsRequest(.plugin(plugin), make)
    }

    func pluginSetEnabled(_ plugin: String, enabled: Bool) {
        guard pluginRow(plugin) != nil else { return }
        pluginChange(plugin) { .pluginsSetEnabled(PluginsSetEnabled(plugin: plugin, enabled: enabled, id: $0)) }
    }

    func pluginInstall(_ plugin: String) {
        pluginChange(plugin) { .pluginsInstall(PluginsInstall(plugin: plugin, id: $0)) }
    }

    /// Update to … and Check for update: the gateway updates to the marketplace's version.
    func pluginUpdate(_ plugin: String) {
        guard pluginRow(plugin) != nil else { return }
        pluginChange(plugin) { .pluginsUpdate(PluginsUpdate(plugin: plugin, id: $0)) }
    }

    func askToUninstallPlugin(_ plugin: String) {
        guard let row = pluginRow(plugin), !plugins.busy.contains(plugin) else { return }
        plugins.uninstalling = PluginUninstallConfirmation(row: row)
    }

    func cancelPluginUninstall() {
        plugins.uninstalling = nil
    }

    func confirmPluginUninstall() {
        guard let ask = plugins.uninstalling else { return }
        plugins.uninstalling = nil
        guard settingsConnected else {
            plugins.lastError = PluginsState.notConnected
            return
        }
        pluginChange(ask.plugin) { .pluginsUninstall(PluginsUninstall(plugin: ask.plugin, id: $0)) }
    }

    func pluginMarketplaceUpdate(_ name: String) {
        guard canSendPlugins, !plugins.busyMarketplaces.contains(name) else { return }
        plugins.busyMarketplaces.insert(name)
        plugins.marketplaceErrors[name] = nil
        plugins.lastError = nil
        pluginsRequest(.marketplace(name)) { .pluginsMarketplaceUpdate(PluginsMarketplaceUpdate(name: name, id: $0)) }
    }

    /// Add marketplace…: the sheet stays open, Adding…, until the reply.
    func pluginMarketplaceAdd(_ draft: PluginMarketplaceAddDraft) {
        guard canSendPlugins, plugins.addingMarketplace == nil, draft.canAdd else { return }
        let id = Self.requestId()
        plugins.addingMarketplace = id
        plugins.marketplaceAddError = nil
        plugins.pending[id] = .addMarketplace
        send(.pluginsMarketplaceAdd(PluginsMarketplaceAdd(source: draft.trimmed, id: id)))
    }

    func pluginMarketplaceAddDismissed() {
        plugins.marketplaceAddError = nil
    }

    func pluginShowDetails(_ plugin: String) {
        guard canSendPlugins, let row = pluginRow(plugin) else { return }
        plugins.details = PluginDetailsSheet(plugin: plugin, title: PluginsPresentation.displayName(row.name))
        pluginsRequest(.details(plugin)) { .pluginsDetails(PluginsDetailsRequest(plugin: plugin, id: $0)) }
    }

    func pluginDetailsClosed() {
        plugins.details = nil
    }

    /// Configure… (R-c29): always offered. The sheet asks for that one
    /// plugin's options the first time on this connection, then uses the
    /// answer kept; a save refreshes it.
    func pluginConfigure(_ plugin: String) {
        guard canSendPlugins, let row = pluginRow(plugin) else { return }
        plugins.configuring = PluginConfigureSheet(
            plugin: plugin, title: "Configure \(PluginsPresentation.displayName(row.name))",
            options: plugins.options[plugin])
        guard plugins.options[plugin] == nil, !plugins.pending.values.contains(.options(plugin)) else { return }
        pluginsRequest(.options(plugin)) { .pluginsOptions(PluginsOptionsRequest(plugin: plugin, id: $0)) }
    }

    /// Save: only the changed values (the gateway pipes exactly what it is sent).
    func pluginSaveConfiguration(_ values: [String: String]) {
        guard canSendPlugins, let sheet = plugins.configuring, sheet.saving == nil, !values.isEmpty else { return }
        let id = Self.requestId()
        plugins.configuring?.saving = id
        plugins.configuring?.error = nil
        plugins.pending[id] = .configure(sheet.plugin)
        send(.pluginsConfigure(PluginsConfigure(plugin: sheet.plugin, values: values, id: id)))
    }

    /// The Configure sheet closed without saving (Cancel is off while a save is out).
    func pluginConfigureClosed() {
        guard plugins.configuring?.saving == nil else { return }
        plugins.configuring = nil
    }

    // MARK: replies

    func applyPluginsState(_ state: PluginsStateMessage) {
        plugins.installed = state.installed
        plugins.marketplaces = state.marketplaces
        if let available = state.available { plugins.available = available }
        plugins.loaded = true
        if let id = state.id, let request = plugins.pending.removeValue(forKey: id) {
            switch request {
            case .plugin(let plugin): plugins.busy.remove(plugin)
            case .marketplace(let name): plugins.busyMarketplaces.remove(name)
            case .addMarketplace:
                plugins.addingMarketplace = nil
                plugins.marketplaceAddFinished += 1
            case .list, .details, .options, .configure: break
            }
        }
    }

    func applyPluginsDetails(_ details: PluginsDetails) {
        guard let id = details.id, plugins.pending.removeValue(forKey: id) != nil else { return }
        if plugins.details?.plugin == details.plugin { plugins.details?.text = details.text }
    }

    func applyPluginsOptions(_ reply: PluginsOptions) {
        plugins.options[reply.plugin] = reply.options
        guard let id = reply.id, let request = plugins.pending.removeValue(forKey: id) else { return }
        guard plugins.configuring?.plugin == reply.plugin else { return }
        switch request {
        case .configure:
            plugins.configuring = nil
            plugins.configureFinished += 1
        case .options:
            if plugins.configuring?.saving == nil { plugins.configuring?.options = reply.options }
        default: break
        }
    }

    /// An `error` for a `plugins.*` request. A change's refusal is shown
    /// where it was asked for and the list is asked for again: the change
    /// may have gone through and only the re-list failed.
    func applyPluginsError(_ error: ErrorMessage) {
        guard let id = error.id else {
            if error.code.hasPrefix("plugins.") { plugins.lastError = error.message }
            return
        }
        guard let request = plugins.pending.removeValue(forKey: id) else { return }
        switch request {
        case .list:
            plugins.lastError = error.message
            return
        case .plugin(let plugin):
            plugins.busy.remove(plugin)
            plugins.rowErrors[plugin] = error.message
        case .marketplace(let name):
            plugins.busyMarketplaces.remove(name)
            plugins.marketplaceErrors[name] = error.message
        case .addMarketplace:
            plugins.addingMarketplace = nil
            plugins.marketplaceAddError = error.message
        case .details(let plugin):
            if plugins.details?.plugin == plugin { plugins.details?.error = error.message }
            return
        case .options(let plugin):
            // A read: nothing changed, nothing to re-list. Not cached, so the next open asks again.
            if plugins.configuring?.plugin == plugin, plugins.configuring?.options == nil {
                plugins.configuring?.error = error.message
            }
            return
        case .configure(let plugin):
            if plugins.configuring?.plugin == plugin {
                plugins.configuring?.saving = nil
                plugins.configuring?.error = error.message
            }
        }
        requestPluginsList(available: plugins.available != nil || pluginsBrowseShowing)
    }

    /// The connection went: nothing in flight will be answered (R-c25).
    func endPluginRequests() {
        plugins.busy = []
        plugins.busyMarketplaces = []
        plugins.pending = [:]
        plugins.addingMarketplace = nil
        plugins.configuring?.saving = nil
        // An open sheet still waiting would spin for ever (no reply is coming).
        if let sheet = plugins.details, sheet.text == nil, sheet.error == nil {
            plugins.details?.error = PluginsState.notConnected
        }
        if let sheet = plugins.configuring, sheet.options == nil, sheet.error == nil {
            plugins.configuring?.error = PluginsState.notConnected
        }
    }

    /// A new hello: the lists are asked for afresh.
    func resetPlugins() {
        plugins = PluginsState()
    }
}
