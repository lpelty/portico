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
        static func caption(brand: String) -> String {
            "Keeping them running lets a long turn finish while \(brand) is closed; reopening attaches to it. Stopping saves battery, and runs the deployment's stop command first."
        }
    }

    enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark

        var label: String {
            switch self {
            case .system: "Match the system"
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
        static let textScale = "textScale"
        static let gatewayURL = "gatewayURL"
        static let tokenFile = "tokenFile"
        static let lastFolder = "lastFolder"
        static let pinnedFiles = "pinnedFiles"
        static let extraFolders = "extraFolders"
        static let sidebarWidth = "sidebarWidth"
        static let readingWidth = "viewerWidth.reading"
        static let canvasWidth = "viewerWidth.canvas"
        static let spaceWidth = "viewerWidth.space"
        static let viewerAtQuit = "viewerAtQuit"
        static let voiceInputEnabled = "voice.inputEnabled"
        static let sendWhenStopTalking = "voice.sendWhenStopTalking"
        static let holdToTalk = "voice.holdToTalk"
        static let readAloudEnabled = "voice.readAloudEnabled"
        static let wrapCode = "conversation.wrapCode"
        static let readAloudAvailable = "voice.readAloudAvailable"
        static let voiceIdentifier = "voice.identifier"
        static let speechRate = "voice.speechRate"
        static let viewerAgentCanSee = "viewer.agentCanSee"
        static let viewerAgentChecksHTML = "viewer.agentChecksHTML"
        static let propertiesOpen = "viewer.propertiesOpen"
        static let spacesNotify = "spaces.notify"
        static let gatewayAdvancedOpen = "gateway.advancedOpen"
        static let spacesLastOpened = "spaces.lastOpened"
        static let spacesFirstSeen = "spaces.firstSeen"
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

    // MARK: text size (v0.15 §3, AN3)

    /// The text scale's steps: 85, 100, 115, 130 and 150%.
    static let textScaleSteps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5]

    /// One scale for every piece of text the app draws (v0.15 §3); always
    /// one of `textScaleSteps`, a value between them taken to the nearest.
    @Published var textScale: Double {
        didSet {
            // Assigning inside its own didSet does not call didSet again.
            let step = Self.nearestTextScale(textScale)
            if step != textScale { textScale = step }
            defaults.set(textScale, forKey: Key.textScale)
        }
    }

    /// The View menu's Bigger Text (⌘+): the next step up; the last stays.
    func biggerText() {
        let index = Self.textScaleSteps.firstIndex(of: textScale) ?? 1
        textScale = Self.textScaleSteps[min(index + 1, Self.textScaleSteps.count - 1)]
    }

    /// Smaller Text (⌘−): the next step down; the first stays.
    func smallerText() {
        let index = Self.textScaleSteps.firstIndex(of: textScale) ?? 1
        textScale = Self.textScaleSteps[max(index - 1, 0)]
    }

    /// Actual Size: back to 100%.
    func actualSize() { textScale = 1.0 }

    var canMakeTextBigger: Bool { textScale < Self.textScaleSteps[Self.textScaleSteps.count - 1] }
    var canMakeTextSmaller: Bool { textScale > Self.textScaleSteps[0] }

    /// The step nearest `value` (a value stored by hand, or out of range).
    static func nearestTextScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return textScaleSteps.min { abs($0 - value) < abs($1 - value) } ?? 1.0
    }

    /// The stepper's reading: "115%".
    static func percentLabel(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
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

    /// Folders the person added to the Files pane (Settings › General › Also
    /// show in Files, v0.19 §4.2), by absolute path, in the order added.
    @Published var extraFolders: [String] {
        didSet { defaults.set(extraFolders, forKey: Key.extraFolders) }
    }

    /// The sidebar's width as last dragged.
    @Published var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: Key.sidebarWidth) }
    }
    /// The viewer's width as last dragged, one per fit (documents, web).
    @Published var readingWidth: CGFloat {
        didSet { defaults.set(Double(readingWidth), forKey: Key.readingWidth) }
    }
    @Published var spaceWidth: CGFloat {
        didSet { defaults.set(Double(spaceWidth), forKey: Key.spaceWidth) }
    }
    @Published var canvasWidth: CGFloat {
        didSet { defaults.set(Double(canvasWidth), forKey: Key.canvasWidth) }
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
    /// The Read aloud feature at all (v0.9, Larry 10-29): off by default and
    /// not in Settings, because the voices the Mac lets apps use sound dated.
    /// The code stays for a better voice later. Turn it on with
    /// `defaults write dev.portico.portico voice.readAloudAvailable -bool YES`.
    let readAloudAvailable: Bool
    /// Code blocks with a language wrap long lines when true (v0.19 §9);
    /// prose in a fence always wraps. The code block header's toggle flips it.
    @Published var wrapCode: Bool {
        didSet { defaults.set(wrapCode, forKey: Key.wrapCode) }
    }

    /// Read aloud is offered: the hidden flag, then the person's setting.
    var readAloudShown: Bool { readAloudAvailable && readAloudEnabled }
    /// The voice's identifier (`AVSpeechSynthesisVoice.identifier`); `nil` is the system default.
    @Published var voiceIdentifier: String? {
        didSet { Self.store(voiceIdentifier, forKey: Key.voiceIdentifier, in: defaults) }
    }
    @Published var speechRate: SpeechRate {
        didSet { defaults.set(speechRate.rawValue, forKey: Key.speechRate) }
    }

    // MARK: viewer vision and spaces (v0.12)

    /// The person's choice for "Agent can see the viewer"; `nil` until they
    /// choose, which means the deployment's default (`hello.viewer_defaults`).
    @Published var viewerAgentCanSee: Bool? {
        didSet { Self.store(viewerAgentCanSee, forKey: Key.viewerAgentCanSee, in: defaults) }
    }
    /// The person's choice for "Agent checks HTML it creates"; `nil` as above.
    @Published var viewerAgentChecksHTML: Bool? {
        didSet { Self.store(viewerAgentChecksHTML, forKey: Key.viewerAgentChecksHTML, in: defaults) }
    }
    /// Whether a front-matter Properties block opens unfolded: the
    /// person's last toggle of one (v0.17 §3.7); `nil` until the first, so
    /// the deployment's `[viewer] properties` applies.
    @Published var propertiesOpen: Bool? {
        didSet { Self.store(propertiesOpen, forKey: Key.propertiesOpen, in: defaults) }
    }
    /// Whether Settings › Gateway's Advanced disclosure is open (v0.19 §5);
    /// closed until the person opens it.
    @Published var gatewayAdvancedOpen: Bool {
        didSet { defaults.set(gatewayAdvancedOpen, forKey: Key.gatewayAdvancedOpen) }
    }
    /// "Notify when a space is updated": the dot and the notification.
    @Published var spacesNotify: Bool {
        didSet { defaults.set(spacesNotify, forKey: Key.spacesNotify) }
    }
    /// When each space (by id) was last opened here; a space changed after
    /// that has something new.
    @Published var spacesLastOpened: [String: Date] {
        didSet {
            defaults.set(spacesLastOpened.mapValues { $0.timeIntervalSince1970 }, forKey: Key.spacesLastOpened)
        }
    }

    /// When this app first saw each space (by id). A space is new only if it
    /// changed after both this and the last time it was opened, so a first
    /// launch shows no dots.
    @Published var spacesFirstSeen: [String: Date] {
        didSet {
            defaults.set(spacesFirstSeen.mapValues { $0.timeIntervalSince1970 }, forKey: Key.spacesFirstSeen)
        }
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
        switch fit {
        case .canvas: canvasWidth
        case .space: spaceWidth
        case .reading: readingWidth
        }
    }

    func setViewerWidth(_ width: CGFloat, for fit: ColumnWidths.Fit) {
        switch fit {
        case .canvas: canvasWidth = width
        case .space: spaceWidth = width
        case .reading: readingWidth = width
        }
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
        textScale = Self.nearestTextScale(defaults.object(forKey: Key.textScale) as? Double ?? 1.0)
        gatewayURL = Self.read(Key.gatewayURL, in: defaults)
        tokenFile = Self.read(Key.tokenFile, in: defaults)
        lastFolder = Self.read(Key.lastFolder, in: defaults)
        pinnedFiles = defaults.stringArray(forKey: Key.pinnedFiles) ?? []
        extraFolders = defaults.stringArray(forKey: Key.extraFolders) ?? []
        sidebarWidth = Self.width(Key.sidebarWidth, in: defaults) ?? ColumnWidths.sidebarDefault
        readingWidth = Self.width(Key.readingWidth, in: defaults) ?? ColumnWidths.viewerDefault
        canvasWidth = Self.width(Key.canvasWidth, in: defaults) ?? ColumnWidths.canvasDefault
        spaceWidth = Self.width(Key.spaceWidth, in: defaults) ?? ColumnWidths.spaceDefault
        voiceInputEnabled = defaults.object(forKey: Key.voiceInputEnabled) as? Bool ?? true
        sendWhenStopTalking = defaults.object(forKey: Key.sendWhenStopTalking) as? Bool ?? false
        holdToTalk = defaults.string(forKey: Key.holdToTalk).flatMap(HoldToTalk.init(rawValue:)) ?? .none
        readAloudEnabled = defaults.object(forKey: Key.readAloudEnabled) as? Bool ?? true
        wrapCode = defaults.object(forKey: Key.wrapCode) as? Bool ?? false
        readAloudAvailable = defaults.bool(forKey: Key.readAloudAvailable)
        voiceIdentifier = Self.read(Key.voiceIdentifier, in: defaults)
        speechRate = defaults.string(forKey: Key.speechRate).flatMap(SpeechRate.init(rawValue:)) ?? .normal
        viewerAgentCanSee = defaults.object(forKey: Key.viewerAgentCanSee) as? Bool
        viewerAgentChecksHTML = defaults.object(forKey: Key.viewerAgentChecksHTML) as? Bool
        propertiesOpen = defaults.object(forKey: Key.propertiesOpen) as? Bool
        spacesNotify = defaults.object(forKey: Key.spacesNotify) as? Bool ?? true
        gatewayAdvancedOpen = defaults.bool(forKey: Key.gatewayAdvancedOpen)
        let opened = defaults.dictionary(forKey: Key.spacesLastOpened) as? [String: Double] ?? [:]
        spacesLastOpened = opened.mapValues { Date(timeIntervalSince1970: $0) }
        let seen = defaults.dictionary(forKey: Key.spacesFirstSeen) as? [String: Double] ?? [:]
        spacesFirstSeen = seen.mapValues { Date(timeIntervalSince1970: $0) }
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

    private static func store(_ value: Bool?, forKey key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
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
