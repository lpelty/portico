import AppKit
import SwiftUI

// MARK: - What the tab says (AR4, rulings 16–19)

/// AR4's lists as the view draws them: View-free so the words and controls
/// are tested without a window.
enum PluginsPresentation {
    enum Segment: String, CaseIterable, Sendable {
        case installed, browse

        var title: String {
            switch self {
            case .installed: "Installed"
            case .browse: "Browse"
            }
        }
    }

    static let footer = "Plugins add skills, commands and MCP servers. Plugins you install in Claude Code show up here too; a change applies to new chats."
    static let addMarketplaceLabel = "Add marketplace…"
    static let checkForUpdatesLabel = "Check for updates"
    static let filterPrompt = "Filter plugins"
    static let installLabel = "Install"
    static let installedLabel = "Installed"
    static let unsupported = "This gateway can't manage plugins"
    static let loading = "Loading…"
    static let noneInstalled = "No plugins installed yet. Browse what your marketplaces offer."
    static let noneMatch = "No plugins match."

    /// The official marketplace's name as people read it (R-c11).
    static let officialMarketplace = "claude-plugins-official"

    /// A slug as words (R-c11): hyphens to spaces, the first letter capitalised;
    /// the official marketplace reads "Claude plugins".
    static func displayName(_ slug: String) -> String {
        if slug == officialMarketplace { return "Claude plugins" }
        let words = slug.replacingOccurrences(of: "-", with: " ")
        guard let first = words.first else { return slug }
        return first.uppercased() + words.dropFirst()
    }

    /// AR4's "Update to 1.5": a trailing ".0" dropped while more than two parts remain.
    static func shortVersion(_ version: String) -> String {
        var parts = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// AR4's logo fills (Design review, Meeting notes, Release helper) and AR1's, chosen by the id.
    static let logoFills = ["#D1567A", "#3F8CD1", "#7A8A3F", "#4F7DF3", "#E07A3F", "#2F9E8F", "#8A6BD1", "#C9A227"]

    static func logoFill(for id: String) -> String {
        let sum = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return logoFills[abs(sum) % logoFills.count]
    }

    static func initial(_ title: String) -> String {
        title.first.map { String($0).uppercased() } ?? "?"
    }

    /// "<description> · from <marketplace>"; just "from …" with no description.
    static func subtitle(description: String, marketplace: String) -> String {
        let from = "from \(displayName(marketplace))"
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? from : "\(text) · \(from)"
    }

    static func installed(_ state: PluginsState, connected: Bool) -> [PluginRowPresentation] {
        state.installed.map { PluginRowPresentation(row: $0, state: state, connected: connected) }
    }

    static func installedTitle(_ state: PluginsState) -> String { "Installed · \(state.installed.count)" }

    static func marketplaces(_ state: PluginsState, connected: Bool) -> [PluginMarketplaceRowPresentation] {
        state.marketplaces.map { PluginMarketplaceRowPresentation(marketplace: $0, state: state, connected: connected) }
    }

    static func marketplacesTitle(_ state: PluginsState) -> String { "Marketplaces · \(state.marketplaces.count)" }

    /// Browse, in the gateway's order, kept to what the filter matches in the
    /// name (as written or as words) or the description, either case.
    static func browse(_ state: PluginsState, filter: String, connected: Bool) -> [PluginBrowseRowPresentation] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let installed = Set(state.installed.map(\.id))
        return (state.available ?? [])
            .filter { plugin in
                needle.isEmpty
                    || [plugin.name, displayName(plugin.name), plugin.description].contains {
                        $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
            }
            .map { PluginBrowseRowPresentation(plugin: $0, state: state, installed: installed, connected: connected) }
    }
}

/// One installed row of AR4.
struct PluginRowPresentation: Equatable, Identifiable {
    enum MenuItem: Equatable, CaseIterable {
        case details, configure, checkForUpdate, uninstall

        var label: String {
            switch self {
            case .details: "Details"
            case .configure: "Configure…"
            case .checkForUpdate: "Check for update"
            case .uninstall: "Uninstall…"
            }
        }

