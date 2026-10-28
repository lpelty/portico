import Foundation
import XCTest

@testable import Portico

/// `GatewayClient` against an in-test WebSocket gateway (`FakeGateway`), the
/// epoch/`since` reconnect policy through `AppModel.handleHello`, and
/// `GatewaySupervisor` discovery and start against fakes on disk.
///
/// Set `PORTICO_GATEWAY_URL` and `PORTICO_GATEWAY_TOKEN` to also run the
/// handshake against a live Python gateway (`testLiveHelloHandshake`).
final class GatewayClientTests: XCTestCase {

    // MARK: - GatewayClient

    func testSocketURLCarriesPathAndToken() {
        let base = URL(string: "ws://127.0.0.1:4321")!
        let url = GatewayClient.socketURL(base: base, token: "s3cret")
        XCTAssertEqual(url.absoluteString, "ws://127.0.0.1:4321/v1?token=s3cret")
        // A base that already names the protocol path is left alone.
        let withPath = GatewayClient.socketURL(base: URL(string: "ws://127.0.0.1:4321/v1")!, token: "t")
        XCTAssertEqual(withPath.absoluteString, "ws://127.0.0.1:4321/v1?token=t")
    }

    func testHelloHandshake() async throws {
        let gateway = FakeGateway(epoch: "epoch-A")
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient()
        let hello = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
        XCTAssertEqual(hello.epoch, "epoch-A")
        XCTAssertEqual(hello.protocol, protocolVersion)

        // The first frame the gateway saw was our hello, with version and protocol.
        let first = try XCTUnwrap(gateway.received.first)
        XCTAssertEqual(first["type"] as? String, "hello")
        XCTAssertEqual(first["app_version"] as? String, "0.1.0-test")
        XCTAssertEqual(first["protocol"] as? Int, protocolVersion)
        XCTAssertNotNil(first["ts"] as? String)

        // The chat.list that follows hello lands on the stream, not in connect's result.
        let stream = await client.messages
        let next = try await withTimeout(seconds: 5) { () async -> ServerMessage? in
            for await message in stream { return message }
            return nil
        }
        guard case .chatList(let list)? = next else {
            return XCTFail("expected chat.list after hello, got \(String(describing: next))")
        }
        XCTAssertEqual(list.chats, [])
        await client.disconnect()
    }

    func testProtocolMismatchIsShownNotTolerated() async throws {
        // A gateway speaking protocol 2: connect refuses it with the line the
        // status strip shows, and no socket is kept.
        let gateway = FakeGateway(protocol: 2)
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient()
        do {
            _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
            XCTFail("a protocol mismatch must not connect")
        } catch {
            XCTAssertEqual("\(error)", "the gateway speaks protocol 2, this app speaks 1")
        }
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        // The reducer refuses it too: no chats are opened, the strip says why.
        await MainActor.run {
            let model = AppModel()
            model.noteOpened(chat: 1)
            var hello = Self.hello(epoch: "epoch-A")
            hello.protocol = 2
            XCTAssertEqual(model.handleHello(hello), [], "no chat.open on a mismatch")
            XCTAssertNil(model.hello)
            XCTAssertEqual(model.connection, .failed("the gateway speaks protocol 2, this app speaks 1"))
        }
    }

    func testHelloDeadlineFiresWhenTheGatewayNeverAnswers() async throws {
        // A gateway that completes the upgrade and then says nothing: connect
        // gives up at the deadline with the line the strip shows, and keeps
        // no socket, rather than parking the attach until the socket closes.
        let gateway = FakeGateway(answersHello: false)
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient(helloTimeout: .seconds(1))
        let began = ContinuousClock.now
        let failure: String? = try await withTimeout(seconds: 8) {
            do {
                _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
                return nil
            } catch {
                return "\(error)"
            }
        }
        let elapsed = ContinuousClock.now - began
        XCTAssertEqual(failure, "timed out waiting for hello")
        XCTAssertLessThan(elapsed, .seconds(5), "the deadline fired late: \(elapsed)")
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        // The app did say hello first; the silence was the gateway's.
        XCTAssertEqual(gateway.received.first?["type"] as? String, "hello")
    }

    func testMessagesStreamDeliversInOrder() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
        let stream = await client.messages

