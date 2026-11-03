import AppKit
import SwiftUI

/// The app entry point: one window, the model, the settings and the
/// gateway supervisor. The window's task keeps the model attached to a
/// gateway for as long as the window is open. Started by `PorticoLaunch`.
struct PorticoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var settings: Settings
    @StateObject private var supervisor: GatewaySupervisor
    /// Voice (v0.9): Read aloud on replies, Talk into the composers.
    @StateObject private var reader: ReadAloud
    @StateObject private var dictation: Dictation

    init() {
        // v0.17: tooltips after 0.8 s, in this app's own defaults only.
        TooltipDelay.register()
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
        // Space-updated notifications need an app bundle; a bare executable
        // (`swift run`) has no notification centre to ask.
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            let notifier = SpaceNotifier()
            notifier.open = { [weak model] id in model?.setOpenSpace(id) }
            notifier.install()
            model.spaceNotifier = notifier
        }
        _settings = StateObject(wrappedValue: settings)
        _supervisor = StateObject(wrappedValue: supervisor)
        _model = StateObject(wrappedValue: model)
        _reader = StateObject(wrappedValue: ReadAloud(settings: settings))
        _dictation = StateObject(wrappedValue: Dictation(settings: settings))
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

    private var viewerShown: Bool {
        guard !model.documentMode else { return false }
        return model.shownChat.map { model.isViewerShown(for: $0) } ?? false
    }

    var body: some Scene {
        // The id names the saved window frame; "a1" starts fresh at the
        // frame's size after the three-column layout landed.
        WindowGroup(model.brand.name, id: "main-a1") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(supervisor)
                .environmentObject(reader)
                .environmentObject(dictation)
                .preferredColorScheme(settings.appearance.colorScheme)
                // One text scale for everything the window draws (v0.15 §3).
                .environment(\.textScale, CGFloat(settings.textScale))
                // The Properties block's fold, remembered (v0.17 §3.7).
                .environment(\.propertiesOpen, model.propertiesOpen)
                .environment(\.setPropertiesOpen) { [settings] open in settings.propertiesOpen = open }
                // Brand from hello (spec section 8): the accent on every
                // control (nil keeps the system accent), the icon in the Dock only
                // for a build without one of its own (v0.5).
                .tint(model.brand.accent)
                .onChange(of: model.hello?.brand, initial: true) { _, _ in
                    model.brand.applyApplicationIcon()
                }
                .task {
                    // ⌘= is Bigger Text too (v0.15 §3): the menu shows ⌘+.
                    delegate.biggerText = { [settings] in settings.biggerText() }
                    // Quit honours the setting (spec §5.5, D19): keep the
                    // agent running (detach only) or stop everything.
                    delegate.quitHandler = { [model, settings, dictation] in
                        // Talk ends unsent; the microphone is let go.
                        await dictation.cancel()
                        // The viewer comes back next launch only with
                        // something in it (v0.6).
                        model.rememberViewerForNextLaunch()
                        await model.prepareToQuit(behaviour: settings.quitBehaviour)
                    }
                    await model.run(supervisor: supervisor, settings: settings, appVersion: Self.version)
                }
                // The window closed: a talk into its composers ends, unsent.
                .onDisappear { Task { await dictation.cancel() } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Theme.defaultWindowSize.width, height: Theme.defaultWindowSize.height)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button(viewerShown ? "Hide Viewer" : "Show Viewer") {
                    if let chat = model.shownChat { model.setViewer(visible: !viewerShown, for: chat) }
                }
                .keyboardShortcut("v", modifiers: [.command, .control])
                .disabled(model.shownChat == nil || model.documentMode)
                Divider()
                Button("Quick Open…") { model.quickOpenShown = true }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.filesChat == nil)
                Button(model.documentMode ? "Back to Conversation" : "Document View") { model.toggleDocumentView() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.filesChat == nil)
                Divider()
                // One text scale (v0.15 §3). Actual Size has no key: ⌘0 is
                // Work and ⌘1–⌘9 the spaces (v0.12).
                Button("Bigger Text") { settings.biggerText() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!settings.canMakeTextBigger)
                Button("Smaller Text") { settings.smallerText() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!settings.canMakeTextSmaller)
                Button("Actual Size") { settings.actualSize() }
                    .disabled(settings.textScale == 1.0)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                let spacesShown = ToolbarLayout.showsSwitcher
                Button("Work") { model.openSpaceAt(0) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!spacesShown)
                ForEach(Array(model.spaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button(space.title) { model.openSpaceAt(index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                // v0.16 §2.4: Main and the open threads take ⌃0–⌃2 (⌘ is the spaces').
                let conversations = ThreadMenuItem.items(threads: model.threads, threadsOn: model.threadsOn)
                if !conversations.isEmpty {
                    Divider()
                    ForEach(conversations) { item in
                        Button(item.title) { model.switchToConversation(slot: item.slot) }
                            .keyboardShortcut(KeyEquivalent(Character(item.key)), modifiers: .control)
                    }
                }
            }
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
                .environmentObject(reader)
                .preferredColorScheme(settings.appearance.colorScheme)
                .environment(\.textScale, CGFloat(settings.textScale))
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
    /// Bigger Text, for ⌘= (the menu item shows ⌘+).
    var biggerText: (() -> Void)?
    private var textKeyMonitor: Any?

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
        textKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard TextScaleKeys.isBiggerAlternate(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                  let biggerText = self?.biggerText
            else { return event }
            biggerText()
            return nil
        }
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

/// ⌘= as well as ⌘+ makes text bigger (v0.15 §3), as in Safari and Mail:
/// on most layouts + is a shifted =, so ⌘= is the key people press. Pure,
/// so the test reads it without an event.
enum TextScaleKeys {
    static func isBiggerAlternate(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Caps Lock, the numeric pad and Fn ride along in the flags; only the
        // four chord modifiers decide whether this is a plain ⌘=.
        characters == "=" && modifiers.intersection([.command, .shift, .option, .control]) == .command
    }
}