        /// AR4's menu icons (lucide info, sliders-horizontal, refresh-cw, trash-2).
        var systemImage: String {
            switch self {
            case .details: "info.circle"
            case .configure: "slider.horizontal.3"
            case .checkForUpdate: "arrow.clockwise"
            case .uninstall: "trash"
            }
        }
    }

    let id: String
    let title: String
    let initial: String
    let logoFill: String
    let version: String
    let subtitle: String
    let isOn: Bool
    /// "Update to 1.5" when the marketplace has another version.
    let updateLabel: String?
    let menuItems: [MenuItem]
    let busy: Bool
    let error: String?
    let connected: Bool

    var controlsEnabled: Bool { !busy && connected }
    var moreHelp: String { "More for \(title)" }

    init(row: PluginRow, state: PluginsState, connected: Bool) {
        id = row.id
        title = PluginsPresentation.displayName(row.name)
        initial = PluginsPresentation.initial(title)
        logoFill = PluginsPresentation.logoFill(for: row.id)
        version = row.version
        subtitle = PluginsPresentation.subtitle(description: row.description, marketplace: row.marketplace)
        isOn = row.enabled
        updateLabel = row.updateTo.map { "Update to \(PluginsPresentation.shortVersion($0))" }
        // R-c29: Configure… is always offered; the sheet says when there's nothing to set.
        menuItems = MenuItem.allCases
        busy = state.busy.contains(row.id)
        error = state.rowErrors[row.id]
        self.connected = connected
    }
}

/// One Browse row.
struct PluginBrowseRowPresentation: Equatable, Identifiable {
    let id: String
    let title: String
    let initial: String
    let logoFill: String
    let subtitle: String
    let installed: Bool
    let busy: Bool
    let error: String?
    let connected: Bool

    var controlsEnabled: Bool { !busy && connected }

    init(plugin: AvailablePlugin, state: PluginsState, installed ids: Set<String>, connected: Bool) {
        id = plugin.id
        title = PluginsPresentation.displayName(plugin.name)
        initial = PluginsPresentation.initial(title)
        logoFill = PluginsPresentation.logoFill(for: plugin.id)
        subtitle = PluginsPresentation.subtitle(description: plugin.description, marketplace: plugin.marketplace)
        installed = plugin.installed || ids.contains(plugin.id)
        busy = state.busy.contains(plugin.id)
        error = state.rowErrors[plugin.id]
        self.connected = connected
    }
}

/// One marketplace row of AR4.
struct PluginMarketplaceRowPresentation: Equatable, Identifiable {
    let name: String
    let title: String
    /// "6 plugins · github.com/acme/plugins · checked today"; the source only
    /// when it isn't the official one, "checked …" only when known (R-c12).
    let subtitle: String
    let busy: Bool
    let error: String?
    let connected: Bool

    var id: String { name }
    var controlsEnabled: Bool { !busy && connected }

    init(marketplace: PluginMarketplace, state: PluginsState, connected: Bool) {
        name = marketplace.name
        title = PluginsPresentation.displayName(marketplace.name)
        var parts = ["\(marketplace.pluginCount) \(marketplace.pluginCount == 1 ? "plugin" : "plugins")"]
        if let source = marketplace.sourceLabel, !source.isEmpty { parts.append(source) }
        if !marketplace.checked.isEmpty { parts.append("checked \(marketplace.checked)") }
        subtitle = parts.joined(separator: " · ")
        busy = state.busyMarketplaces.contains(marketplace.name)
        error = state.marketplaceErrors[marketplace.name]
        self.connected = connected
    }
}

/// One Configure field (ruling 19): a secure field for a sensitive option,
/// "Saved" in it when it has a value the app never sees.
struct PluginOptionField: Equatable, Identifiable {
    static let savedPlaceholder = "Saved"

    let key: String
    let label: String
    let help: String
    let secure: Bool
    let placeholder: String

    var id: String { key }

