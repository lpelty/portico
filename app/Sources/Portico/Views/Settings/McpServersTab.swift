import AppKit
import SwiftUI

// MARK: - What the tab says (AR1–AR3, rulings 7–15)

/// AR1's list as the view draws it: View-free so the groups, words and
/// controls are tested without a window. Brand words come from the
/// deployment's brand name, never a literal.
enum McpServersPresentation {
    static let intro = "Tools the agent can use. Servers you add in Claude Code show up here too."
    static let addLabel = "Add server…"
    static let builtInLabel = "Built in"
    static let userScopeNote = "User scope"
    static let unsupported = "This gateway can't manage MCP servers"
    static let loading = "Loading…"

    static func footer(brand: String) -> String {
        "Built-in servers are how \(brand) works, so they can't be turned off. A server that ships with \(brand) can be turned off for you, and stays off through updates. A change applies to new chats; an open chat picks it up when it reconnects."
    }

    /// A group's title: shipped and local rows share "<brand> only" (AR1).
    static func groupTitle(_ group: McpServerRow.Group, brand: String) -> String {
        switch group {
        case .user: "All your projects"
        case .local, .shipped: "\(brand) only"
        case .core: "Built into \(brand)"
        case .account: "From your Claude account"
        }
    }

    /// The row's name: the server's own title, else its name as written;
    /// the built-in `portico` server reads as the deployment's brand (R-c5).
    static func displayName(_ row: McpServerRow, brand: String) -> String {
        if row.group == .core && row.name == "portico" { return brand }
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? row.name : title
    }

    /// AR1's logo fills, chosen by the name so a row keeps its colour.
    static let logoFills = ["#4F7DF3", "#E07A3F", "#2F9E8F", "#8A6BD1", "#C9A227", "#D1567A", "#3F6FD8", "#5D6874"]

    static func logoFill(for name: String) -> String {
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return logoFills[abs(sum) % logoFills.count]
    }

    struct Section: Equatable, Identifiable {
        let title: String
        /// Right of the title ("User scope" over All your projects).
        let trailing: String?
        let rows: [McpRowPresentation]
        var id: String { title }
    }

    /// The groups in AR1's order (All your projects, <brand> only, Built
    /// into <brand>), then the Claude account's (ruling 14); empty ones are left out.
    /// `connected` false: every control is off until the connection is back (R-c25).
    static func sections(_ state: McpServersState, brand: String, connected: Bool = true) -> [Section] {
        let order: [[McpServerRow.Group]] = [[.user], [.local, .shipped], [.core], [.account]]
        return order.compactMap { groups in
            let rows = state.rows.filter { groups.contains($0.group) }
            guard let first = rows.first else { return nil }
            return Section(
                title: groupTitle(first.group, brand: brand),
                trailing: groups == [.user] ? userScopeNote : nil,
                rows: rows.map { McpRowPresentation(row: $0, state: state, brand: brand, connected: connected) })
        }
    }
}

/// One row of AR1.
struct McpRowPresentation: Equatable, Identifiable {
    enum Tone: Equatable { case connected, waiting, failed, off }
    enum Primary: Equatable { case signIn, reconnect }

    let name: String
    let title: String
    let initial: String
    let logoFill: String
    /// "Ships with <brand>" beside a shipped server's name.
    let badge: String?
    let status: String
    let tone: Tone
    /// The button before the switch: Sign in, or Reconnect.
    let primary: Primary?
    let showsSwitch: Bool
    let isOn: Bool
    /// Built-in rows show "Built in" with a lock: no switch, no menu.
    let builtIn: Bool
    let showsMore: Bool
    let canRemove: Bool
    let canSignOut: Bool
    /// A request is out for the row: a spinner, and its controls are off.
    let busy: Bool
    let error: String?
    let connected: Bool

    var id: String { name }
    var controlsEnabled: Bool { !busy && connected }

