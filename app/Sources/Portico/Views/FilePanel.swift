import AppKit

/// v0.17 §4.2: tooltips appear after 0.8 s instead of the system's slower
/// default. Registered in this app's own registration domain, so it is never
/// written to disk, touches no other app, and a person's own
/// `defaults write … NSInitialToolTipDelay` still wins.
enum TooltipDelay {
    static let milliseconds = 800

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["NSInitialToolTipDelay": milliseconds])
    }
}

/// v0.17 §4.3: every file picker drops from the window as a sheet, so it
/// stays with the window it belongs to instead of floating over the screen.
enum FilePanel {
    /// Shows `panel` as a sheet on `window`; `done` gets the chosen URLs on
    /// OK and is not called on Cancel. With no window it falls back to a
    /// modal panel.
    @MainActor
    static func present(_ panel: NSOpenPanel, from window: NSWindow?, done: @escaping ([URL]) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { done(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            done(panel.urls)
        }
    }
}