    init(_ option: PluginOption) {
        key = option.key
        label = option.title.isEmpty ? option.key : option.title
        help = option.description
        secure = option.sensitive
        placeholder = option.sensitive && option.set ? Self.savedPlaceholder : ""
    }
}

/// The sheets' words.
enum PluginSheetsPresentation {
    static let addTitle = "Add a marketplace"
    static let sourceLabel = "Source"
    static let sourcePrompt = "acme/plugins"
    static let sourceHelp = "A GitHub repo (owner/repo), a git address or a folder on this Mac."
    static let cancelLabel = "Cancel"
    static let addLabel = "Add"
    static let addingLabel = "Adding…"
    static let saveLabel = "Save"
    static let savingLabel = "Saving…"
    static let doneLabel = "Done"
    static let noSettings = "This plugin has no settings."
    static let configureNote = "Only the values you change are saved. A saved key stays as it is unless you type a new one."
}

// MARK: - The tab

/// Settings → Plugins (AR4): Installed and Browse, the marketplaces, and the
/// sheets for Details, Configure and Add marketplace.
struct PluginsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: PluginsPresentation.Segment = .installed
    @State private var filter = ""
    @State private var addingMarketplace = false

    private var connected: Bool { model.settingsConnected }

    var body: some View {
        Group {
            if !model.pluginsAvailable {
                Text(PluginsPresentation.unsupported)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { content.padding(.horizontal, 24).padding(.vertical, 18) }
            }
        }
        .onAppear {
            model.pluginsTabAppeared()
            segmentShown(segment)
        }
        .onDisappear { model.pluginsTabDisappeared() }
        // A hello asks again while the tab is shown (the model's resumeSettingsLists).
        .onChange(of: segment) { _, shown in segmentShown(shown) }
        .onChange(of: model.plugins.marketplaceAddFinished) { addingMarketplace = false }
        .sheet(isPresented: $addingMarketplace, onDismiss: { model.pluginMarketplaceAddDismissed() }) {
            PluginMarketplaceAddSheet(isPresented: $addingMarketplace)
                .environmentObject(model)
                .presentationBackground(Theme.window)
        }
        .sheet(item: Binding(get: { model.plugins.details }, set: { if $0 == nil { model.pluginDetailsClosed() } })) { sheet in
            PluginDetailsSheetView(sheet: sheet) { model.pluginDetailsClosed() }
                .presentationBackground(Theme.window)
        }
        .sheet(item: Binding(get: { model.plugins.configuring }, set: { if $0 == nil { model.pluginConfigureClosed() } })) { sheet in
            PluginConfigureSheetView(plugin: sheet.plugin)
                .environmentObject(model)
                .presentationBackground(Theme.window)
        }
        .alert(
            model.plugins.uninstalling?.title ?? "",
            isPresented: Binding(get: { model.plugins.uninstalling != nil }, set: { if !$0 { model.cancelPluginUninstall() } }),
            presenting: model.plugins.uninstalling
        ) { _ in
            Button(PluginUninstallConfirmation.cancelLabel, role: .cancel) { model.cancelPluginUninstall() }
            Button(PluginUninstallConfirmation.uninstallLabel, role: .destructive) { model.confirmPluginUninstall() }
        } message: { ask in
            Text(ask.message)
        }
    }

    private func segmentShown(_ shown: PluginsPresentation.Segment) {
        switch shown {
        case .installed: model.pluginsInstalledShown()
        case .browse: model.pluginsBrowseShown()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            if let error = model.plugins.lastError {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch segment {
            case .installed: installed
            case .browse: browse
            }
            Text(PluginsPresentation.footer)
                .scaledFont(11.5)
                .foregroundStyle(Theme.text3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: AR4's top: the segments and Add marketplace…

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            PluginsSegmented(selection: $segment)
            Spacer()
            Button { addingMarketplace = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(Theme.iconFont(10, weight: .medium)).foregroundStyle(Theme.text2)
                    Text(PluginsPresentation.addMarketplaceLabel)
                }
            }
            .buttonStyle(SettingsButtonStyle(kind: .quiet))
            .disabled(!connected)
        }
        .padding(.bottom, 4)
    }

    // MARK: Installed

    @ViewBuilder
    private var installed: some View {
        let rows = PluginsPresentation.installed(model.plugins, connected: connected)
        if !model.plugins.loaded {
            loadingLine
        } else {
            sectionTitle(PluginsPresentation.installedTitle(model.plugins))
            if rows.isEmpty {
                quietLine(PluginsPresentation.noneInstalled)
            } else {
                SettingsPanel {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        installedRow(row)
                    }
                }
            }
            let markets = PluginsPresentation.marketplaces(model.plugins, connected: connected)
            if !markets.isEmpty {
                sectionTitle(PluginsPresentation.marketplacesTitle(model.plugins))
                SettingsPanel {
                    ForEach(Array(markets.enumerated()), id: \.element.id) { index, market in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        marketplaceRow(market)
                    }
                }
            }
        }
    }

