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
        // v0.22: thin overlay scroll bars everywhere, whatever the system setting.
        OverlayScrollers.install()
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
        // Pasted images never sent go after a week (v0.19 §8.2), off the main thread.
        let home = supervisor.home.url
        Task.detached(priority: .utility) { PastedImages.prunePending(home: home, now: Date()) }
        // Space-updated notifications need an app bundle; a bare executable
        // (`swift run`) has no notification centre to ask.
        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            let notifier = SpaceNotifier()
            notifier.open = { [weak model] id, target in model?.openSpace(id, scrollTo: target) }
            notifier.install()
            model.spaceNotifier = notifier
        }
        _settings = StateObject(wrappedValue: settings)
        _supervisor = StateObject(wrappedValue: supervisor)
        _model = StateObject(wrappedValue: model)
        // v0.26 (PORT-23): one ElevenLabs account, its key in the Keychain, reached through Read aloud.
        _reader = StateObject(wrappedValue: ReadAloud(settings: settings, account: ElevenLabsAccount(store: KeychainStore.elevenLabs())))
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

    /// The shown viewer file's media, when a viewer is on screen.
    private var shownMedia: (media: Media, missing: Bool)? {
        guard viewerShown, let chat = model.shownChat, let artifact = model.shownArtifact(for: chat) else { return nil }
        let shown = ArtifactPresentation(artifact: artifact)
        return (shown.media, shown.isMissing)
    }

    private var zoomAvailable: Bool {
        ZoomMenu.isEnabled(media: shownMedia?.media, missing: shownMedia?.missing ?? false)
    }

    /// The shown viewer's Edit switch, when a file viewer is on screen.
    private var shownEdit: ViewerEdit? {
        guard viewerShown, model.openSpace == nil, let chat = model.shownChat else { return nil }
        return ViewerEditing.shared.controller(for: chat)
    }

    private var editing: Bool { shownEdit?.isEditing ?? false }

    private var editAvailable: Bool {
        guard viewerShown, let chat = model.shownChat else { return false }
        return ViewerEditing.canToggle(artifact: model.shownArtifact(for: chat), spaceOpen: model.openSpace != nil)
    }

    private func toggleEdit() {
        guard let chat = model.shownChat, let edit = shownEdit else { return }
        edit.toggle(model.current[chat])
    }

    private var zoomTarget: (any ZoomTarget)? {
        ZoomHub.shared.target(space: model.openSpace != nil)
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
                .background(WindowTitleSetter(title: model.brand.name))
                .onChange(of: model.hello?.brand, initial: true) { _, _ in
                    model.brand.applyApplicationIcon()
                }
                .task {
                    // Text that couldn't be saved is kept under the home folder (v0.20).
                    let unsaved = supervisor.home.url.appendingPathComponent("unsaved")
                    EditSessions.shared.recoveryFolder = unsaved
                    Task.detached(priority: .utility) { EditRecovery.sweep(unsaved) }
                    EditSessions.shared.onDetachedFailure = { [model] session in
                        model.editNotice = EditNotice(name: session.name, path: session.location, chat: session.chat)
                    }
                    // After every save (and Keep mine, Restore): files.edited (§2.7).
                    EditSessions.shared.onSaved = { [model] session in
                        model.fileEdited(path: session.url.path, chat: session.chat)
                    }
                    EditSessions.shared.onResolved = { [model] session in
                        if model.editNotice?.path == session.location { model.editNotice = nil }
                    }
                    EditSessions.shared.onQuitHeld = { [model] session in
                        model.showEditedFile(path: session.location, chat: session.chat)
                        NSApplication.shared.activate()
                        NSApplication.shared.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
                    }
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
                Divider()
                // Images and PDFs (v0.20 §3.1): ⌘+ and ⌘− are the text's.
                let zoomOn = zoomAvailable
                Button("Zoom In") { zoomTarget?.zoomIn() }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                    .disabled(!zoomOn)
                Button("Zoom Out") { zoomTarget?.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                    .disabled(!zoomOn)
                Button("Zoom to Fit") { zoomTarget?.zoomToFit() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!zoomOn)
                Divider()
                // The viewer's Edit switch (v0.20 §2.2): only for a file it can edit.
                Button(editing ? "Stop Editing" : "Edit File") { toggleEdit() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!editing && !editAvailable)
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
                let conversations = ThreadMenuItem.items(
                    threads: model.threads, threadsOn: model.threadsOn, agentName: model.hello?.brand.agentName)
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
///
/// v0.20 (Review Focus 4): every file being edited is saved first. When a
/// save fails, the quit is cancelled with no alert (an alert would block
/// automation): the file is brought forward and its header says "Couldn't
/// save <name> — ⌘Q again quits and keeps your edits in <home>/unsaved/".
/// A second quit writes recovery copies of every unsaved text and quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var quitHandler: (() async -> Void)?
    /// The edit sessions a quit saves first.
    var editSessions = EditSessions.shared
    /// How far a quit with unsaved edits got (`QuitGate`).
    private(set) var quitStage: QuitGate.Stage = .none
    /// Bigger Text, for ⌘= (the menu item shows ⌘+).
    var biggerText: (() -> Void)?
    private var textKeyMonitor: Any?

    /// A bare executable (`swift run`, no app bundle) is a background-only
    /// process to AppKit: no Dock tile, no menu bar, and its window never
    /// shows. Ask for a regular app and come to the front, so the window
    /// appears from a checkout the same as it will from a bundle.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // v0.26.4: notice the diagnostics switch file without a relaunch.
        Diagnostics.start()
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

    /// v0.26.4: what the open recordings hold reaches their files before the app goes.
    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.closeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitHandler == nil && editSessions.all.isEmpty { return .terminateNow }
        Task { @MainActor in
            let proceed = await self.prepareToTerminate()
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// Save every edit, then the quit handler; false cancels the quit.
    func prepareToTerminate() async -> Bool {
        let saved = await editSessions.endAll()
        // Whenever every edit is saved, a later failure starts over.
        if saved { quitStage = .none }
        switch QuitGate.decide(saved: saved, stage: quitStage) {
        case .cancel:
            quitStage = .held
            editSessions.holdQuit()
            return false
        case .keepAndQuit:
            guard editSessions.keepAllForQuit() else {
                quitStage = .keepFailed
                return false
            }
        case .quit, .quitAnyway:
            break
        }
        await quitHandler?()
        return true
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
