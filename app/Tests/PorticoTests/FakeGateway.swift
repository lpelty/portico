import Foundation
import Network

@testable import Portico

/// A tiny in-test WebSocket gateway on `NWListener`.
///
/// It speaks just enough of the protocol for the client tests: it waits for
/// the app's `hello`, answers `hello` (with the configured `epoch`) and an
/// empty `chat.list`, records every frame it receives, and lets a test push
/// any `ServerMessage` to the attached app. One connection at a time, which
/// is what the real gateway allows too.
final class FakeGateway: @unchecked Sendable {
    let epoch: String
    /// The protocol version the fake's `hello` claims; a test sets another to
    /// stand in for a newer gateway.
    let protocolVersionSent: Int
    /// Whether the fake answers the app's `hello` at all; `false` stands in
    /// for a gateway that accepts the socket and then says nothing.
    let answersHello: Bool
    /// Stands in for a gateway older than v0.10, strict about fields: a
    /// `hello` that carries `capabilities` is refused (`protocol.invalid`)
    /// and the socket closed.
    let refusesCapabilities: Bool
    private let queue = DispatchQueue(label: "fake-gateway")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var _received: [[String: Any]] = []
    private var _port: UInt16 = 0

    init(
        epoch: String = "epoch-1", protocol protocolVersionSent: Int = protocolVersion, answersHello: Bool = true,
        refusesCapabilities: Bool = false
    ) {
        self.epoch = epoch
        self.protocolVersionSent = protocolVersionSent
        self.answersHello = answersHello
        self.refusesCapabilities = refusesCapabilities
    }

    /// Every frame received so far, decoded as JSON objects, oldest first.
    var received: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(_port)
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)")! }

    /// Poll for the first received frame of `type`, up to `seconds`.
    func waitForFrame(type: String, seconds: Double) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let frame = received.first(where: { $0["type"] as? String == type }) { return frame }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Bind a free loopback port and start listening. Returns once the port is known.
    func start() async throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port, let self {
                        self.lock.lock()
                        self._port = port.rawValue
                        self.lock.unlock()
                    }
                    if resumed.take() { cont.resume() }
                case .failed(let error):
                    if resumed.take() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    /// Push a message to the attached app.
    func send(_ message: ServerMessage) throws {
        let data = try JSONEncoder().encode(message)
        queue.sync { sendRaw(data) }
    }

    /// Close the app's connection from the server side (the gateway went away).
    func dropConnection() {
        queue.sync {
            connection?.cancel()
            connection = nil
        }
    }

    // MARK: - connection handling (on `queue`)

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: queue)
        receiveNext(conn)
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.lock.lock()
                self._received.append(obj)
                self.lock.unlock()
                if obj["type"] as? String == "hello", self.refusesCapabilities, obj["capabilities"] != nil {
                    self.refuseHello(conn)
                    return
                }
                if obj["type"] as? String == "hello", self.answersHello {
                    self.replyHello()
                }
            }
            self.receiveNext(conn)
        }
    }

    private func refuseHello(_ conn: NWConnection) {
        let error = ErrorMessage(code: "protocol.invalid", message: "unknown field capabilities", ts: "2026-10-27T12:00:00Z")
        if let data = try? JSONEncoder().encode(ServerMessage.error(error)) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func replyHello() {
        let hello = HelloServer(
            protocol: protocolVersionSent,
            gatewayVersion: "0.0-fake",
            epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"),
            actions: [],
            roots: [],
            commands: [],
            capabilities: [],
            ts: "2026-10-27T12:00:00Z")
        let list = ChatList(chats: [], ts: "2026-10-27T12:00:00Z")
        for message in [ServerMessage.hello(hello), .chatList(list)] {
            if let data = try? JSONEncoder().encode(message) {
                sendRaw(data)
            }
        }
    }

    private func sendRaw(_ data: Data) {
        guard let conn = connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

/// A one-shot plain-HTTP server answering every request with one JSON body,
/// standing in for the gateway's `GET /v1/health`.
final class FakeHealthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-health")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _port: UInt16 = 0
    let body: String
    let status: String

    init(body: String = #"{"epoch":"abc","protocol":1}"#, status: String = "200 OK") {
        self.body = body
        self.status = status
    }

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(_port)
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, _ in
                guard let self else { return }
                let payload = Data(self.body.utf8)
                let head = "HTTP/1.1 \(self.status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port, let self {
                        self.lock.lock()
                        self._port = port.rawValue
                        self.lock.unlock()
                    }
                    if resumed.take() { cont.resume() }
                case .failed(let error):
                    if resumed.take() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections = []
            listener?.cancel()
            listener = nil
        }
    }
}

/// A loopback port nothing is listening on: bind one, read it, release it.
func freeLoopbackPort() async throws -> Int {
    let server = FakeHealthServer()
    try await server.start()
    let port = server.port
    server.stop()
    // Give the kernel a moment to release the listener before the caller probes it.
    try await Task.sleep(for: .milliseconds(50))
    return port
}

/// Resume-once guard for continuations driven by repeated state callbacks.
final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
