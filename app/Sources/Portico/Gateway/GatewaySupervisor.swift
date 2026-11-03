import Darwin
import Foundation

/// Finds, starts, and stops the gateway; reports whether one is running.
///
/// The gateway is a detached process the app discovers and attaches to, not
/// a child that dies with it. `discover` reads the ledger the gateway wrote
/// and believes it only after `GET /v1/health` answers and the token file is
/// readable. `start` spawns the gateway command in its own session (so the
/// app's signals never reach it), reads `PORTICO_READY port=<n>` from its
/// stdout, and reads the token file the gateway rewrote. `stop` is the
/// explicit action: `gateway.stop` through the client.
@MainActor
final class GatewaySupervisor: ObservableObject {
    enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    enum SupervisorError: Error, CustomStringConvertible {
        case commandNotFound([String])
        case spawnFailed(String, Int32)
        case exitedBeforeReady(String?)
        case readyTimeout(Duration)
        case tokenUnreadable(String)
        /// v0.17: the folder `bin/install --home` wrote into Info.plist is gone.
        case homeMissing(String)

        var description: String {
            switch self {
            case .commandNotFound(let tried):
                "no gateway command found; looked at \(tried.joined(separator: ", "))"
            case .spawnFailed(let command, let code):
                "could not start \(command): \(String(cString: strerror(code)))"
            case .exitedBeforeReady(let line):
                "the gateway exited before it was ready" + (line.map { ": \($0)" } ?? "")
            case .readyTimeout(let limit):
                "the gateway did not report ready within \(limit)"
            case .tokenUnreadable(let path):
                "the gateway is up but its token file \(path) cannot be read"
            case .homeMissing(let path):
                "Portico's folder \(path) is missing; reinstall"
            }
        }
    }

    /// What `ledger.json` holds: where the running gateway listens.
    struct Ledger: Decodable, Equatable, Sendable {
        var host: String
        var port: Int
        var pid: Int
        var epoch: String
    }

    nonisolated static let readyPrefix = "PORTICO_READY"
    nonisolated static let commandEnvironmentVariable = "PORTICO_GATEWAY_BIN"
    nonisolated static let homeEnvironmentVariable = "PORTICO_HOME"
    /// The Info.plist key an assembled `.app` carries: the absolute path of
    /// the deployment's `bin/portico-gateway` (written by `bin/install`).
    nonisolated static let infoPlistCommandKey = "PorticoGatewayBin"
    /// v0.17: the Info.plist key `bin/install --home` writes: the absolute
    /// path of Portico's folder (config, token, index, log).
    nonisolated static let infoPlistHomeKey = "PorticoHome"

