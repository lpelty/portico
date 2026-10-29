import AppKit
import Foundation

/// Self-update from the app (spec decision 14). "Update available"
/// relaunches this same binary in updater mode (`--update`): a small window
/// that runs `<gateway command> update` — which stops a running gateway,
/// runs the deployment's `update.run` and exits with its code — showing its
/// output as it comes. On success it reopens the app (without `--update`)
/// and quits; on failure it keeps the window with the log and an Open
/// button. Portico owns the window and the relaunch; the deployment owns
/// the commands.
enum Updater {
    static let flag = "--update"
    /// `--wait-pid <pid>`: the app that asked for the update. The updater
    /// waits for it to exit before running the update, so the old app
    /// cannot start the gateway again in the middle of it.
    static let waitFlag = "--wait-pid"
    /// How long the updater waits for the old app to quit.
    static let waitSeconds: Double = 30

    /// This launch is the updater's.
    static func isUpdaterLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// The arguments to launch the app again with (no program name): the
    /// ones it had, without `--update` and `--wait-pid <pid>` (and without
    /// the `-psn_` serial LaunchServices adds), plus `--update` and
    /// `--wait-pid <this pid>` when `updating`.
    static func relaunchArguments(
        _ arguments: [String] = CommandLine.arguments, updating: Bool,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [String] {
        var kept: [String] = []
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            if argument == waitFlag {
                _ = rest.popFirst()
            } else if argument != flag && !argument.hasPrefix("-psn_") {
                kept.append(argument)
            }
        }
        if updating { kept += [flag, waitFlag, String(pid)] }
        return kept
    }

    /// The pid after `--wait-pid`, if any.
    static func waitPid(_ arguments: [String] = CommandLine.arguments) -> pid_t? {
        guard let index = arguments.dropFirst().firstIndex(of: waitFlag), index + 1 < arguments.count else { return nil }
        guard let pid = pid_t(arguments[index + 1]), pid > 0 else { return nil }
        return pid
    }

    /// Whether a process with `pid` still exists.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// The name the updater window uses: the bundle's display name (an
    /// installed `.app` is named for the brand), else Portico.
    static func brandName(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info?[key] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return "Portico"
    }

    /// The `.app` this process runs from, if it runs from one (a `swift
    /// run` build has none).
    static func appBundle(_ bundle: Bundle = .main) -> URL? {
        bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil
    }

    /// The main app's "Update available": start the updater and quit.
    @MainActor
    static func relaunchForUpdate() {
        launchSelf(arguments: relaunchArguments(updating: true)) { NSApp.terminate(nil) }
    }

    /// The updater's last step: open the app again, then quit.
    @MainActor
    static func reopenApp(thenQuit: Bool = true) {
        launchSelf(arguments: relaunchArguments(updating: false)) {
            if thenQuit { NSApp.terminate(nil) }
        }
    }

    /// Launch another instance of this app: through LaunchServices for an
    /// `.app` (a new instance, since this one is still running), else the
    /// executable directly.
    @MainActor
    private static func launchSelf(arguments: [String], then done: @escaping @MainActor () -> Void) {
        if let bundle = appBundle() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
                Task { @MainActor in done() }
            }
        } else if let executable = Bundle.main.executableURL {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            try? process.run()
            done()
        }
    }
}

/// Runs the update command and collects its output, line by line, for the
/// updater window.
@MainActor
final class UpdateRunner: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(Int32)
        case couldNotStart(String)
    }

    @Published private(set) var lines: [String] = []
    @Published private(set) var state: State = .idle

    private let resolve: () throws -> URL
    private let arguments: [String]
    private let environment: [String: String]
    private let waitFor: pid_t?
    private let waitSeconds: Double
    private var partial = ""

    /// - Parameters:
    ///   - resolve: finds the command; by default the gateway command, as
    ///     the supervisor looks it up.
    ///   - arguments: `["update"]`.
    ///   - waitFor: the old app's pid (`--wait-pid`): the update runs only
    ///     once it has exited, so it cannot restart the gateway mid-update.
    init(
        resolve: (() throws -> URL)? = nil, arguments: [String] = ["update"],
        environment: [String: String]? = nil,
        waitFor: pid_t? = Updater.waitPid(), waitSeconds: Double = Updater.waitSeconds
    ) {
        self.waitFor = waitFor
        self.waitSeconds = waitSeconds
        if let resolve {
            self.resolve = resolve
        } else {
            self.resolve = { try GatewaySupervisor().resolveCommand() }
        }
        self.arguments = arguments
        var env = environment ?? ProcessInfo.processInfo.environment
        if env[GatewaySupervisor.homeEnvironmentVariable] == nil {
            env[GatewaySupervisor.homeEnvironmentVariable] = GatewaySupervisor.defaultStateDir(environment: env).path
        }
        self.environment = env
    }

    /// Run the command to its end; stdout and stderr arrive in `lines` as
    /// they are written. Returns the final state.
    @discardableResult
    func run() async -> State {
        guard state != .running else { return state }
        lines = []
        partial = ""
        let command: URL
        do {
            command = try resolve()
        } catch {
            state = .couldNotStart("\(error)")
            lines.append("\(error)")
            return state
        }
        state = .running
        if let pid = waitFor, Updater.isRunning(pid) {
            lines.append("Waiting for the app to quit…")
            let deadline = Date().addingTimeInterval(waitSeconds)
            while Updater.isRunning(pid) {
                if Date() >= deadline {
                    let why = "The app (pid \(pid)) did not quit within \(Int(waitSeconds)) seconds; not updating."
                    lines.append(why)
                    state = .couldNotStart(why)
                    return state
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        lines.append("$ \(([command.path] + arguments).joined(separator: " "))")

        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Output arrives on the pipe's queue and is handed to the main
        // actor in order; the stream ends at EOF, or a moment after the
        // command exits when something it started still holds the pipe.
        let (chunks, feed) = AsyncStream<Data>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(data)
            }
        }
        let (exited, exit) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            exit.yield(finished.terminationStatus)
            exit.finish()
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            feed.finish()
            state = .couldNotStart("could not run \(command.path): \(error.localizedDescription)")
            lines.append("could not run \(command.path): \(error.localizedDescription)")
            return state
        }
        // The write end is the child's now; closing ours lets the read end
        // see EOF when the child (and anything it started) is done.
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        Task.detached {
            for await _ in exited {}
            try? await Task.sleep(for: .seconds(1))
            reader.readabilityHandler = nil
            feed.finish()
        }
        for await data in chunks {
            take(data)
        }
        process.waitUntilExit()
        let code = process.terminationStatus
        if !partial.isEmpty {
            lines.append(partial)
            partial = ""
        }
        state = code == 0 ? .succeeded : .failed(code)
        if code != 0 { lines.append("The update exited with code \(code).") }
        return state
    }

    private func take(_ data: Data) {
        partial += String(decoding: data, as: UTF8.self)
        while let newline = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<newline]).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            partial = String(partial[partial.index(after: newline)...])
        }
    }
}
