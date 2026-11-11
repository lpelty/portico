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
    /// Posted (main thread) whenever the switch changes; each open conversation
    /// starts or stops its recording on it. Unlike `onChange`, nothing resets it.
    static let switched = Notification.Name("PorticoDiagnosticsSwitched")
    /// The conversation recorders made since the switch last turned on, by chat.
    static private(set) var recorders: [Int: Recorder] = [:]
    private static var poll: Task<Void, Never>?

    /// Reads the switch once.
    static func refresh() {
        let now = FileManager.default.fileExists(atPath: switchFile.path)
        // Off then on again inside one poll: the open trace points at a deleted file.
        if now, isOn, ScrollTrace.isOpen, !FileManager.default.fileExists(atPath: tracePath.path) {
            ScrollTrace.closeHandle()
        }
        // Off then on again inside one poll: the open recordings point into a deleted
        // `recordings/`. Close them; the views start fresh on the notice.
        if now, isOn, !recorders.isEmpty, !FileManager.default.fileExists(atPath: recordingsDirectory.path) {
            closeAll()
            NotificationCenter.default.post(name: switched, object: nil)
        }
        guard now != isOn else { return }
        isOn = now
        // The folder is going away under an open trace and recordings: let go of them.
        if !now {
            ScrollTrace.closeHandle()
            closeAll()
        }
        NotificationCenter.default.post(name: switched, object: nil)
        for handler in onChange { handler(now) }
    }

    /// The chat's recorder: `nil` while off; made on the first ask after the
    /// switch turns on (its file opens then), the same one after that.
    static func recorder(for chat: Int) -> Recorder? {
        guard isOn else { return nil }
        if let made = recorders[chat] { return made }
        let made = Recorder(chat: chat, directory: recordingsDirectory)
        recorders[chat] = made
        return made
    }

    /// Closes and forgets every recorder (switch off, app quit, tests).
    static func closeAll() {
        for recorder in recorders.values { recorder.close() }
        recorders = [:]
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
