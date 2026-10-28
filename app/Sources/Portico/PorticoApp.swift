import AppKit
import SwiftUI

/// The app entry point: one window, the model, the settings and the
/// gateway supervisor. The window's task keeps the model attached to a
/// gateway for as long as the window is open.
@main
struct PorticoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var settings: Settings
    @StateObject private var supervisor: GatewaySupervisor

    init() {
        // The model reads the auto-open settings (spec §5.3), so it holds the
        // same `Settings` object the settings scene edits.
        let settings = Settings()
        let supervisor = GatewaySupervisor()
        let model = AppModel(settings: settings)
        // So Start from the settings window works before the main window's
        // loop has run (or after it closed), and a quit with "stop
        // everything" after the window closed can still reach the gateway.
        model.supervisor = supervisor
        model.appVersion = Self.version
        _settings = StateObject(wrappedValue: settings)
        _supervisor = StateObject(wrappedValue: supervisor)
        _model = StateObject(wrappedValue: model)
    }

    /// The app's version, sent in `hello`: the repo's VERSION file when the
    /// app runs from a checkout, else the bundle's, else a dev marker.
    static let version: String = {
        if let bundled = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !bundled.isEmpty {
            return bundled
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("VERSION")
                if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                dir = dir.deletingLastPathComponent()
                if dir.path == "/" { break }
            }
        }
        return "0.0.0-dev"
    }()

    var body: some Scene {
        WindowGroup(model.brand.name) {
            MainWindow()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(supervisor)
                .preferredColorScheme(settings.appearance.colorScheme)
                // Brand from hello (spec section 8): the accent on every
                // control (nil keeps the system accent), the icon in the Dock.
                .tint(model.brand.accent)
                .onChange(of: model.hello?.brand, initial: true) { _, _ in
                    model.brand.applyApplicationIcon()
                }
                .task {
                    // Quit honours the setting (spec §5.5, D19): keep the
                    // agent running (detach only) or stop everything.
                    delegate.quitHandler = { [model, settings] in
                        await model.prepareToQuit(behaviour: settings.quitBehaviour)
                    }
                    await model.run(supervisor: supervisor, settings: settings, appVersion: Self.version)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(model.brand.name)") {
                    model.brand.showAboutPanel(version: Self.version)
                }
            }
            CommandMenu("Agent") {
                Button("Start") { model.startGateway() }
                    .disabled(model.connection == .connected || supervisor.status == .starting)
                Button("Stop") { Task { await model.stopGateway() } }
                    .disabled(model.connection != .connected)
            }
        }

        SwiftUI.Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(supervisor)
                .preferredColorScheme(settings.appearance.colorScheme)
                .tint(model.brand.accent)
        }
    }
}

/// Holds quit until the gateway has been dealt with the way the setting
/// says. With "keep the agent running" the handler returns at once; with
/// "stop everything" it sends `gateway.stop` and waits up to ten seconds
/// for the socket to close, then the app terminates either way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var quitHandler: (() async -> Void)?

    /// A bare executable (`swift run`, no app bundle) is a background-only
    /// process to AppKit: no Dock tile, no menu bar, and its window never
    /// shows. Ask for a regular app and come to the front, so the window
    /// appears from a checkout the same as it will from a bundle.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitHandler else { return .terminateNow }
        Task { @MainActor in
            await quitHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
