import AppKit
import SwiftUI

/// The settings window (spec §5.6, v0.12 §6): General (Folder, Viewer, Spaces),
/// Appearance, Gateway (Start / Stop, Doctor, what quitting does, v0.9
/// decision 7, and the address and token overrides under Advanced, v0.19 §5).
/// Every tab is drawn with `SettingsKit` (v0.19 §3).
/// Brand, actions and roots are the gateway's, not here.
/// One fixed window, the same on every tab (v0.12 spec section 6; v0.13 decision 7: 20% shorter, a taller tab scrolls).
enum SettingsWindow {
    static let width: CGFloat = 700
    static let height: CGFloat = 640
}

/// What Settings → General shows and says (v0.12 spec sections 3.5, 4.5, 6).
enum GeneralSettingsPresentation {
    static let canSeeNote = "The agent can look at, scroll and click what's open in the viewer, when asked or when it helps. You see every action as it happens."
    static let checksHTMLNote = "After creating or changing an HTML page, the agent opens it in the viewer and looks before replying. Uses more tokens."
    /// Names the app by its brand (v0.18.1): a deployment's people never see "Portico".
    static func spacesNote(brand: String) -> String {
        "A dot on the switcher, and a macOS notification while \(brand) is in the background."
    }

    /// Spaces appears only on a gateway with `spaces.v1`. There is no
    /// Sessions section: Clear earlier sessions is an admin command.
    static func sectionTitles(capabilities: [String]) -> [String] {
        ["Folder", "Viewer"] + (capabilities.contains("spaces.v1") ? ["Spaces"] : [])
    }

    /// The Works in row while the deployment fixes the folder (v0.19 §4.1).
    static func folderLockedNote(brand: String) -> String { "Set by \(brand)" }

    /// The same note inside a sentence (the start screen's line): only the first word drops its capital, the brand keeps its case.
    static func folderLockedClause(brand: String) -> String { "set by \(brand)" }

    // Also show in Files (v0.19 §4.2).
    static let extraFoldersTitle = "Also show in Files"
    static let extraFoldersAdd = "Add folder…"
    static let extraFolderRemove = "Remove"
    static let extraFolderMissing = "Not found"
    static let extraFoldersNeedsNewerGateway = "Needs a newer gateway"
    static func extraFoldersFootnote(brand: String) -> String {
        "Folders you browse in the Files pane, after \(brand)'s own. The agent isn't told about them; Add to chat attaches a file from one."
    }

    /// "Agent checks HTML it creates" is disabled while the agent cannot see.
    static func checksHTMLEnabled(canSee: Bool) -> Bool { canSee }
}

enum GatewayConnectionPresentation {
    static let caption = "Leave these empty: the app finds the gateway and reads its token itself. A change is used the next time it connects."
}

/// Settings › Gateway's Advanced disclosure (v0.19 §5): Address and Token
/// file sit under it, closed by default and remembered; a value in either
/// opens it by itself, so a support case is never hidden.
enum GatewaySettingsPresentation {
    static let advancedTitle = "Advanced"
    static let customConnectionNote = "Custom connection in use"

    static func isCustom(address: String, tokenFile: String) -> Bool {
        !address.isEmpty || !tokenFile.isEmpty
    }

    static func advancedOpen(stored: Bool, address: String, tokenFile: String) -> Bool {
        isCustom(address: address, tokenFile: tokenFile) ? true : stored
    }

    /// The heading's tip while a custom connection holds Advanced open.
    static let lockedOpenTip = "Clear the custom connection to close"

    /// What a click on the heading stores: nil when it is ignored, a close
    /// while a custom connection is set (the stored state is kept).
    static func storedAfterToggle(open: Bool, address: String, tokenFile: String) -> Bool? {
        if !open && isCustom(address: address, tokenFile: tokenFile) { return nil }
        return open
    }
}

/// The tabs in `SettingsTab` order; the selection is the model's, so
/// `/mcp` and `/plugin` can open Settings at their tab (v0.18 ruling 15).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                content(tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .padding(20)
        .frame(width: SettingsWindow.width, height: SettingsWindow.height)
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab()
        case .gateway: GatewaySettingsTab()
        case .mcpServers: McpServersTab()
        case .plugins: PluginsTab()
        case .voice: VoiceSettingsTab()
        case .appearance: AppearanceSettingsTab()
        }
    }
}

