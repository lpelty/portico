import Foundation

/// v0.26.4: the diagnostics suite's switch and directory. Everything the app
/// writes for diagnostics goes under `<home>/diagnostics/`; the file
/// `diagnostics/on` (made by `portico-gateway diagnostics on`) turns it on and
/// the app notices it without a relaunch. Off costs one `fileExists` per poll.
@MainActor
enum Diagnostics {
    /// The app's home; tests point it at a temp folder.
    static var home: URL = GatewaySupervisor.resolveHome().url
    static var directory: URL { home.appendingPathComponent("diagnostics", isDirectory: true) }
    static var switchFile: URL { directory.appendingPathComponent("on") }
    static var tracePath: URL { directory.appendingPathComponent("trace.log") }
    static var recordingsDirectory: URL { directory.appendingPathComponent("recordings", isDirectory: true) }
    static var evaluationsDirectory: URL { directory.appendingPathComponent("evaluations", isDirectory: true) }

    static private(set) var isOn = false
    /// Called with the new value whenever the switch changes.
    static var onChange: [(Bool) -> Void] = []
    private static var poll: Task<Void, Never>?

    /// Reads the switch once.
    static func refresh() {
        let now = FileManager.default.fileExists(atPath: switchFile.path)
        // Off then on again inside one poll: the open trace points at a deleted file.
        if now, isOn, ScrollTrace.isOpen, !FileManager.default.fileExists(atPath: tracePath.path) {
            ScrollTrace.closeHandle()
        }
        guard now != isOn else { return }
        isOn = now
        // The folder is going away under an open trace: let go of it.
        if !now { ScrollTrace.closeHandle() }
        for handler in onChange { handler(now) }
    }

    /// Polls the switch on the main actor; a second call does nothing.
    static func start(pollEvery seconds: TimeInterval = 3) {
        guard poll == nil else { return }
        poll = Task { @MainActor in
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Stops the poll (tests).
    static func stop() {
        poll?.cancel()
        poll = nil
    }
}