    init(row: McpServerRow, state: McpServersState, brand: String, connected: Bool = true) {
        name = row.name
        title = McpServersPresentation.displayName(row, brand: brand)
        initial = title.first.map { String($0).uppercased() } ?? "?"
        logoFill = McpServersPresentation.logoFill(for: row.name)
        badge = row.group == .shipped ? "Ships with \(brand)" : nil
        status = row.detail
        tone = Self.tone(row.status)
        switch row.status {
        case .needsAuth: primary = .signIn
        case .failed: primary = .reconnect
        default: primary = nil
        }
        builtIn = row.group == .core
        showsSwitch = row.canToggle && !builtIn
        isOn = row.status != .off
        showsMore = !builtIn
        canRemove = row.canRemove
        canSignOut = row.canSignOut
        busy = state.busy.contains(row.name)
        error = state.rowErrors[row.name]
        self.connected = connected
    }

    static func tone(_ status: McpServerRow.Status) -> Tone {
        switch status {
        case .connected: .connected
        case .needsAuth, .pending, .signingIn: .waiting
        case .failed: .failed
        case .off, .unknown: .off
        }
    }

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .connected: Theme.working
        case .waiting: Theme.wait
        case .failed: Theme.deny
        case .off: Theme.idle
        }
    }
}

extension McpToolRow.Policy {
    /// AR2's menu words (ruling 10).
    var label: String {
        switch self {
        case .allow: "Runs without asking"
        case .ask: "Asks first"
        }
    }
}

/// AR2: one server's page.
struct McpDetailsPresentation: Equatable {
    static let backLabel = "MCP servers"
    static let toolsNote = "Tools that only read run without asking unless you change them here."
    /// Tools shown before "+ N more." (ruling 10).
    static let visibleTools = 5

    struct Tool: Equatable, Identifiable {
        let name: String
        let description: String
        let policy: McpToolRow.Policy
        var policyLabel: String { policy.label }
        var id: String { name }
    }

    let title: String
    /// "Connected · All your projects · signed in as …" (the account only when the status carries one).
    let header: String
    let toolsTitle: String
    let tools: [Tool]
    let moreText: String?
    let policyEditable: Bool
    let showsSignIn: Bool
    let showsReconnect: Bool
    let showsSignOut: Bool
    let showsRemove: Bool
    /// "Turn off" / "Turn on"; `nil` where the server can't be turned off.
    let toggleLabel: String?

    init(row: McpServerRow, brand: String, expanded: Bool) {
        title = McpServersPresentation.displayName(row, brand: brand)
        let state = row.status == .connected ? "Connected" : row.detail
        let scope = row.group == .shipped
            ? "Ships with \(brand)" : McpServersPresentation.groupTitle(row.group, brand: brand)
        header = ([state, scope] + (row.account.map { ["signed in as \($0)"] } ?? [])).joined(separator: " · ")
        toolsTitle = "Tools · \(row.toolCount ?? row.tools.count)"
        let all = row.tools.map { Tool(name: $0.name, description: $0.description, policy: $0.policy) }
        let shown = expanded ? all : Array(all.prefix(Self.visibleTools))
        tools = shown
        moreText = all.count > shown.count ? "+ \(all.count - shown.count) more." : nil
        policyEditable = row.group != .core
        showsSignIn = row.status == .needsAuth
        showsReconnect = row.status != .off
        showsSignOut = row.canSignOut
        showsRemove = row.canRemove
        toggleLabel = row.canToggle && row.group != .core ? (row.status == .off ? "Turn on" : "Turn off") : nil
    }
}

/// AR3's words.
enum McpAddPresentation {
    static let title = "Add an MCP server"
    static let nameLabel = "Name"
    static let connectsByLabel = "Connects by"
    static let addressLabel = "Address"
    /// The program's field (AR3 screens only the web address).
    static let commandLabel = "Command"
    static let commandPrompt = "npx -y acme-mcp"
    static let addressPrompt = "https://mcp.acme.example/"
    static let whereLabel = "Where it works"
    static let cancelLabel = "Cancel"
    static let addLabel = "Add"
    static let addingLabel = "Adding…"