/// The viewable media kinds as a person reads them, in the order the tab lists them.
struct AutoOpenKindPresentation: Equatable, Sendable, Identifiable {
    let kind: String
    let label: String

    var id: String { kind }

    static let all: [AutoOpenKindPresentation] = [
        .init(kind: "markdown", label: "Markdown"),
        .init(kind: "image", label: "Images"),
        .init(kind: "html", label: "HTML pages"),
        .init(kind: "pdf", label: "PDFs"),
        .init(kind: "url", label: "Web addresses"),
    ]
}

struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let titles = GeneralSettingsPresentation.sectionTitles(capabilities: model.hello?.capabilities ?? [])
        SettingsPage {
            SettingsSection("Folder") {
                SettingsRow("Works in", help: "The folder new sessions work in. A session that is already going keeps its folder.") {
                    HStack(spacing: 10) {
                        Text(model.startFolder?.lastPathComponent ?? "None chosen")
                            .scaledFont(12)
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .tip(model.startFolder?.path ?? "")
                        if model.isFolderLocked {
                            Image(systemName: "lock")
                                .font(Theme.iconFont(11))
                                .foregroundStyle(Theme.text3)
                            Text(GeneralSettingsPresentation.folderLockedNote(brand: model.brand.name))
                                .scaledFont(11)
                                .foregroundStyle(Theme.text3)
                        } else {
                            Button("Choose…", action: chooseFolder)
                                .buttonStyle(SettingsButtonStyle(kind: .quiet))
                        }
                    }
                }
            }
            ExtraFoldersSection()
            SettingsSection("Viewer") {
                SettingsRow(
                    "Open files in the viewer automatically",
                    help: "When the agent creates or changes a file of these kinds. Anything else is listed in the chat and opens only when clicked."
                ) {
                    SettingsSwitch("Open files in the viewer automatically", isOn: $settings.autoOpen)
                }
                HStack(spacing: 10) {
                    ForEach(AutoOpenKindPresentation.all) { kind in
                        SettingsCheckbox(kind.label, isOn: binding(for: kind.kind))
                    }
                }
                .disabled(!settings.autoOpen)
                .padding(.horizontal, SettingsKit.rowHorizontal - 6)
                .padding(.vertical, SettingsKit.rowVertical - 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsRow("Agent can see the viewer", help: GeneralSettingsPresentation.canSeeNote) {
                    SettingsSwitch("Agent can see the viewer", isOn: canSeeBinding)
                }
                SettingsRow("Agent checks HTML it creates", help: GeneralSettingsPresentation.checksHTMLNote) {
                    SettingsSwitch("Agent checks HTML it creates", isOn: checksHTMLBinding)
                }
                .disabled(!GeneralSettingsPresentation.checksHTMLEnabled(canSee: model.agentCanSee))
            }
            if titles.contains("Spaces") {
                SettingsSection("Spaces") {
                    SettingsRow("Notify when a space is updated", help: GeneralSettingsPresentation.spacesNote(brand: model.brand.name)) {
                        SettingsSwitch("Notify when a space is updated", isOn: $settings.spacesNotify)
                    }
                }
            }
        }
    }

    private var canSeeBinding: Binding<Bool> {
        Binding(get: { model.agentCanSee }, set: { settings.viewerAgentCanSee = $0 })
    }

    private var checksHTMLBinding: Binding<Bool> {
        Binding(
            get: { model.agentChecksHTML },
            set: { settings.viewerAgentChecksHTML = $0 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder the agent works in"
        if let current = model.startFolder { panel.directoryURL = current }
        FilePanel.present(panel, from: NSApp.keyWindow ?? NSApp.mainWindow) { urls in
            if let folder = urls.first { model.chooseStartFolder(folder) }
        }
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { settings.autoOpenKinds.contains(kind) },
            set: { on in
                if on { settings.autoOpenKinds.insert(kind) } else { settings.autoOpenKinds.remove(kind) }
            })
    }
}

/// What Settings → Appearance says (v0.15 §3, AN3).
enum AppearanceSettingsPresentation {
    static let appearanceLabel = "Appearance"
    static let textSizeLabel = "Text size"
    static let textSizeNote = "Conversation, sidebar and documents. Web pages in the viewer keep their own size."
    static let shortcutNote = "⌘+ and ⌘− change it anywhere in the app."
}

