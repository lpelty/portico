import Foundation
import Network

/// v0.26 (PORT-23): a tiny HTTP/1.1 server on 127.0.0.1 for the ElevenLabs
/// tests, so nothing calls the real API. It records each request and answers
/// from a per-path table; `Connection: close` after every reply.
final class StubHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Wait this long before answering.
        var delay: TimeInterval = 0

        static func json(_ status: Int, _ text: String) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }
        static func audio(_ bytes: Int = 3) -> Response {
            Response(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Data(repeating: 0x49, count: bytes))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tests.stub-http")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var routes: [String: [Response]] = [:]
    private(set) var port: UInt16 = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var requests: [Request] { lock.withLock { _requests } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    /// Answer `path` with `responses` in turn (the last one repeats).
    func route(_ path: String, _ responses: Response...) {
        lock.withLock { routes[path] = responses }
    }

    private func response(for path: String) -> Response {
        lock.withLock {
            guard var list = routes[path], !list.isEmpty else { return .json(404, #"{"detail":"no route"}"#) }
            let first = list.removeFirst()
            if !list.isEmpty { routes[path] = list }
            return first
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self._requests.append(request) }
                let reply = self.response(for: request.path)
                self.queue.asyncAfter(deadline: .now() + reply.delay) {
                    connection.send(content: Self.serialise(reply), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            } else if done || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// A whole request (headers and `Content-Length` of body), or nil while more is to come.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let target = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(
            method: String(first[0]), path: target?.path ?? String(first[1]), query: query, headers: headers,
            body: Data(body.prefix(length)))
    }

    private static func serialise(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) Stub\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }
}