    /// Portico's folder and where it was found.
    struct Home: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            /// The app's Info.plist (`bin/install --home`): it must already exist.
            case infoPlist
            /// `PORTICO_HOME`, or a folder given to the supervisor: created if missing.
            case environment
            /// `~/.portico`: created if missing.
            case standard
        }

        var url: URL
        var source: Source
    }

    @Published private(set) var status: Status = .stopped

    /// The process this supervisor started in this app run, if any.
    private(set) var pid: pid_t?

    /// How long `start` waits for the ready line.
    var readyTimeout: Duration = .seconds(30)

    /// Portico's folder and where it came from.
    let home: Home
    /// The gateway's state directory (`home.url`).
    var stateDir: URL { home.url }
    private let explicitCommand: URL?
    private var stdoutDrain: Task<Void, Never>?

    /// A token file to read instead of the state directory's (Settings ›
    /// Gateway, for a gateway that keeps its state elsewhere). `nil`: the default.
    var tokenOverride: URL?

    /// - Parameters:
    ///   - stateDir: the gateway's state directory (created if missing); default `resolveHome()`.
    ///   - gatewayCommand: the gateway command; default is resolved by `resolveCommand()`.
    convenience init(stateDir: URL? = nil, gatewayCommand: URL? = nil) {
        self.init(
            home: stateDir.map { Home(url: $0, source: .environment) } ?? Self.resolveHome(),
            gatewayCommand: gatewayCommand)
    }

    init(home: Home, gatewayCommand: URL? = nil) {
        self.home = home
        self.explicitCommand = gatewayCommand
    }

    /// Portico's folder, in order: the Info.plist's `PorticoHome` (written by
    /// `bin/install --home`), `$PORTICO_HOME`, then `~/.portico`.
    nonisolated static func resolveHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Home {
        if let baked = infoDictionary?[infoPlistHomeKey] as? String, !baked.isEmpty {
            return Home(url: folderURL(baked), source: .infoPlist)
        }
        if let home = environment[homeEnvironmentVariable], !home.isEmpty {
            return Home(url: folderURL(home), source: .environment)
        }
        return Home(
            url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portico", isDirectory: true),
            source: .standard)
    }

    private nonisolated static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The environment for what the app starts with its folder (the gateway, the doctor):
    /// `PORTICO_HOME` is the folder and `PORTICO_HOME_SOURCE` says where the app found
    /// it, so a doctor names it and a `portico-gateway` call without `--state` agrees.
    nonisolated static func childEnvironment(home: Home, base: [String: String]) -> [String: String] {
        var environment = base
        environment[homeEnvironmentVariable] = home.url.path
        environment["PORTICO_HOME_SOURCE"] =
            switch home.source {
            case .infoPlist: "Info.plist"
            case .environment: homeEnvironmentVariable
            case .standard: "the default"
            }
        return environment
    }

    /// What the app starts the gateway with: its folder given explicitly, so
    /// the gateway never looks for it on its own.
    nonisolated static func launchArguments(state: URL) -> [String] {
        ["run", "--port", "0", "--state", state.path]
    }

    var ledgerURL: URL { stateDir.appendingPathComponent("ledger.json") }
    var tokenURL: URL { tokenOverride ?? stateDir.appendingPathComponent("token") }
    /// Where a gateway this app started writes its stderr.
    var logURL: URL { stateDir.appendingPathComponent("gateway.log") }

    // MARK: - discover

    /// A running gateway's port and token, or `nil`: the ledger is only a
    /// hint, so it counts only when `/v1/health` answers on that port and the
    /// token file is readable.
    func discover() async -> (port: Int, token: String)? {
        guard let ledger = readLedger() else { return markNotRunning() }
        guard await Self.healthy(host: ledger.host, port: ledger.port) else { return markNotRunning() }
        guard let token = readToken() else { return markNotRunning() }
        status = .running(port: ledger.port)
        return (ledger.port, token)
    }

    private func markNotRunning() -> (port: Int, token: String)? {
        if case .running = status { status = .stopped }
        return nil
    }

    func readLedger() -> Ledger? {
        guard let data = try? Data(contentsOf: ledgerURL) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: data)
    }

    /// The token file's content with surrounding whitespace removed; `nil` when missing or empty.
    func readToken() -> String? {
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// `GET /v1/health` answers 200 with a JSON object carrying `epoch`.
    static func healthy(host: String, port: Int, timeout: TimeInterval = 2) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/v1/health") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["epoch"] is String
        else { return false }
        return true
    }

    // MARK: - start

    /// Where the gateway command is looked for, in order: `$PORTICO_GATEWAY_BIN`,
    /// the app bundle's `PorticoGatewayBin` (an absolute path `bin/install`
    /// writes into the assembled `.app`), `../bin/portico-gateway` next to
    /// the executable, then `bin/portico-gateway` in any ancestor of the
    /// executable (a `swift run` build inside the repo). Nothing is tied to
    /// where the checkout lives.
    static func candidateCommands(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> [URL] {
        var candidates: [URL] = []
        if let explicit = environment[commandEnvironmentVariable], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath))
        }
        if let bundled = infoDictionary?[infoPlistCommandKey] as? String, !bundled.isEmpty {
            candidates.append(URL(fileURLWithPath: (bundled as NSString).expandingTildeInPath))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = executable.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("../bin/portico-gateway").standardizedFileURL)
            var ancestor = dir
            for _ in 0..<8 {
                ancestor = ancestor.deletingLastPathComponent()
                candidates.append(ancestor.appendingPathComponent("bin/portico-gateway"))
                if ancestor.path == "/" { break }
            }
        }
        return candidates
    }

    func resolveCommand() throws -> URL {
        let candidates = explicitCommand.map { [$0] } ?? Self.candidateCommands()
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw SupervisorError.commandNotFound(candidates.map(\.path))
    }

    /// Start a detached gateway on a free port and return its port and token.
    func start() async throws -> (port: Int, token: String) {
        status = .starting
        do {
            let result = try await launch()
            status = .running(port: result.port)
            return result
        } catch {
            status = .failed("\(error)")
            throw error
        }
    }

    private func launch() async throws -> (port: Int, token: String) {
        // The folder bin/install wrote into the app must exist: making a new,
        // empty one would quietly start a gateway with no config.
        var isDirectory: ObjCBool = false
        if home.source == .infoPlist,
            !(FileManager.default.fileExists(atPath: stateDir.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        {
            throw SupervisorError.homeMissing(stateDir.path)
        }
        let command = try resolveCommand()
        try FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SupervisorError.spawnFailed(command.path, errno) }
        let readEnd = fds[0]
        let writeEnd = fds[1]

        let child: pid_t
        do {
            child = try Self.spawnDetached(
                command: command.path, arguments: Self.launchArguments(state: stateDir),
                environment: Self.childEnvironment(home: home, base: ProcessInfo.processInfo.environment),
                stdout: writeEnd, stderrPath: logURL.path)
        } catch {
            close(readEnd)
            close(writeEnd)
            throw error
        }
        close(writeEnd)
        pid = child

        let limit = readyTimeout
        let port: Int
        switch await Self.awaitReadyLine(fd: readEnd, within: limit) {
        case .timeout:
            // The command is up but silent (wedged before it could listen):
            // it is no gateway, so it goes, and the app says why.
            Self.terminate(child)
            _ = Self.reap(child)
            pid = nil
            close(readEnd)
            throw SupervisorError.readyTimeout(limit)
        case .closed:
            // stdout closed before the ready line: the command exited.
            let code = Self.reap(child)
            pid = nil
            close(readEnd)
            throw SupervisorError.exitedBeforeReady(lastLogLine() ?? code.map { "exit code \($0)" })
        case .ready(let found):
            port = found
        }

        // Keep draining stdout so a later write there never SIGPIPEs the gateway.
        let stdout = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        stdoutDrain = Task.detached {
            do { for try await _ in stdout.bytes.lines {} } catch {}
        }

        guard let token = readToken() else {
            throw SupervisorError.tokenUnreadable(tokenURL.path)
        }
        return (port, token)
    }

    /// What reading the command's stdout for the ready line came to.
    enum ReadyOutcome: Equatable, Sendable {
        case ready(port: Int)
        /// stdout closed first: the command exited.
        case closed
        /// The deadline passed with the command still silent.
        case timeout
    }

    /// Read the command's stdout for the ready line on a thread of its own,
    /// with `poll()` so the deadline holds even when the child never writes
    /// and never exits. A blocked `read` (and `FileHandle.bytes.lines`,
    /// which is one) honours no task cancellation, so a deadline raced
    /// against it in a task group could only fire once stdout closed.
    nonisolated static func awaitReadyLine(fd: Int32, within limit: Duration) async -> ReadyOutcome {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: readReadyLine(fd: fd, within: limit))
            }
        }
    }

    /// `awaitReadyLine`'s blocking half: lines before the deadline, until
    /// one carries the port or the pipe closes.
    nonisolated static func readReadyLine(fd: Int32, within limit: Duration) -> ReadyOutcome {
        let deadline = ContinuousClock.now + limit
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .timeout }
            let (seconds, attoseconds) = remaining.components
            let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, max(milliseconds, 1))
            if ready == 0 { continue }  // the loop re-checks the deadline
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if count == 0 { return .closed }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                if let port = readyPort(in: line) { return .ready(port: port) }
            }
        }
    }

    /// The port from `PORTICO_READY port=<n>`, or `nil` for any other line.
    nonisolated static func readyPort(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(readyPrefix) else { return nil }
        for field in trimmed.split(separator: " ").dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "port", let port = Int(pair[1]) { return port }
        }
        return nil
    }

    private func lastLogLine() -> String? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init)
    }

    // MARK: - stop

    /// Ask the gateway to stop through the attached client: it interrupts
    /// every running turn, runs the deployment's stop command and exits.
    func stop(using client: GatewayClient) async {
        try? await client.send(.gatewayStop(GatewayStop()))
        noteStopped()
    }

    /// The gateway has gone (the app asked it to and the socket closed):
    /// forget the process and show `stopped`.
    func noteStopped() {
        stdoutDrain?.cancel()
        stdoutDrain = nil
        pid = nil
        status = .stopped
    }

    // MARK: - doctor

    /// Run the deployment's doctor and return its lines: `bin/doctor`
    /// beside the gateway command when it is there, else the gateway
    /// command's own `doctor`. stdout and stderr in order; when the
    /// checks fail, the exit code is the last line. Never throws: a doctor
    /// that cannot run says so in its one line.
    func runDoctor() async -> [String] {
        let command: URL
        do {
            command = try resolveCommand()
        } catch {
            return ["\(error)"]
        }
        let sibling = command.deletingLastPathComponent().appendingPathComponent("doctor")
        let (executable, arguments): (URL, [String]) =
            FileManager.default.isExecutableFile(atPath: sibling.path) ? (sibling, []) : (command, ["doctor"])
        let env = Self.childEnvironment(home: home, base: ProcessInfo.processInfo.environment)
        return await Task.detached {
            Self.runCapturing(executable, arguments, environment: env)
        }.value
    }

    nonisolated static func runCapturing(_ executable: URL, _ arguments: [String], environment: [String: String]) -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ["could not run \(executable.path): \(error.localizedDescription)"]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if process.terminationStatus != 0 {
            lines.append("doctor exited with code \(process.terminationStatus)")
        }
        return lines
    }

    /// Kill a gateway this supervisor started (its whole session). Tests only;
    /// a person stops the gateway through `stop`.
    func killForTests() {
        if let pid {
            Self.terminate(pid)
            _ = Self.reap(pid)
        }
        stdoutDrain?.cancel()
        stdoutDrain = nil
        pid = nil
        status = .stopped
    }

    // MARK: - process plumbing

    /// `posix_spawn` with `POSIX_SPAWN_SETSID`: the child leads a new session,
    /// so a signal to the app's group never reaches it. stdin is `/dev/null`,
    /// stdout is the given descriptor, stderr appends to `stderrPath`, and
    /// every other descriptor is closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
    private static func spawnDetached(
        command: String, arguments: [String], environment: [String: String], stdout: Int32, stderrPath: String
    ) throws
        -> pid_t
    {
        var attrs: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attrs) == 0 else { throw SupervisorError.spawnFailed(command, errno) }
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(truncatingIfNeeded: POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SupervisorError.spawnFailed(command, errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_addopen(&actions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, command, &actions, &attrs, argv, envp)
        guard rc == 0 else { throw SupervisorError.spawnFailed(command, rc) }
        return child
    }

    /// SIGTERM the child's whole process group (it leads its own session).
    private static func terminate(_ pid: pid_t) {
        kill(-pid, SIGTERM)
    }

    /// Wait briefly for the child; its exit code when it has gone.
    private static func reap(_ pid: pid_t) -> Int32? {
        var state: Int32 = 0
        for _ in 0..<50 {
            let r = waitpid(pid, &state, WNOHANG)
            if r == pid {
                let exited = (state & 0x7f) == 0
                return exited ? (state >> 8) & 0xff : nil
            }
            if r == -1 { return nil }
            usleep(20_000)
        }
        return nil
    }
}