/// AN3: one panel of two rows, no heading above it. Appearance is a
/// pop-up menu (Match the system / Light / Dark, the radio rows before
/// v0.15); Text size is a − / percent / + stepper. Under the panel, the
/// keys that do the same anywhere. Drawn with the kit (v0.19 §3).
struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        SettingsPage {
            SettingsSection("", footnote: AppearanceSettingsPresentation.shortcutNote) {
                SettingsRow(AppearanceSettingsPresentation.appearanceLabel) {
                    Picker(AppearanceSettingsPresentation.appearanceLabel, selection: $settings.appearance) {
                        ForEach(Settings.Appearance.allCases, id: \.self) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .hoverHighlight()
                }
                SettingsRow(AppearanceSettingsPresentation.textSizeLabel, help: AppearanceSettingsPresentation.textSizeNote) {
                    TextScaleStepper()
                }
            }
        }
    }
}

/// "−" | "115%" | "+": a bordered segmented stepper (AN3, corner 6). The
/// ends dim at the smallest and largest steps.
struct TextScaleStepper: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        HStack(spacing: 0) {
            segment("−", help: "Smaller Text", enabled: settings.canMakeTextSmaller) { settings.smallerText() }
            divider
            Text(Settings.percentLabel(settings.textScale))
                .scaledFont(12)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 48)
                .accessibilityLabel("Text size \(Settings.percentLabel(settings.textScale))")
            divider
            segment("+", help: "Bigger Text", enabled: settings.canMakeTextBigger) { settings.biggerText() }
        }
        .fixedSize()
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Theme.borderStrong).frame(width: 1)
    }

    private func segment(_ label: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.iconFont(13, weight: .medium))
                .foregroundStyle(enabled ? Theme.text : Theme.text3)
                .frame(width: 28)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: AnyShape(Rectangle())))
        .disabled(!enabled)
        .tip(help)
        .accessibilityLabel(help)
    }
}

