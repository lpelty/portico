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

    @Published private(set) var status: Status = .stopped

    /// The process this supervisor started in this app run, if any.
    private(set) var pid: pid_t?

    /// How long `start` waits for the ready line.
    var readyTimeout: Duration = .seconds(30)

    let stateDir: URL
    private let explicitCommand: URL?
    private var stdoutDrain: Task<Void, Never>?

    /// A token file to read instead of the state directory's (Settings ›
    /// Gateway, for a gateway that keeps its state elsewhere). `nil`: the default.
    var tokenOverride: URL?

    /// - Parameters:
    ///   - stateDir: the gateway's state directory; default `$PORTICO_HOME` or `~/.portico`.
    ///   - gatewayCommand: the gateway command; default is resolved by `resolveCommand()`.
    init(stateDir: URL? = nil, gatewayCommand: URL? = nil) {
        self.stateDir = stateDir ?? Self.defaultStateDir()
        self.explicitCommand = gatewayCommand
    }

    static func defaultStateDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment[homeEnvironmentVariable], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portico", isDirectory: true)
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
    /// `../bin/portico-gateway` next to the executable, `bin/portico-gateway`
    /// in any ancestor of the executable (a `swift run` build inside the repo),
    /// then `~/portico/bin/portico-gateway`.
    static func candidateCommands(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var candidates: [URL] = []
        if let explicit = environment[commandEnvironmentVariable], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath))
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
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("portico/bin/portico-gateway"))
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
                command: command.path, arguments: ["run", "--port", "0"],
                stdout: writeEnd, stderrPath: logURL.path)
        } catch {
            close(readEnd)
            close(writeEnd)
            throw error
        }
        close(writeEnd)
        pid = child

        let stdout = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        let limit = readyTimeout
        let port: Int?
        do {
            port = try await Self.withDeadline(limit) {
                for try await line in stdout.bytes.lines {
                    if let port = Self.readyPort(in: line) { return port }
                }
                return nil
            }
        } catch {
            Self.terminate(child)
            pid = nil
            throw SupervisorError.readyTimeout(limit)
        }
        guard let port else {
            // stdout closed before the ready line: the command exited.
            let code = Self.reap(child)
            pid = nil
            throw SupervisorError.exitedBeforeReady(lastLogLine() ?? code.map { "exit code \($0)" })
        }

        // Keep draining stdout so a later write there never SIGPIPEs the gateway.
        stdoutDrain = Task.detached {
            do { for try await _ in stdout.bytes.lines {} } catch {}
        }

        guard let token = readToken() else {
            throw SupervisorError.tokenUnreadable(tokenURL.path)
        }
        return (port, token)
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
        var environment = ProcessInfo.processInfo.environment
        environment[Self.homeEnvironmentVariable] = stateDir.path
        let env = environment
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
    private static func spawnDetached(command: String, arguments: [String], stdout: Int32, stderrPath: String) throws
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
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
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

    private static func withDeadline<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SupervisorError.readyTimeout(limit)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