        let count = 50
        for seq in 1...count {
            try gateway.send(.textDelta(TextDelta(chat: 1, turn: 1, text: "d\(seq)", seq: seq, ts: "2026-10-27T12:00:00Z")))
        }

        let collected = try await withTimeout(seconds: 10) { () async -> [Int] in
            var seen: [Int] = []
            for await message in stream {
                if case .textDelta(let delta) = message, let seq = delta.seq {
                    seen.append(seq)
                    if seen.count == count { break }
                }
            }
            return seen
        }
        XCTAssertEqual(collected, Array(1...count), "deltas arrived out of order or were dropped")
        await client.disconnect()
    }

    func testSendEncodesClientMessage() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
        try await client.send(.chatOpen(ChatOpen(chat: 7, since: 41)))

        let frame = await gateway.waitForFrame(type: "chat.open", seconds: 5)
        let open = try XCTUnwrap(frame)
        XCTAssertEqual(open["chat"] as? Int, 7)
        XCTAssertEqual(open["since"] as? Int, 41)
        await client.disconnect()
    }

    func testStreamFinishesWhenGatewayDrops() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }

        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")
        let stream = await client.messages
        gateway.dropConnection()

        // The stream ends (after draining chat.list) instead of hanging forever.
        let ended: Bool = try await withTimeout(seconds: 10) {
            for await _ in stream {}
            return true
        }
        XCTAssertTrue(ended)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testConnectFailsWhenNothingListens() async throws {
        let port = try await freeLoopbackPort()
        let client = GatewayClient()
        do {
            _ = try await client.connect(
                url: URL(string: "ws://127.0.0.1:\(port)")!, token: "tok", appVersion: "0.1.0-test")
            XCTFail("connect should fail when nothing listens")
        } catch {
            // expected
        }
    }

    func testLiveHelloHandshake() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["PORTICO_GATEWAY_URL"], let url = URL(string: raw), let token = env["PORTICO_GATEWAY_TOKEN"] else {
            throw XCTSkip("set PORTICO_GATEWAY_URL and PORTICO_GATEWAY_TOKEN to run against a live gateway")
        }
        let client = GatewayClient()
        let hello = try await client.connect(url: url, token: token, appVersion: "0.1.0-test")
        XCTAssertEqual(hello.protocol, protocolVersion)
        XCTAssertFalse(hello.epoch.isEmpty)
        await client.disconnect()
    }

    // MARK: - Reconnect policy (Review Focus 2)

    @MainActor
    func testEpochChangeTriggersFullHistoryRefetch() {
        let model = AppModel()
        let helloA = Self.hello(epoch: "epoch-A")

        // First attach: nothing open yet, nothing to catch up on.
        XCTAssertEqual(model.handleHello(helloA), [])
        XCTAssertEqual(model.hello?.epoch, "epoch-A")

        // The app opens chat 1 and sees events up to seq 41.
        model.noteOpened(chat: 1)
        model.noteSeq(of: .textDelta(TextDelta(chat: 1, turn: 1, text: "x", seq: 40)))
        model.noteSeq(of: .textDelta(TextDelta(chat: 1, turn: 1, text: "y", seq: 41)))
        XCTAssertEqual(model.lastSeq[1], 41)

        // Same gateway (same epoch) after a socket drop: ask for events since 41.
        let catchUp = model.handleHello(helloA)
        XCTAssertEqual(catchUp.count, 1)
        guard case .chatOpen(let open)? = catchUp.first else { return XCTFail("expected chat.open, got \(catchUp)") }
        XCTAssertEqual(open.chat, 1)
        XCTAssertEqual(open.since, 41)
        XCTAssertEqual(model.lastSeq[1], 41, "a same-epoch reattach keeps the sequence watermark")

        // The gateway restarted (new epoch): the sequence is meaningless, so
        // drop it and open from the beginning; the gateway replays the transcript once.
        let refetch = model.handleHello(Self.hello(epoch: "epoch-B"))
        XCTAssertEqual(refetch.count, 1)
        guard case .chatOpen(let fresh)? = refetch.first else { return XCTFail("expected chat.open, got \(refetch)") }
        XCTAssertEqual(fresh.chat, 1)
        XCTAssertNil(fresh.since, "a new epoch must open without `since`")
        XCTAssertEqual(model.lastSeq, [:], "a new epoch drops every chat's watermark")
        XCTAssertEqual(model.hello?.epoch, "epoch-B")
    }

    @MainActor
    func testNoteSeqIgnoresUnsequencedAndOlderEvents() {
        let model = AppModel()
        model.noteSeq(of: .textDelta(TextDelta(chat: 2, turn: 1, text: "a", seq: 10)))
        model.noteSeq(of: .textDelta(TextDelta(chat: 2, turn: 1, text: "b")))  // replayed transcript: no seq
        model.noteSeq(of: .textDelta(TextDelta(chat: 2, turn: 1, text: "c", seq: 9)))  // a re-sent card-style frame
        XCTAssertEqual(model.lastSeq[2], 10)
        model.noteSeq(of: .chatList(ChatList(chats: [])))  // not chat-scoped
        XCTAssertEqual(model.lastSeq.count, 1)
    }

    // MARK: - GatewaySupervisor

    func testDiscoverReturnsNilWhenLedgerMissing() async throws {
        let dir = try tempStateDir()
        let supervisor = await GatewaySupervisor(stateDir: dir)
        let found = await supervisor.discover()
        XCTAssertNil(found)
        let status = await supervisor.status
        XCTAssertEqual(status, .stopped)
    }

    func testDiscoverReturnsNilWhenLedgerStale() async throws {
        let dir = try tempStateDir()
        let port = try await freeLoopbackPort()
        try writeLedger(dir, port: port, epoch: "gone")
        try "token-of-a-dead-gateway\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)

        let supervisor = await GatewaySupervisor(stateDir: dir)
        let found = await supervisor.discover()
        XCTAssertNil(found, "a ledger pointing at a port nobody answers on is stale")
        let status = await supervisor.status
        XCTAssertEqual(status, .stopped)
    }

    func testDiscoverReturnsNilWhenHealthyButTokenMissing() async throws {
        let dir = try tempStateDir()
        let health = FakeHealthServer()
        try await health.start()
        defer { health.stop() }
        try writeLedger(dir, port: health.port, epoch: "abc")

        let supervisor = await GatewaySupervisor(stateDir: dir)
        let found = await supervisor.discover()
        XCTAssertNil(found, "a live gateway without a readable token cannot be attached to")
    }

    func testDiscoverReturnsPortAndTokenWhenHealthy() async throws {
        let dir = try tempStateDir()
        let health = FakeHealthServer()
        try await health.start()
        defer { health.stop() }
        try writeLedger(dir, port: health.port, epoch: "abc")
        try "live-token\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)

        let supervisor = await GatewaySupervisor(stateDir: dir)
        let discovered = await supervisor.discover()
        let found = try XCTUnwrap(discovered)
        XCTAssertEqual(found.port, health.port)
        XCTAssertEqual(found.token, "live-token", "the token is the file's content without the trailing newline")
        let status = await supervisor.status
        XCTAssertEqual(status, .running(port: health.port))
    }

    func testStartReadsReadyLineAndToken() async throws {
        let dir = try tempStateDir()
        try "fresh-token\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = try fakeGatewayScript(
            in: dir,
            """
            #!/bin/sh
            echo "noise on stderr" >&2
            echo "PORTICO_READY port=45678"
            sleep 30
            """)

        let supervisor = await GatewaySupervisor(stateDir: dir, gatewayCommand: script)
        let started = try await supervisor.start()
        addTeardownBlock { await supervisor.killForTests() }
        XCTAssertEqual(started.port, 45678)
        XCTAssertEqual(started.token, "fresh-token")
        let status = await supervisor.status
        XCTAssertEqual(status, .running(port: 45678))

        // The child runs in its own session so the app's signals never reach it.
        let startedPid = await supervisor.pid
        let pid = try XCTUnwrap(startedPid)
        XCTAssertEqual(getsid(pid), pid, "the gateway must be its own session leader")

        // Its stderr went to the log file in the state directory.
        let log = try String(contentsOf: dir.appendingPathComponent("gateway.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("noise on stderr"))
    }

    func testStartFailsWhenCommandExitsBeforeReady() async throws {
        let dir = try tempStateDir()
        let script = try fakeGatewayScript(
            in: dir,
            """
            #!/bin/sh
            echo "portico-gateway: another gateway is already running" >&2
            exit 1
            """)
        let supervisor = await GatewaySupervisor(stateDir: dir, gatewayCommand: script)
        do {
            _ = try await supervisor.start()
            XCTFail("start should fail when the command exits before the ready line")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("another gateway is already running"),
                "the failure carries the command's last stderr line, got: \(error)")
        }
        let status = await supervisor.status
        guard case .failed(let reason) = status else { return XCTFail("expected .failed, got \(status)") }
        XCTAssertTrue(reason.contains("another gateway is already running"))
    }

    func testStartGivesUpWhenTheReadyLineNeverComes() async throws {
        // A command that comes up but never prints the ready line (wedged
        // before it could listen): start fails at the deadline and the
        // process is gone, rather than the app sitting at `starting` until
        // the command happens to exit.
        let dir = try tempStateDir()
        let script = try fakeGatewayScript(
            in: dir,
            """
            #!/bin/sh
            sleep 120
            """)
        let supervisor = await GatewaySupervisor(stateDir: dir, gatewayCommand: script)
        await MainActor.run { supervisor.readyTimeout = .seconds(1) }
        addTeardownBlock { await supervisor.killForTests() }

        let began = ContinuousClock.now
        let failure: String? = try await withTimeout(seconds: 8) {
            do {
                _ = try await supervisor.start()
                return nil
            } catch {
                return "\(error)"
            }
        }
        let elapsed = ContinuousClock.now - began
        XCTAssertEqual(failure, "the gateway did not report ready within 1.0 seconds")
        XCTAssertLessThan(elapsed, .seconds(5), "the deadline fired late: \(elapsed)")
        let status = await supervisor.status
        XCTAssertEqual(status, .failed("the gateway did not report ready within 1.0 seconds"))
        let pid = await supervisor.pid
        XCTAssertNil(pid, "the silent command was terminated and forgotten")
    }

    func testReadReadyLineStopsAtTheLineTheEndOrTheDeadline() throws {
        // The reader behind `start`: the port from the ready line among noise,
        // `closed` when the writer goes away first, `timeout` when nothing comes.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }
        let text = "starting up\nPORTICO_READY port=4242 epoch=abc\nmore\n"
        _ = text.withCString { write(writeEnd, $0, strlen($0)) }
        XCTAssertEqual(GatewaySupervisor.readReadyLine(fd: readEnd, within: .seconds(2)), .ready(port: 4242))

        _ = "no port here\n".withCString { write(writeEnd, $0, strlen($0)) }
        XCTAssertEqual(GatewaySupervisor.readReadyLine(fd: readEnd, within: .milliseconds(200)), .timeout)

        close(writeEnd)
        XCTAssertEqual(GatewaySupervisor.readReadyLine(fd: readEnd, within: .seconds(2)), .closed)
    }

    func testStartFailsWhenCommandMissing() async throws {
        let dir = try tempStateDir()
        let supervisor = await GatewaySupervisor(stateDir: dir, gatewayCommand: dir.appendingPathComponent("nope"))
        do {
            _ = try await supervisor.start()
            XCTFail("start should fail when the command is missing")
        } catch {
            // expected
        }
        let status = await supervisor.status
        guard case .failed = status else { return XCTFail("expected .failed, got \(status)") }
    }

    func testStopSendsGatewayStop() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }
        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.1.0-test")

        let supervisor = await GatewaySupervisor(stateDir: try tempStateDir())
        await supervisor.stop(using: client)

        let frame = await gateway.waitForFrame(type: "gateway.stop", seconds: 5)
        XCTAssertNotNil(frame)
        let status = await supervisor.status
        XCTAssertEqual(status, .stopped)
    }

    // MARK: - helpers

    private static func hello(epoch: String) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: [], capabilities: [])
    }

    private func tempStateDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portico-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeLedger(_ dir: URL, port: Int, epoch: String) throws {
        let ledger = #"{"host": "127.0.0.1", "port": \#(port), "pid": 1, "epoch": "\#(epoch)"}"#
        try ledger.write(to: dir.appendingPathComponent("ledger.json"), atomically: true, encoding: .utf8)
    }

    private func fakeGatewayScript(in dir: URL, _ body: String) throws -> URL {
        let script = dir.appendingPathComponent("fake-gateway")
        try (body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

/// Run `body` with a deadline; a test that would hang fails instead.
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "timed out after \(seconds)s" }
}