    private func installedRow(_ row: PluginRowPresentation) -> some View {
        HStack(spacing: 10) {
            McpLogo(initial: row.initial, fill: row.logoFill, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(row.title)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(row.version)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text3)
                }
                Text(row.subtitle)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(2)
                if let error = row.error { errorLine(error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.busy { ProgressView().controlSize(.small) }
            HStack(spacing: 10) {
                if let update = row.updateLabel {
                    Button(update) { model.pluginUpdate(row.id) }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                }
                SettingsSwitch(isOn: Binding(get: { row.isOn }, set: { model.pluginSetEnabled(row.id, enabled: $0) }))
                    .accessibilityLabel(row.title)
                Menu {
                    ForEach(row.menuItems, id: \.self) { item in
                        if item == .uninstall { Divider() }
                        Button(role: item == .uninstall ? .destructive : nil) { choose(item, row.id) } label: {
                            Label(item.label, systemImage: item.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Theme.iconFont(13))
                        .foregroundStyle(Theme.text2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tip(row.moreHelp)
            }
            .disabled(!row.controlsEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func choose(_ item: PluginRowPresentation.MenuItem, _ plugin: String) {
        switch item {
        case .details: model.pluginShowDetails(plugin)
        case .configure: model.pluginConfigure(plugin)
        case .checkForUpdate: model.pluginUpdate(plugin)
        case .uninstall: model.askToUninstallPlugin(plugin)
        }
    }

    private func marketplaceRow(_ market: PluginMarketplaceRowPresentation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "storefront")
                .font(Theme.iconFont(14))
                .foregroundStyle(Theme.text2)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(market.title)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(market.subtitle)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = market.error { errorLine(error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if market.busy { ProgressView().controlSize(.small) }
            Button(PluginsPresentation.checkForUpdatesLabel) { model.pluginMarketplaceUpdate(market.name) }
                .buttonStyle(SettingsButtonStyle(kind: .quiet))
                .disabled(!market.controlsEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Browse

    @ViewBuilder
    private var browse: some View {
        TextField("", text: $filter, prompt: Text(PluginsPresentation.filterPrompt))
            .textFieldStyle(.roundedBorder)
            .scaledFont(13)
        if model.plugins.available == nil {
            loadingLine
        } else {
            let rows = PluginsPresentation.browse(model.plugins, filter: filter, connected: connected)
            if rows.isEmpty {
                quietLine(PluginsPresentation.noneMatch)
            } else {
                SettingsPanel {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        browseRow(row)
                    }
                }
            }
        }
    }

    private func browseRow(_ row: PluginBrowseRowPresentation) -> some View {
        HStack(spacing: 10) {
            McpLogo(initial: row.initial, fill: row.logoFill, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(row.subtitle)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(2)
                if let error = row.error { errorLine(error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.busy { ProgressView().controlSize(.small) }
            if row.installed {
                Text(PluginsPresentation.installedLabel)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
            } else {
                Button(PluginsPresentation.installLabel) { model.pluginInstall(row.id) }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .disabled(!row.controlsEnabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .scaledFont(12, weight: .semibold)
            .foregroundStyle(Theme.text2)
    }

    private var loadingLine: some View {
        quietLine(PluginsPresentation.loading)
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .scaledFont(12)
            .foregroundStyle(Theme.text3)
    }

    private func errorLine(_ text: String) -> some View {
        Text(text)
            .scaledFont(11.5)
            .foregroundStyle(Theme.deny)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// AR4's segmented control, drawn by `SettingsSegmented` (the control
/// colour, radius 7, a border, the chosen segment on the selected fill,
/// radius 5, and the hover tint on every segment, v0.19 §3).
struct PluginsSegmented: View {
    @Binding var selection: PluginsPresentation.Segment

    var body: some View {
        SettingsSegmented(selection: $selection, options: PluginsPresentation.Segment.allCases.map { ($0, $0.title) })
    }
}

// MARK: - Sheets

struct PluginMarketplaceAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var draft = PluginMarketplaceAddDraft()

    private var sending: Bool { model.plugins.addingMarketplace != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PluginSheetsPresentation.addTitle)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 5) {
                Text(PluginSheetsPresentation.sourceLabel)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.text2)
                TextField("", text: $draft.source, prompt: Text(PluginSheetsPresentation.sourcePrompt))
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(13)
                Text(PluginSheetsPresentation.sourceHelp)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.plugins.marketplaceAddError {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button(PluginSheetsPresentation.cancelLabel) { isPresented = false }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.plugins.canCancelMarketplaceAdd)
                Button(sending ? PluginSheetsPresentation.addingLabel : PluginSheetsPresentation.addLabel) {
                    model.pluginMarketplaceAdd(draft)
                }
                .buttonStyle(SettingsButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
                .disabled(sending || !model.settingsConnected || !draft.canAdd)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 460)
        .background(Theme.panel)
        .interactiveDismissDisabled(!model.plugins.canCancelMarketplaceAdd)
    }
}

/// Details: the CLI's text as it prints it.
struct PluginDetailsSheetView: View {
    let sheet: PluginDetailsSheet
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.title)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            if let error = sheet.error {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = sheet.text {
                ScrollView {
                    Text(text)
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 360)
                .background(Theme.window, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button(PluginSheetsPresentation.doneLabel, action: close)
                    .buttonStyle(SettingsButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 520)
        .background(Theme.panel)
    }
}

/// Configure (ruling 19): text fields, secure ones for sensitive options;
/// Save sends only the changed values.
struct PluginConfigureSheetView: View {
    @EnvironmentObject private var model: AppModel
    let plugin: String
    @State private var draft: PluginConfigureDraft?

    private var sheet: PluginConfigureSheet? {
        model.plugins.configuring?.plugin == plugin ? model.plugins.configuring : nil
    }

    var body: some View {
        let sheet = sheet
        let saving = sheet?.saving != nil
        VStack(alignment: .leading, spacing: 14) {
            Text(sheet?.title ?? "")
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            if let options = sheet?.options, options.isEmpty {
                Text(PluginSheetsPresentation.noSettings)
                    .scaledFont(12.5)
                    .foregroundStyle(Theme.text2)
            } else if let options = sheet?.options {
                ForEach(options.map(PluginOptionField.init)) { field in
                    fieldView(field)
                }
                Text(PluginSheetsPresentation.configureNote)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sheet?.error == nil {
                ProgressView().controlSize(.small)
            }
            if let error = sheet?.error {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sheet?.options?.isEmpty == true {
                HStack {
                    Spacer()
                    Button(PluginSheetsPresentation.doneLabel) { model.pluginConfigureClosed() }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            } else {
            HStack(spacing: 8) {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(PluginSheetsPresentation.cancelLabel) { model.pluginConfigureClosed() }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? PluginSheetsPresentation.savingLabel : PluginSheetsPresentation.saveLabel) {
                    guard let options = sheet?.options, let draft else { return }
                    model.pluginSaveConfiguration(draft.changed(options))
                }
                .buttonStyle(SettingsButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !model.settingsConnected || !canSave)
            }
            .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 460)
        .background(Theme.panel)
        .interactiveDismissDisabled(saving)
        .onAppear { seed() }
        .onChange(of: sheet?.options) { seed() }
    }

    private var canSave: Bool {
        guard let options = sheet?.options, let draft else { return false }
        return draft.canSave(options)
    }

    /// The fields start from the options once they come.
    private func seed() {
        guard draft == nil, let options = sheet?.options else { return }
        draft = PluginConfigureDraft(options: options)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft?.text[key] ?? "" }, set: { draft?.text[key] = $0 })
    }

    private func fieldView(_ field: PluginOptionField) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.label)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.text2)
            Group {
                if field.secure {
                    SecureField("", text: binding(field.key), prompt: Text(field.placeholder))
                } else {
                    TextField("", text: binding(field.key), prompt: Text(field.placeholder))
                }
            }
            .textFieldStyle(.roundedBorder)
            .scaledFont(13)
            if !field.help.isEmpty {
                Text(field.help)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
