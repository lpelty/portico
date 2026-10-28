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
            case .keepRunning: "Keep the agent running"
            case .stopEverything: "Stop everything"
            }
        }
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

    /// Files pinned in the Files pane's Quick tab (F2), by absolute path,
    /// in the order they were pinned.
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
