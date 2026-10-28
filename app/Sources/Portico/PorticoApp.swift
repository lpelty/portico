import SwiftUI

/// The app entry point: one window, the model, the settings and the
/// gateway supervisor. The window's task keeps the model attached to a
/// gateway for as long as the window is open.
@main
struct PorticoApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settings: Settings
    @StateObject private var supervisor = GatewaySupervisor()

    init() {
        // The model reads the auto-open settings (spec §5.3), so it holds the
        // same `Settings` object the settings scene edits.
        let settings = Settings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
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
        WindowGroup(model.hello?.brand.name ?? "Portico") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(supervisor)
                .preferredColorScheme(settings.appearance.colorScheme)
                .task {
                    await model.run(supervisor: supervisor, settings: settings, appVersion: Self.version)
                }
        }
    }
}
