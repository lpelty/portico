import AppKit
import SwiftUI

/// The settings window (spec §5.6, v0.12 §6): General (Folder, Viewer, Spaces),
/// Appearance, Gateway (address and token overrides, Start / Stop, Doctor,
/// and what quitting does, v0.9 decision 7).
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
    static let spacesNote = "A dot on the switcher, and a macOS notification while Portico is in the background."

    /// Spaces appears only on a gateway with `spaces.v1`. There is no
    /// Sessions section: Clear earlier sessions is an admin command.
    static func sectionTitles(capabilities: [String]) -> [String] {
        ["Folder", "Viewer"] + (capabilities.contains("spaces.v1") ? ["Spaces"] : [])
    }

    /// "Agent checks HTML it creates" is disabled while the agent cannot see.
    static func checksHTMLEnabled(canSee: Bool) -> Bool { canSee }
}

enum GatewayConnectionPresentation {
    static let caption = "Leave these empty: the app finds the gateway and reads its token itself. A change is used the next time it connects."
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
        Form {
            Section("Folder") {
                LabeledContent("Works in") {
                    HStack {
                        Text(model.startFolder?.lastPathComponent ?? "None chosen")
                            .tip(model.startFolder?.path ?? "")
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("The folder new sessions work in. A session that is already going keeps its folder.")
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
            Section("Viewer") {
                Toggle("Open files in the viewer automatically", isOn: $settings.autoOpen)
                Text("When the agent creates or changes a file of these kinds. Anything else is listed in the chat and opens only when clicked.")
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(AutoOpenKindPresentation.all) { kind in
                        Toggle(kind.label, isOn: binding(for: kind.kind))
                            .toggleStyle(.checkbox)
                    }
                }
                .disabled(!settings.autoOpen)
                Toggle("Agent can see the viewer", isOn: canSeeBinding)
                Text(GeneralSettingsPresentation.canSeeNote)
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
                Toggle("Agent checks HTML it creates", isOn: checksHTMLBinding)
                    .disabled(!GeneralSettingsPresentation.checksHTMLEnabled(canSee: model.agentCanSee))
                Text(GeneralSettingsPresentation.checksHTMLNote)
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
            if titles.contains("Spaces") {
                Section("Spaces") {
                    Toggle("Notify when a space is updated", isOn: $settings.spacesNotify)
                    Text(GeneralSettingsPresentation.spacesNote)
                        .scaledFont(10)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
    static let shortcutNote = "⌘+ and ⌘− change it anywhere in Portico."
}

/// AN3: one grouped panel of two rows, no heading above it. Appearance is
/// a pop-up menu (Match the system / Light / Dark, the radio rows before
/// v0.15); Text size is a − / percent / + stepper. Under the panel, the
/// keys that do the same anywhere.
struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    appearanceRow
                    Rectangle().fill(Theme.border).frame(height: 1)
                    textSizeRow
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border, lineWidth: 1))
                Text(AppearanceSettingsPresentation.shortcutNote)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                    .padding(.leading, 2)
            }
            .padding(20)
        }
    }

    private var appearanceRow: some View {
        HStack {
            Text(AppearanceSettingsPresentation.appearanceLabel)
                .scaledFont(13)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 12)
            Picker(AppearanceSettingsPresentation.appearanceLabel, selection: $settings.appearance) {
                ForEach(Settings.Appearance.allCases, id: \.self) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var textSizeRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppearanceSettingsPresentation.textSizeLabel)
                    .scaledFont(13)
                    .foregroundStyle(Theme.text)
                Text(AppearanceSettingsPresentation.textSizeNote)
                    .scaledFont(11)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TextScaleStepper()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .buttonStyle(.plain)
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

    var body: some View {
        Form {
            Section("Gateway") {
                LabeledContent("State", value: model.statusStrip(gateway: supervisor.status).gatewayText)
                if model.configStale {
                    HStack {
                        Label(StatusStripPresentation.restartText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.wait)
                        Spacer()
                        Button(model.restarting ? "Restarting…" : "Restart") {
                            model.request(.restart, from: .settings)
                        }
                        .disabled(model.restarting)
                    }
                }
                HStack {
                    Button("Start") { model.startGateway() }
                        .disabled(model.connection == .connected || supervisor.status == .starting)
                    // Stop and Restart ask first while a turn runs (v0.8 decision 3).
                    Button("Stop") { model.request(.stop, from: .settings) }
                        .disabled(model.connection != .connected)
                    // Always offered (v0.8 decision 3); with the config
                    // stale it is the one beside the warning above.
                    if !model.configStale {
                        Button(model.restarting ? "Restarting…" : "Restart") { model.request(.restart, from: .settings) }
                            .disabled(model.restarting)
                    }
                    Spacer()
                    Button(doctorRunning ? "Checking…" : "Doctor") { runDoctor() }
                        .disabled(doctorRunning)
                }
                Text("Stop interrupts every running turn, runs the deployment's stop command, and exits the gateway. Restart stops it and starts it again, reading the config afresh. Doctor checks this machine, the state directory and the config, one line per check.")
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
            if !doctorLines.isEmpty {
                Section("Doctor") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(doctorLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .scaledFont(10, design: .monospaced)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                }
            }
            // Moved here from General with clearer wording (v0.9 decision 7, AE2).
            Section("When Portico quits") {
                Picker("When Portico quits", selection: $settings.quitBehaviour) {
                    ForEach(Settings.QuitBehaviour.allCases, id: \.self) { behaviour in
                        Text(behaviour.label).tag(behaviour)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(Settings.QuitBehaviour.caption)
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                TextField("Address", text: optional($settings.gatewayURL), prompt: Text("discovered from the ledger"))
                    .textFieldStyle(.roundedBorder)
                TextField("Token file", text: optional($settings.tokenFile), prompt: Text(supervisor.stateDir.appendingPathComponent("token").path))
                    .textFieldStyle(.roundedBorder)
                Text(GatewayConnectionPresentation.caption)
                    .scaledFont(10)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .gatewayConfirmDialog(model, place: .settings)
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
