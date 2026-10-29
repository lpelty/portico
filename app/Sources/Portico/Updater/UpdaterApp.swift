import AppKit
import SwiftUI

/// The app in updater mode (`--update`): one small window that runs the
/// update and shows its output; see `Updater`.
struct UpdaterApp: App {
    @NSApplicationDelegateAdaptor(UpdaterDelegate.self) private var delegate
    @StateObject private var runner = UpdateRunner()

    var body: some Scene {
        Window("Updating \(Updater.brandName())…", id: "updater") {
            UpdaterView(brand: Updater.brandName())
                .environmentObject(runner)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 360)
    }
}

/// Like the main app's delegate: a bare executable asks to be a regular
/// app so its window shows. Closing the window quits.
@MainActor
final class UpdaterDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
        }
        app.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// "Updating Portico…": a spinner while the command runs, its output
/// as it arrives, and on failure the log stays with an Open button.
struct UpdaterView: View {
    let brand: String
    @EnvironmentObject private var runner: UpdateRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if runner.state == .running || runner.state == .idle {
                    ProgressView().controlSize(.small)
                }
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(runner.lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .onChange(of: runner.lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            if failed {
                HStack {
                    Text("Nothing was reopened. The log above says what happened.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Open \(brand)") { Updater.reopenApp() }
                        .buttonStyle(PillButtonStyle(kind: .primary(Theme.accent)))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 320)
        .background(Theme.window)
        .task {
            let result = await runner.run()
            if result == .succeeded { Updater.reopenApp() }
        }
    }

    private var failed: Bool {
        switch runner.state {
        case .failed, .couldNotStart: true
        default: false
        }
    }

    private var headline: String {
        switch runner.state {
        case .idle, .running: "Updating \(brand)…"
        case .succeeded: "Updated. Opening \(brand)…"
        case .failed, .couldNotStart: "The update did not finish"
        }
    }
}
