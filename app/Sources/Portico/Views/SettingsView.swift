import AppKit
import SwiftUI

/// The settings window (spec §5.6): General (auto-open, quit behaviour),
/// Appearance, Gateway (address and token overrides, Start / Stop, Doctor).
/// Brand, actions and roots are the gateway's, not here.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            GatewaySettingsTab()
                .tabItem { Label("Gateway", systemImage: "server.rack") }
        }
        .frame(width: 520)
        .padding(20)
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
        .init(kind: "pdf", label: "PDF documents"),
        .init(kind: "url", label: "Web addresses"),
    ]
}

struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Folder") {
                LabeledContent("Works in") {
                    HStack {
                        Text(model.startFolder?.lastPathComponent ?? "None chosen")
                            .help(model.startFolder?.path ?? "")
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("The folder new sessions work in. A session that is already going keeps its folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Artifacts") {
                Toggle("Open artifacts automatically", isOn: $settings.autoOpen)
                ForEach(AutoOpenKindPresentation.all) { kind in
                    Toggle(kind.label, isOn: binding(for: kind.kind))
                        .disabled(!settings.autoOpen)
                        .padding(.leading, 20)
                }
                Text("Anything else is listed in the chat's history and never opens on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("When I quit") {
                Picker("When I quit", selection: $settings.quitBehaviour) {
                    ForEach(Settings.QuitBehaviour.allCases, id: \.self) { behaviour in
                        Text(behaviour.label).tag(behaviour)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Keeping the agent running lets a long turn finish while the app is closed; reopening attaches to it. Stop everything stops the gateway, which runs the deployment's stop command first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.chooseStartFolder(folder)
    }

    private func binding(for kind: String) -> Binding<Bool> {
        Binding(
            get: { settings.autoOpenKinds.contains(kind) },
            set: { on in
                if on { settings.autoOpenKinds.insert(kind) } else { settings.autoOpenKinds.remove(kind) }
            })
    }
}

struct AppearanceSettingsTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(Settings.Appearance.allCases, id: \.self) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
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
            Section("Connection") {
                TextField("Address", text: optional($settings.gatewayURL), prompt: Text("discovered from the ledger"))
                    .textFieldStyle(.roundedBorder)
                TextField("Token file", text: optional($settings.tokenFile), prompt: Text(supervisor.stateDir.appendingPathComponent("token").path))
                    .textFieldStyle(.roundedBorder)
                Text("Defaults that never need touching: the app finds the gateway through \(supervisor.ledgerURL.path) and reads its token on every attach. A change is used on the next attach.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !doctorLines.isEmpty {
                Section("Doctor") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(doctorLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                }
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