    static func scopeTitle(_ scope: McpAdd.Where, brand: String) -> String {
        switch scope {
        case .user: "All your projects"
        case .local: "\(brand) only"
        }
    }

    static func scopeHelp(_ scope: McpAdd.Where, brand: String) -> String {
        switch scope {
        case .user: "You, anywhere on this Mac. Claude Code uses it too."
        case .local: "You, only when you work with \(brand). Nothing is written into \(brand)'s own files."
        }
    }

    static func signInNote(brand: String) -> String {
        "If the server needs you to sign in, \(brand) opens your browser after you add it."
    }
}

// MARK: - The tab

/// Settings → MCP servers (AR1), a server's page (AR2), Add (AR3).
struct McpServersTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var shownServer: String?
    @State private var expandedTools = false
    @State private var adding = false

    private var brand: String { model.brand.name }

    var body: some View {
        Group {
            if !model.mcpAvailable {
                Text(McpServersPresentation.unsupported)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let name = shownServer, let row = model.mcpServers.rows.first(where: { $0.name == name }) {
                ScrollView { details(row).padding(.horizontal, 24).padding(.vertical, 18) }
            } else {
                ScrollView { list.padding(.horizontal, 24).padding(.vertical, 18) }
            }
        }
        .onAppear { model.mcpTabAppeared() }
        // A new hello asks again while the tab is shown (the model's resumeSettingsLists).
        .onDisappear { model.mcpTabDisappeared() }
        .onChange(of: model.mcpAddFinished) { adding = false }
        .sheet(isPresented: $adding, onDismiss: { model.mcpAddDismissed() }) {
            McpAddSheet(isPresented: $adding)
                .environmentObject(model)
                .presentationBackground(Theme.window)
        }
        .alert(
            model.mcpRemoving?.title ?? "",
            isPresented: Binding(get: { model.mcpRemoving != nil }, set: { if !$0 { model.cancelMcpRemove() } }),
            presenting: model.mcpRemoving
        ) { _ in
            Button(McpRemoveConfirmation.cancelLabel, role: .cancel) { model.cancelMcpRemove() }
            Button(McpRemoveConfirmation.removeLabel, role: .destructive) { model.confirmMcpRemove() }
        } message: { ask in
            Text(ask.message)
        }
    }

    // MARK: AR1

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(McpServersPresentation.intro)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { adding = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(Theme.iconFont(10, weight: .medium)).foregroundStyle(Theme.text2)
                        Text(McpServersPresentation.addLabel)
                    }
                }
                .buttonStyle(SettingsButtonStyle(kind: .quiet))
                .disabled(!model.settingsConnected)
            }
            .padding(.bottom, 4)
            if let error = model.mcpServers.lastError {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
            }
            let sections = McpServersPresentation.sections(model.mcpServers, brand: brand, connected: model.settingsConnected)
            if sections.isEmpty && !model.mcpServers.loaded {
                Text(McpServersPresentation.loading)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
            }
            ForEach(sections) { section in
                sectionHeader(section)
                SettingsPanel {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        serverRow(row)
                    }
                }
            }
            Text(McpServersPresentation.footer(brand: brand))
                .scaledFont(11.5)
                .foregroundStyle(Theme.text3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader(_ section: McpServersPresentation.Section) -> some View {
        HStack {
            Text(section.title)
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(Theme.text2)
            Spacer()
            if let trailing = section.trailing {
                Text(trailing)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private func serverRow(_ row: McpRowPresentation) -> some View {
        HStack(spacing: 10) {
            McpLogo(initial: row.initial, fill: row.logoFill, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(row.title)
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let badge = row.badge { McpBadge(text: badge) }
                }
                McpStatusLine(text: row.status, tone: row.tone)
                if let error = row.error {
                    Text(error)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.deny)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { show(row.name) }
            if row.busy {
                ProgressView().controlSize(.small)
            }
            trailing(row)
                .disabled(!row.controlsEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The row's controls after its spinner; all off while it is busy.
    @ViewBuilder
    private func trailing(_ row: McpRowPresentation) -> some View {
        HStack(spacing: 10) {
            switch row.primary {
            case .signIn:
                Button("Sign in") { model.mcpSignIn(row.name) }
                    .buttonStyle(SettingsButtonStyle(kind: .accent))
            case .reconnect:
                Button("Reconnect") { model.mcpReconnect(row.name) }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
            case nil:
                EmptyView()
            }
            if row.showsSwitch {
                SettingsSwitch(isOn: Binding(get: { row.isOn }, set: { model.mcpToggle(row.name, enabled: $0) }))
                    .accessibilityLabel(row.title)
            }
            if row.builtIn {
                HStack(spacing: 5) {
                    Image(systemName: "lock").font(Theme.iconFont(10)).foregroundStyle(Theme.text3)
                    Text(McpServersPresentation.builtInLabel)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 4)
            }
            if row.showsMore {
                Menu {
                    Button("Details") { show(row.name) }
                    Button("Reconnect") { model.mcpReconnect(row.name) }
                    if row.canSignOut { Button("Sign out") { model.mcpSignOut(row.name) } }
                    if row.canRemove {
                        Divider()
                        Button("Remove…") { model.askToRemoveMcp(row.name) }
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
                .tip("More for \(row.title)")
            }
        }
    }

    private func show(_ name: String) {
        expandedTools = false
        shownServer = name
    }

    // MARK: AR2

    private func details(_ row: McpServerRow) -> some View {
        let page = McpDetailsPresentation(row: row, brand: brand, expanded: expandedTools)
        let busy = model.mcpServers.busy.contains(row.name) || !model.settingsConnected
        return VStack(alignment: .leading, spacing: 10) {
            Button { shownServer = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(Theme.iconFont(11, weight: .medium))
                    Text(McpDetailsPresentation.backLabel).scaledFont(12.5)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            HStack(spacing: 12) {
                McpLogo(
                    initial: page.title.first.map { String($0).uppercased() } ?? "?",
                    fill: McpServersPresentation.logoFill(for: row.name), size: 40, radius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(Theme.text)
                    McpStatusLine(text: page.header, tone: McpRowPresentation.tone(row.status))
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                if page.showsSignIn {
                    Button("Sign in") { model.mcpSignIn(row.name) }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                }
                if page.showsReconnect {
                    actionButton("Reconnect", icon: "arrow.clockwise") { model.mcpReconnect(row.name) }
                }
                if page.showsSignOut {
                    actionButton("Sign out", icon: "rectangle.portrait.and.arrow.right") { model.mcpSignOut(row.name) }
                }
                if let toggle = page.toggleLabel {
                    actionButton(toggle, icon: "power") { model.mcpToggle(row.name, enabled: row.status == .off) }
                }
                Spacer()
                if page.showsRemove {
                    Button { model.askToRemoveMcp(row.name) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(Theme.iconFont(10))
                            Text("Remove…")
                        }
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .destructive))
                }
            }
            .disabled(busy)
            if let error = model.mcpServers.rowErrors[row.name] {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
            }
            if !page.tools.isEmpty {
                Text(page.toolsTitle)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.text2)
                SettingsPanel {
                    ForEach(Array(page.tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        toolRow(tool, server: row.name, editable: page.policyEditable && !busy)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let more = page.moreText {
                        Button(more) { expandedTools = true }
                            .buttonStyle(.hoverText)
                            .scaledFont(11.5)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(McpDetailsPresentation.toolsNote)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(Theme.iconFont(10)).foregroundStyle(Theme.text2)
                Text(title)
            }
        }
        .buttonStyle(SettingsButtonStyle(kind: .quiet))
    }

    private func toolRow(_ tool: McpDetailsPresentation.Tool, server: String, editable: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if editable {
                Menu {
                    ForEach(McpToolRow.Policy.allCases, id: \.self) { policy in
                        Button(policy.label) { model.mcpSetPolicy(server: server, tool: tool.name, policy: policy) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(tool.policyLabel).scaledFont(12).foregroundStyle(Theme.text2)
                        Image(systemName: "chevron.down").font(Theme.iconFont(9)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(tool.policyLabel)
                    .scaledFont(12)
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - AR3: Add

struct McpAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var draft = McpAddDraft()

    private var brand: String { model.brand.name }
    private var existing: [String] { model.mcpServers.rows.map(\.name) }
    private var sending: Bool { model.mcpAdding != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(McpAddPresentation.title)
                .scaledFont(15, weight: .semibold)
                .foregroundStyle(Theme.text)
            field(McpAddPresentation.nameLabel) {
                TextField("", text: $draft.name, prompt: Text("acme-tracker"))
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(13)
                if let error = draft.nameError(existing: existing) {
                    Text(error)
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.deny)
                }
            }
            field(McpAddPresentation.connectsByLabel) {
                SettingsSegmented(
                    selection: $draft.connectsBy,
                    options: McpAddDraft.ConnectsBy.allCases.map { ($0, $0.label) })
                    .accessibilityLabel(McpAddPresentation.connectsByLabel)
                    .fixedSize()
            }
            if draft.connectsBy == .web {
                field(McpAddPresentation.addressLabel) {
                    TextField("", text: $draft.address, prompt: Text(McpAddPresentation.addressPrompt))
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(13)
                }
            } else {
                field(McpAddPresentation.commandLabel) {
                    TextField("", text: $draft.command, prompt: Text(McpAddPresentation.commandPrompt))
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(13, design: .monospaced)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(McpAddPresentation.whereLabel)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Theme.text2)
                ForEach([McpAdd.Where.user, .local], id: \.self) { scope in
                    scopeChoice(scope)
                }
            }
            if draft.connectsBy == .web {
                Text(McpAddPresentation.signInNote(brand: brand))
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.mcpAddError {
                Text(error)
                    .scaledFont(11.5)
                    .foregroundStyle(Theme.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button(McpAddPresentation.cancelLabel) { isPresented = false }
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    // R-c25: the Add stays answerable; Cancel waits for its reply.
                    .disabled(!model.mcpAddCanCancel)
                Button(sending ? McpAddPresentation.addingLabel : McpAddPresentation.addLabel) { model.mcpAdd(draft) }
                    .buttonStyle(SettingsButtonStyle(kind: .accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || !model.settingsConnected || !draft.canAdd(existing: existing))
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 460)
        .background(Theme.panel)
        .interactiveDismissDisabled(!model.mcpAddCanCancel)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.text2)
            content()
        }
    }

    private func scopeChoice(_ scope: McpAdd.Where) -> some View {
        Button { draft.scope = scope } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: draft.scope == scope ? "largecircle.fill.circle" : "circle")
                    .font(Theme.iconFont(13))
                    .foregroundStyle(draft.scope == scope ? Theme.accent : Theme.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(McpAddPresentation.scopeTitle(scope, brand: brand))
                        .scaledFont(13)
                        .foregroundStyle(Theme.text)
                    Text(McpAddPresentation.scopeHelp(scope, brand: brand))
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .accessibilityAddTraits(draft.scope == scope ? .isSelected : [])
    }
}

// MARK: - Pieces of the list tabs (the shared ones are in SettingsKit.swift)

/// A server's square logo: its initial in white on a fill.
struct McpLogo: View {
    let initial: String
    let fill: String
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Text(initial)
            .scaledFont(13, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                BrandPresentation.color(hex: fill) ?? Theme.accent,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "Ships with <brand>": 10.5-pt, the control colour, radius 5 (AR1).
struct McpBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .scaledFont(10.5)
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// A status dot and its words (AR1): text 3 when all is well, text 2 when it needs the person.
struct McpStatusLine: View {
    let text: String
    let tone: McpRowPresentation.Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(McpRowPresentation.color(tone)).frame(width: 7, height: 7)
            Text(text)
                .scaledFont(11.5)
                .foregroundStyle(tone == .waiting || tone == .failed ? Theme.text2 : Theme.text3)
                .lineLimit(2)
        }
    }
}