struct GatewaySettingsTab: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var supervisor: GatewaySupervisor
    @State private var doctorLines: [String] = []
    @State private var doctorRunning = false

    /// Open because a custom value was there when the tab appeared: it
    /// stays open while that value is edited away.
    @State private var openedForCustom = false

    var body: some View {
        SettingsPage {
            SettingsSection(
                "Gateway",
                footnote: "Stop interrupts every running turn, runs the deployment's stop command, and exits the gateway. Restart stops it and starts it again, reading the config afresh. Doctor checks this machine, the state directory and the config, one line per check."
            ) {
                SettingsRow("State") {
                    Text(model.statusStrip(gateway: supervisor.status).gatewayText)
                        .scaledFont(12)
                        .foregroundStyle(Theme.text2)
                }
                if model.configStale {
                    HStack {
                        Label(StatusStripPresentation.restartText, systemImage: "exclamationmark.triangle")
                            .scaledFont(13)
                            .foregroundStyle(Theme.wait)
                        Spacer()
                        Button(model.restarting ? "Restarting…" : "Restart") {
                            model.request(.restart, from: .settings)
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .accent))
                        .disabled(model.restarting)
                    }
                    .settingsRowInsets()
                }
                HStack(spacing: 8) {
                    Button("Start") { model.startGateway() }
                        .buttonStyle(SettingsButtonStyle(kind: .quiet))
                        .disabled(model.connection == .connected || supervisor.status == .starting)
                    // Stop and Restart ask first while a turn runs (v0.8 decision 3).
                    Button("Stop") { model.request(.stop, from: .settings) }
                        .buttonStyle(SettingsButtonStyle(kind: .quiet))
                        .disabled(model.connection != .connected)
                    // Always offered (v0.8 decision 3); with the config
                    // stale it is the one beside the warning above.
                    if !model.configStale {
                        Button(model.restarting ? "Restarting…" : "Restart") { model.request(.restart, from: .settings) }
                            .buttonStyle(SettingsButtonStyle(kind: .quiet))
                            .disabled(model.restarting)
                    }
                    Spacer()
                    Button(doctorRunning ? "Checking…" : "Doctor") { runDoctor() }
                        .buttonStyle(SettingsButtonStyle(kind: .quiet))
                        .disabled(doctorRunning)
                }
                .settingsRowInsets()
            }
            if !doctorLines.isEmpty {
                SettingsSection("Doctor") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(doctorLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(Theme.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .settingsRowInsets()
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                }
            }
            // Moved here from General with clearer wording (v0.9 decision 7, AE2).
            SettingsSection(
                "When \(model.brand.name) quits", footnote: Settings.QuitBehaviour.caption(brand: model.brand.name)
            ) {
                SettingsRadioGroup(
                    selection: $settings.quitBehaviour,
                    options: Settings.QuitBehaviour.allCases.map { ($0, $0.label) },
                    label: "When \(model.brand.name) quits")
                    .padding(.horizontal, SettingsKit.rowHorizontal - 6)
                    .padding(.vertical, SettingsKit.rowVertical - 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsDisclosure(
                GatewaySettingsPresentation.advancedTitle, isOpen: advancedOpen,
                lockedOpen: isCustom ? GatewaySettingsPresentation.lockedOpenTip : nil
            ) {
                SettingsSection("", footnote: GatewayConnectionPresentation.caption) {
                    SettingsRow("Address") {
                        SettingsTextField("Address", text: optional($settings.gatewayURL), prompt: "discovered from the ledger")
                            .frame(width: 340)
                    }
                    SettingsRow("Token file") {
                        SettingsTextField(
                            "Token file", text: optional($settings.tokenFile),
                            prompt: supervisor.stateDir.appendingPathComponent("token").path)
                            .frame(width: 340)
                    }
                }
                if isCustom {
                    Label(GatewaySettingsPresentation.customConnectionNote, systemImage: "info.circle")
                        .scaledFont(11.5)
                        .foregroundStyle(Theme.text2)
                }
            }
        }
        .onAppear { openedForCustom = isCustom }
        .gatewayConfirmDialog(model, place: .settings)
    }

    private var isCustom: Bool {
        GatewaySettingsPresentation.isCustom(address: settings.gatewayURL ?? "", tokenFile: settings.tokenFile ?? "")
    }

    private var advancedOpen: Binding<Bool> {
        Binding(
            get: {
                openedForCustom
                    || GatewaySettingsPresentation.advancedOpen(
                        stored: settings.gatewayAdvancedOpen,
                        address: settings.gatewayURL ?? "", tokenFile: settings.tokenFile ?? "")
            },
            set: { open in
                guard let stored = GatewaySettingsPresentation.storedAfterToggle(
                    open: open, address: settings.gatewayURL ?? "", tokenFile: settings.tokenFile ?? "")
                else { return }
                settings.gatewayAdvancedOpen = stored
                if !stored { openedForCustom = false }
            })
    }

    private func runDoctor() {
        doctorRunning = true
        Task {
            doctorLines = await supervisor.runDoctor()
            doctorRunning = false
        }
    }

    /// An optional string setting as a text field: empty text clears it.
    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

/// Settings › General › Also show in Files (v0.19 §4.2): the folders the person added, each with Remove
/// (and "Not found" when it is gone), and Add folder… at the heading's right.
struct ExtraFoldersSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(GeneralSettingsPresentation.extraFoldersTitle)
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.text2)
                Spacer()
                Button(GeneralSettingsPresentation.extraFoldersAdd, action: addFolder)
                    .buttonStyle(SettingsButtonStyle(kind: .quiet))
                    .disabled(!model.offersExtraFolders)
            }
            let rows = model.extraFolderRows
            if !rows.isEmpty {
                SettingsPanel {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        folderRow(row)
                    }
                }
            }
            Text(model.extraFoldersNote)
                .scaledFont(11.5)
                .foregroundStyle(Theme.text3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderRow(_ row: ExtraFolderRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(Theme.iconFont(12))
                .foregroundStyle(row.missing ? Theme.text3 : Theme.text2)
            Text(row.name)
                .scaledFont(12.5, weight: .medium)
                .foregroundStyle(row.missing ? Theme.text3 : Theme.text)
                .lineLimit(1)
            Text(row.shownPath)
                .scaledFont(11)
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .tip(row.path)
            Spacer(minLength: 8)
            if row.missing {
                Text(GeneralSettingsPresentation.extraFolderMissing)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
            }
            Button(GeneralSettingsPresentation.extraFolderRemove) { model.removeExtraFolder(row.path) }
                .buttonStyle(SettingsButtonStyle(kind: .quiet))
        }
        .padding(.horizontal, SettingsKit.rowHorizontal)
        .padding(.vertical, SettingsKit.rowVertical)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to show in the Files pane"
        FilePanel.present(panel, from: NSApp.keyWindow ?? NSApp.mainWindow) { urls in
            if let folder = urls.first { model.addExtraFolder(folder) }
        }
    }
}
