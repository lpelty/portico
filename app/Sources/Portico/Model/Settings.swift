import Foundation
import SwiftUI

/// Per-user settings, stored in `UserDefaults` (spec §5.6). Brand, actions
/// and roots are not here: they come from the gateway's `hello`.
@MainActor
final class Settings: ObservableObject {
    enum QuitBehaviour: String, CaseIterable, Sendable {
        /// Quitting the app only detaches; the gateway and its turns go on.
        case keepRunning
        /// Quitting the app stops the gateway (which runs the deployment's
        /// on-stop command first).
        case stopEverything

        var label: String {
            switch self {
            // Raw values stay as they were so saved choices survive; only
            // the wording changed (v0.9 decision 7, AE2).
            case .keepRunning: "Keep the gateway and its services running"
            case .stopEverything: "Stop the gateway and its services"
            }
        }

        /// The line under the choices in Settings › Gateway.
        static let caption = "Keeping them running lets a long turn finish while Portico is closed; reopening attaches to it. Stopping saves battery, and runs the deployment's stop command first."
    }

    enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        var label: String {
            switch self {
            case .system: "Follow system"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// How fast Read aloud speaks (v0.9, AE2 Voice pane).
    enum SpeechRate: String, CaseIterable, Sendable {
        case slow, normal, fast

        var label: String {
            switch self {
            case .slow: "Slow"
            case .normal: "Normal"
            case .fast: "Fast"
            }
        }

        /// The utterance rate: `AVSpeechUtteranceDefaultSpeechRate` is 0.5
        /// on a 0–1 scale, and a step either side stays easy to follow.
        var utteranceRate: Float {
            switch self {
            case .slow: 0.42
            case .normal: 0.5
            case .fast: 0.58
            }
        }
    }

    /// A key held to talk while the window is key (v0.9 decision 1). None
    /// by default: Fn belongs to the system's dictation and to dictation
    /// tools, so the mic button is the way in unless the person picks one.
    enum HoldToTalk: String, CaseIterable, Sendable {
        case none
        case rightOption

        var label: String {
            switch self {
            case .none: "None"
            case .rightOption: "Hold Right Option"
            }
        }
    }

    /// The media kinds that may auto-open (spec §5.3): everything else is
    /// listed in the history and never opens on its own.
    static let viewableKinds: Set<String> = ["markdown", "image", "html", "pdf", "url"]

    enum Key {
        static let autoOpen = "autoOpen"
        static let autoOpenKinds = "autoOpenKinds"
        static let quitBehaviour = "quitBehaviour"
        static let appearance = "appearance"
        static let gatewayURL = "gatewayURL"
        static let tokenFile = "tokenFile"
        static let lastFolder = "lastFolder"
        static let pinnedFiles = "pinnedFiles"
        static let sidebarWidth = "sidebarWidth"
        static let readingWidth = "viewerWidth.reading"
        static let canvasWidth = "viewerWidth.canvas"
        static let earlierHeight = "earlierHeight"
        static let viewerAtQuit = "viewerAtQuit"
        static let voiceInputEnabled = "voice.inputEnabled"
        static let sendWhenStopTalking = "voice.sendWhenStopTalking"
        static let holdToTalk = "voice.holdToTalk"
        static let readAloudEnabled = "voice.readAloudEnabled"
        static let voiceIdentifier = "voice.identifier"
        static let speechRate = "voice.speechRate"
    }

    private let defaults: UserDefaults

    @Published var autoOpen: Bool { didSet { defaults.set(autoOpen, forKey: Key.autoOpen) } }
    @Published var autoOpenKinds: Set<String> {
        didSet { defaults.set(Array(autoOpenKinds).sorted(), forKey: Key.autoOpenKinds) }
    }
    @Published var quitBehaviour: QuitBehaviour {
        didSet { defaults.set(quitBehaviour.rawValue, forKey: Key.quitBehaviour) }
    }
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    /// A gateway address to use instead of discovering one (`ws://127.0.0.1:<port>`); `nil` means discover.
    @Published var gatewayURL: String? {
        didSet { Self.store(gatewayURL, forKey: Key.gatewayURL, in: defaults) }
    }
    /// Where the token file is read from when it is not in the state directory; `nil` means the default.
    @Published var tokenFile: String? {
        didSet { Self.store(tokenFile, forKey: Key.tokenFile, in: defaults) }
    }

    /// The folder the last chat started in; the start screen's folder chip begins there.
    @Published var lastFolder: String? {
        didSet { Self.store(lastFolder, forKey: Key.lastFolder, in: defaults) }
    }

    /// Files bookmarked in the Files pane's Bookmarks tab (F2), by absolute path,
    /// in the order they were added. The key keeps v0.2's name (`pinnedFiles`) so bookmarks made before v0.4 survive.
    @Published var pinnedFiles: [String] {
        didSet { defaults.set(pinnedFiles, forKey: Key.pinnedFiles) }
    }

    /// The sidebar's width as last dragged.
    @Published var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: Key.sidebarWidth) }
    }
    /// The viewer's width as last dragged, one per fit (documents, web).
    @Published var readingWidth: CGFloat {
        didSet { defaults.set(Double(readingWidth), forKey: Key.readingWidth) }
    }
    @Published var canvasWidth: CGFloat {
        didSet { defaults.set(Double(canvasWidth), forKey: Key.canvasWidth) }
    }

    /// The single-session sidebar's EARLIER list height as last dragged;
    /// `nil` until the person drags it (the list then fits its sessions).
    @Published var earlierHeight: CGFloat? {
        didSet {
            if let earlierHeight { defaults.set(Double(earlierHeight), forKey: Key.earlierHeight) }
            else { defaults.removeObject(forKey: Key.earlierHeight) }
        }
    }

    // MARK: voice (v0.9 decisions 1, 2; AE2 Voice pane)

    /// Talk: the mic in the composers; off hides it.
    @Published var voiceInputEnabled: Bool {
        didSet { defaults.set(voiceInputEnabled, forKey: Key.voiceInputEnabled) }
    }
    /// Stopping the mic sends what was said, instead of leaving it to glance at.
    @Published var sendWhenStopTalking: Bool {
        didSet { defaults.set(sendWhenStopTalking, forKey: Key.sendWhenStopTalking) }
    }
    @Published var holdToTalk: HoldToTalk {
        didSet { defaults.set(holdToTalk.rawValue, forKey: Key.holdToTalk) }
    }
    /// Listen: Read aloud on each reply; off hides it.
    @Published var readAloudEnabled: Bool {
        didSet { defaults.set(readAloudEnabled, forKey: Key.readAloudEnabled) }
    }
    /// The voice's identifier (`AVSpeechSynthesisVoice.identifier`); `nil` is the system default.
    @Published var voiceIdentifier: String? {
        didSet { Self.store(voiceIdentifier, forKey: Key.voiceIdentifier, in: defaults) }
    }
    @Published var speechRate: SpeechRate {
        didSet { defaults.set(speechRate.rawValue, forKey: Key.speechRate) }
    }

    /// The artifact the viewer showed when the app last quit, and in which
    /// session (v0.6); `nil` when it was closed or empty. Read at launch to
    /// decide whether the viewer comes back.
    var viewerAtQuit: SavedViewer? {
        get {
            guard let saved = defaults.dictionary(forKey: Key.viewerAtQuit),
                let chat = saved["chat"] as? Int, let artifact = saved["artifact"] as? String, !artifact.isEmpty
            else { return nil }
            return SavedViewer(chat: chat, artifact: artifact)
        }
        set {
            if let newValue {
                defaults.set(["chat": newValue.chat, "artifact": newValue.artifact], forKey: Key.viewerAtQuit)
            } else {
                defaults.removeObject(forKey: Key.viewerAtQuit)
            }
        }
    }

    func viewerWidth(for fit: ColumnWidths.Fit) -> CGFloat {
        fit == .canvas ? canvasWidth : readingWidth
    }

    func setViewerWidth(_ width: CGFloat, for fit: ColumnWidths.Fit) {
        if fit == .canvas { canvasWidth = width } else { readingWidth = width }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoOpen = defaults.object(forKey: Key.autoOpen) as? Bool ?? true
        if let kinds = defaults.stringArray(forKey: Key.autoOpenKinds) {
            autoOpenKinds = Set(kinds)
        } else {
            autoOpenKinds = Self.viewableKinds
        }
        quitBehaviour = defaults.string(forKey: Key.quitBehaviour).flatMap(QuitBehaviour.init(rawValue:)) ?? .keepRunning
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        gatewayURL = Self.read(Key.gatewayURL, in: defaults)
        tokenFile = Self.read(Key.tokenFile, in: defaults)
        lastFolder = Self.read(Key.lastFolder, in: defaults)
        pinnedFiles = defaults.stringArray(forKey: Key.pinnedFiles) ?? []
        sidebarWidth = Self.width(Key.sidebarWidth, in: defaults) ?? ColumnWidths.sidebarDefault
        readingWidth = Self.width(Key.readingWidth, in: defaults) ?? ColumnWidths.viewerDefault
        canvasWidth = Self.width(Key.canvasWidth, in: defaults) ?? ColumnWidths.canvasDefault
        earlierHeight = Self.width(Key.earlierHeight, in: defaults)
        voiceInputEnabled = defaults.object(forKey: Key.voiceInputEnabled) as? Bool ?? true
        sendWhenStopTalking = defaults.object(forKey: Key.sendWhenStopTalking) as? Bool ?? false
        holdToTalk = defaults.string(forKey: Key.holdToTalk).flatMap(HoldToTalk.init(rawValue:)) ?? .none
        readAloudEnabled = defaults.object(forKey: Key.readAloudEnabled) as? Bool ?? true
        voiceIdentifier = Self.read(Key.voiceIdentifier, in: defaults)
        speechRate = defaults.string(forKey: Key.speechRate).flatMap(SpeechRate.init(rawValue:)) ?? .normal
    }

    /// Whether an artifact of `media` should open on its own.
    func shouldAutoOpen(media: String) -> Bool {
        autoOpen && Self.viewableKinds.contains(media) && autoOpenKinds.contains(media)
    }

    private static func width(_ key: String, in defaults: UserDefaults) -> CGFloat? {
        guard let value = defaults.object(forKey: key) as? Double, value > 0 else { return nil }
        return CGFloat(value)
    }

    private static func read(_ key: String, in defaults: UserDefaults) -> String? {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func store(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }
}
