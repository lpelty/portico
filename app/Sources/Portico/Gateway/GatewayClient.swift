import Foundation

/// The app's one WebSocket to the gateway.
///
/// `connect` opens `ws://host:port/v1?token=…`, sends `hello` and returns the
/// gateway's `hello`, refusing one that names another protocol version (the
/// status strip then says so). Every frame after that is decoded in arrival order and
/// delivered through `messages`; the stream finishes when the connection
/// drops, which is how the model learns it must reconnect. Reconnect policy
/// (what to re-open, with which `since`) is not here: it lives in
/// `AppModel.handleHello`, next to the sequence watermarks it depends on.
actor GatewayClient {
    enum ClientError: Error, CustomStringConvertible {
        case notConnected
        case badURL(String)
        case unexpectedFirstFrame(String)
        /// The gateway answered `hello` with an `error` (its message is kept).
        case refused(String)
        /// The gateway's `hello` names another protocol version.
        case protocolMismatch(Int)
        case notText
        case timeout(String)

        var description: String {
            switch self {
            case .notConnected: "not connected to the gateway"
            case .badURL(let s): "cannot build the gateway URL from \(s)"
            case .unexpectedFirstFrame(let t): "the gateway's first frame was \(t), not hello"
            case .refused(let message): "the gateway refused the connection: \(message)"
            case .protocolMismatch(let version): GatewayClient.protocolMismatchText(version)
            case .notText: "the gateway sent a binary frame"
            case .timeout(let what): "timed out waiting for \(what)"
            }
        }
    }

    /// How long `connect` waits for the gateway's `hello`.
    let helloTimeout: Duration

    /// The one line shown for a gateway speaking another protocol version
    /// (PROTOCOL.md, Version: a mismatch is shown, not silently tolerated).
    static func protocolMismatchText(_ version: Int) -> String {
        "the gateway speaks protocol \(version), this app speaks \(protocolVersion)"
    }

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var continuation: AsyncStream<ServerMessage>.Continuation?
    private var currentStream: AsyncStream<ServerMessage>
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(helloTimeout: Duration = .seconds(10)) {
        self.helloTimeout = helloTimeout
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        // Until the first connect there is nothing to deliver.
        let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
        cont.finish()
        currentStream = stream
    }

    /// Frames from the gateway after `hello`, in arrival order. A fresh stream
    /// per connection; it finishes when that connection ends.
    var messages: AsyncStream<ServerMessage> { currentStream }

    var isConnected: Bool { task != nil }

    /// `/v1?token=<token>` on the gateway's base URL (`ws://127.0.0.1:<port>`).
    /// A base that already ends in `/v1` keeps its path.
    static func socketURL(base: URL, token: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        }
        var items = (components.queryItems ?? []).filter { $0.name != "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? base
    }

    /// Open the socket, send `hello`, await the gateway's `hello`.
    /// Any earlier connection is closed first.
    func connect(url: URL, token: String, appVersion: String) async throws -> HelloServer {
        disconnect()
        let socket = session.webSocketTask(with: Self.socketURL(base: url, token: token))
        socket.maximumMessageSize = 64 * 1024 * 1024
        socket.resume()
        task = socket

        do {
            try await sendRaw(.hello(HelloClient(appVersion: appVersion)), on: socket)
            let first = try await withDeadline(helloTimeout, what: "hello") {
                try await Self.receiveOrCancel(socket)
            }
            let message = try decode(first)
            if case .error(let refusal) = message {
                throw ClientError.refused(refusal.message)
            }
            guard case .hello(let hello) = message else {
                throw ClientError.unexpectedFirstFrame(message.type)
            }
            guard hello.protocol == protocolVersion else {
                throw ClientError.protocolMismatch(hello.protocol)
            }
            startReceiving(on: socket)
            return hello
        } catch {
            socket.cancel(with: .protocolError, reason: nil)
            if task === socket { task = nil }
            throw error
        }
    }

    func send(_ message: ClientMessage) async throws {
        guard let socket = task else { throw ClientError.notConnected }
        try await sendRaw(message, on: socket)
    }

    /// Close the socket. The current `messages` stream finishes.
    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - internals

    private func sendRaw(_ message: ClientMessage, on socket: URLSessionWebSocketTask) async throws {
        let data = try encoder.encode(message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func decode(_ frame: URLSessionWebSocketTask.Message) throws -> ServerMessage {
        switch frame {
        case .string(let text):
            return try decoder.decode(ServerMessage.self, from: Data(text.utf8))
        case .data(let data):
            return try decoder.decode(ServerMessage.self, from: data)
        @unknown default:
            throw ClientError.notText
        }
    }

    private func startReceiving(on socket: URLSessionWebSocketTask) {
        let (stream, cont) = AsyncStream<ServerMessage>.makeStream()
        currentStream = stream
        continuation = cont
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                let frame: URLSessionWebSocketTask.Message
                do {
                    frame = try await socket.receive()
                } catch {
                    break
                }
                guard let self else { break }
                await self.deliver(frame, from: socket, to: cont)
            }
            await self?.connectionEnded(socket, cont)
        }
    }

    private func deliver(
        _ frame: URLSessionWebSocketTask.Message, from socket: URLSessionWebSocketTask,
        to cont: AsyncStream<ServerMessage>.Continuation
    ) {
        guard task === socket else { return }
        do {
            cont.yield(try decode(frame))
        } catch {
            // A frame this app cannot read is skipped, not fatal: a newer
            // gateway may send a type this version does not know.
            FileHandle.standardError.write(Data("portico: skipped a frame: \(error)\n".utf8))
        }
    }

    private func connectionEnded(_ socket: URLSessionWebSocketTask, _ cont: AsyncStream<ServerMessage>.Continuation) {
        cont.finish()
        if task === socket {
            task = nil
            continuation = nil
            receiveLoop = nil
        }
    }

    /// `receive()` honours no task cancellation: a gateway that accepts the
    /// socket and never writes would hold it (and any deadline raced
    /// against it) until it closes. Closing the socket when the task is
    /// cancelled makes the receive throw, so the deadline can win.
    private static func receiveOrCancel(_ socket: URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message
    {
        try await withTaskCancellationHandler {
            try await socket.receive()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// `body` or, when `limit` passes first, `ClientError.timeout(what)`.
    /// `body` must honour cancellation for the timer to win.
    private func withDeadline<T: Sendable>(
        _ limit: Duration, what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw ClientError.timeout(what)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
