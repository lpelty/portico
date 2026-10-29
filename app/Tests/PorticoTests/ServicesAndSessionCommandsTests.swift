import Foundation
import XCTest

@testable import Portico

/// v0.4 in the model: the protocol additions, the services control and
/// menu (decision 4), the strip that never wraps (3), Log session and
/// `/log` (5, 6), and New asking to log first (7). Model-only.
@MainActor
final class ServicesAndSessionCommandsTests: XCTestCase {

    // MARK: - helpers

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func model() throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v04-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    /// A v0.4 gateway: single presentation, sessions, and `log` in the commands when it can log.
    private func hello(canLog: Bool = true, speaksLog: Bool = true) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.4.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: canLog && speaksLog ? ["new", "log"] : ["new"],
            capabilities: ["files", "sessions", "context"], presentation: "single", canLog: canLog)
    }

    private func session(_ chat: Int, unlogged: Bool? = nil, loggedAt: String? = nil) -> ChatSummary {
        ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-28T09:09:00Z",
            loggedAt: loggedAt, unlogged: unlogged)
    }

    private func service(_ id: String, _ name: String, _ state: ServiceState, detail: String? = nil, restart: Bool? = nil) -> Service {
        Service(id: id, name: name, state: state, detail: detail, canRestart: restart)
    }

    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    // MARK: - protocol

    func testV04MessagesDecodeAndEncodeAsTheContractSays() throws {
        guard case .servicesStatus(let status) = try decode("""
            {"type":"services.status","ts":"2026-10-28T12:00:00Z","services":[
              {"id":"memory","name":"Memory (Hindsight)","state":"down","detail":"not responding since 9:41","since":"2026-10-28T09:41:00Z","can_restart":true},
              {"id":"search","name":"Search (Chroma)","state":"up"}]}
            """) else { return XCTFail() }
        XCTAssertEqual(status.services.map(\.id), ["memory", "search"])
        XCTAssertEqual(status.services[0].canRestart, true)
        XCTAssertNil(status.services[1].canRestart, "absent reads as false")

        guard case .sessionLogged(let logged) = try decode("""
            {"type":"session.logged","ts":"2026-10-28T12:00:00Z","id":"r1",
             "chat":{"chat":1,"folder":"/v","alias":null,"state":"idle","created":"2026-10-28T09:09:00Z","logged_at":"2026-10-28T12:00:00Z","unlogged":false}}
            """) else { return XCTFail() }
        XCTAssertEqual(logged.chat.loggedAt, "2026-10-28T12:00:00Z")
        XCTAssertEqual(logged.chat.hasUnloggedWork, false)
        XCTAssertNil(ServerMessage.sessionLogged(logged).envelope.chat, "its chat is a record, not a number")

        let log = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.sessionLog(SessionLog(chat: 3, id: "a")))) as? [String: Any]
        XCTAssertEqual(log?["type"] as? String, "session.log")
        XCTAssertEqual(log?["chat"] as? Int, 3)
        let restart = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ClientMessage.serviceRestart(ServiceRestart(service: "memory", id: "b")))) as? [String: Any]
        XCTAssertEqual(restart?["type"] as? String, "service.restart")
        XCTAssertEqual(restart?["service"] as? String, "memory")
    }

    // MARK: - services

    private let gatewayUp = ServicesPresentation.gatewayRow(.running(port: 54675), connection: .connected)

    func testAllUpOneDownSeveralDown() {
        let allUp = ServicesPresentation(gateway: gatewayUp, services: [
            service("memory", "Memory (Hindsight)", .up, detail: "recall and capture"),
            service("search", "Search (Chroma)", .up, detail: "10 collections"),
        ])
        XCTAssertEqual(allUp.label, "All services up")
        XCTAssertEqual(allUp.tone, .up)
        XCTAssertEqual(allUp.rows.map(\.name), ["Gateway", "Memory (Hindsight)", "Search (Chroma)"])
        XCTAssertEqual(allUp.rows.map(\.detail), ["running · port 54675", "up · recall and capture", "up · 10 collections"])

        let oneDown = ServicesPresentation(gateway: gatewayUp, services: [
            service("memory", "Memory (Hindsight)", .down, detail: "not responding since 9:41 · chat still works", restart: true),
            service("search", "Search (Chroma)", .up),
        ])
        XCTAssertEqual(oneDown.label, "Memory is down")
        XCTAssertEqual(oneDown.tone, .down)
        XCTAssertEqual(oneDown.rows.map(\.id), ["memory", "gateway", "search"], "a down service floats above the Gateway row")
        XCTAssertEqual(oneDown.rows[0].detail, "not responding since 9:41 · chat still works")
        XCTAssertTrue(oneDown.rows[0].canRestart)

        let twoDown = ServicesPresentation(gateway: gatewayUp, services: [
            service("memory", "Memory", .down), service("search", "Search", .down),
        ])
        XCTAssertEqual(twoDown.label, "2 services down")

        XCTAssertEqual(ServicesPresentation(gateway: gatewayUp, services: nil).label, "Checking…", "before the first status")
        XCTAssertEqual(ServicesPresentation(gateway: gatewayUp, services: []).label, "All services up", "no [[services]]: the Gateway alone")
        XCTAssertEqual(
            ServicesPresentation(gateway: gatewayUp, services: [service("m", "Memory", .checking)]).label, "Checking…")
    }

    func testTheGatewayRowComesFromTheApp() {
        XCTAssertEqual(ServicesPresentation.gatewayRow(.running(port: 1), connection: .connected).detail, "running · port 1")
        XCTAssertEqual(ServicesPresentation.gatewayRow(.stopped, connection: .connected).detail, "running", "a gateway the settings point at")
        XCTAssertEqual(ServicesPresentation.gatewayRow(.starting, connection: .connecting).state, .checking)
        XCTAssertEqual(ServicesPresentation.gatewayRow(.starting, connection: .connecting).detail, "starting")
        XCTAssertEqual(ServicesPresentation.gatewayRow(.stopped, connection: .disconnected).detail, "stopped")
        let silent = ServicesPresentation.gatewayRow(.running(port: 1), connection: .failed("refused"))
        XCTAssertEqual(silent.state, .down)
        XCTAssertEqual(silent.detail, "not responding")

        // The gateway down: it leads, the strip counts it, and what the
        // gateway said before is not drawn as if it were current.
        let down = ServicesPresentation(gateway: silent, services: [service("memory", "Memory", .down)])
        XCTAssertEqual(down.rows.map(\.id), ["gateway"])
        XCTAssertEqual(down.label, "Gateway is down")
        XCTAssertEqual(down.tone, .down)
    }

    func testServicesStatusAndRestartThroughTheModel() throws {
        let (model, sent) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "Checking…")
        model.apply(.servicesStatus(ServicesStatus(services: [service("memory", "Memory (Hindsight)", .down, restart: true)])))
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "Memory is down")

        model.restartService("memory")
        guard case .serviceRestart(let restart)? = sent.frames.last else { return XCTFail("\(sent.types())") }
        XCTAssertEqual(restart.service, "memory")
        XCTAssertTrue(model.isRestarting(service: "memory"))
        model.restartService("memory")
        XCTAssertEqual(sent.types().filter { $0 == "service.restart" }.count, 1, "one restart at a time")
        model.apply(.servicesStatus(ServicesStatus(services: [service("memory", "Memory (Hindsight)", .up)])))
        XCTAssertFalse(model.isRestarting(service: "memory"), "the next status answers it")
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "All services up")

        model.restartService("memory")
        guard case .serviceRestart(let again)? = sent.frames.last else { return XCTFail() }
        model.apply(.error(ErrorMessage(code: "service.no_restart", message: "no restart", id: again.id)))
        XCTAssertFalse(model.isRestarting(service: "memory"), "a refusal ends it too")

        // A new hello: checked afresh.
        model.apply(.hello(hello()))
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "Checking…")
    }

    // MARK: - the strip

    func testShortModelNames() {
        XCTAssertEqual(StatusStripPresentation.shortModelName("Claude Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(StatusStripPresentation.shortModelName("Claude Opus 5.5 (work)"), "Opus 5.5 (work)")
        XCTAssertEqual(StatusStripPresentation.shortModelName("gpt-6"), "gpt-6")
        XCTAssertEqual(StatusStripPresentation.shortModelName("GPT 6"), "GPT 6")
    }

    func testTheStripDropsWordsAsItNarrows() {
        let strip = StatusStripPresentation(
            modelText: "Claude Opus 5.5", contextPercent: 2.2,
            services: ServicesPresentation(gateway: gatewayUp, services: []), gatewayText: "")
        XCTAssertEqual(strip.model(at: .full), "Claude Opus 5.5")
        XCTAssertEqual(strip.model(at: .compact), "Opus 5.5")
        XCTAssertNil(strip.model(at: .minimal))
        XCTAssertEqual(strip.context(at: .full), "2% context")
        XCTAssertEqual(strip.context(at: .compact), "2%")
        XCTAssertEqual(strip.servicesLabel(at: .full), "All services up")
        XCTAssertEqual(strip.servicesLabel(at: .compact), "Services")

        // Seven points a character, so the arithmetic is the test's own.
        let measure: (String) -> CGFloat = { CGFloat($0.count * 7) }
        let full = strip.width(at: .full, restart: false, update: "0.3.1", measure: measure)
        let compact = strip.width(at: .compact, restart: false, update: "0.3.1", measure: measure)
        let minimal = strip.width(at: .minimal, restart: false, update: "0.3.1", measure: measure)
        XCTAssertGreaterThan(full, compact)
        XCTAssertGreaterThan(compact, minimal)
        XCTAssertEqual(strip.fit(width: 1200, restart: false, update: "0.3.1", measure: measure), .full)
        XCTAssertEqual(strip.fit(width: full - 1, restart: false, update: "0.3.1", measure: measure), .compact)
        XCTAssertEqual(strip.fit(width: compact - 1, restart: false, update: "0.3.1", measure: measure), .minimal)
        XCTAssertEqual(strip.fit(width: 10, restart: false, update: nil, measure: measure), .minimal, "never wider than minimal")
        XCTAssertGreaterThan(
            strip.width(at: .full, restart: true, update: nil, measure: measure),
            strip.width(at: .full, restart: false, update: nil, measure: measure), "the stale-config button takes room")
    }

    // MARK: - Log session and /log

    func testLogSessionLogsWithoutEnding() throws {
        let (model, sent) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))
        XCTAssertTrue(model.canLogSession(chat: 1))
        model.logSession(chat: 1)
        guard case .sessionLog(let log)? = sent.frames.last else { return XCTFail("\(sent.types())") }
        XCTAssertEqual(log.chat, 1)
        XCTAssertTrue(model.isLogging(chat: 1))
        XCTAssertTrue(model.isSessionCommandPending(chat: 1))
        model.logSession(chat: 1)
        model.requestNew(chat: 1)
        XCTAssertEqual(sent.types().filter { $0.hasPrefix("session.") }, ["session.log"], "one at a time")

        model.apply(.sessionLogged(SessionLogged(chat: session(1, unlogged: false, loggedAt: "2026-10-28T12:00:00Z"), id: log.id)))
        XCTAssertFalse(model.isLogging(chat: 1))
        XCTAssertEqual(model.summary(of: 1)?.loggedAt, "2026-10-28T12:00:00Z")
        XCTAssertNil(model.summary(of: 1)?.ended, "the session goes on")

        // Nothing unlogged now: New starts the next one at once, without a log.
        model.requestNew(chat: 1)
        XCTAssertNil(model.askingToLog)
        guard case .sessionRenew(let renew)? = sent.frames.last else { return XCTFail("\(sent.types())") }
        XCTAssertFalse(renew.log)
    }

    func testARefusedLogIsNoLongerPending() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))
        model.logSession(chat: 1)
        guard case .sessionLog(let log)? = sent.frames.last else { return XCTFail() }
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "A turn is running", chat: 1, id: log.id)))
        XCTAssertFalse(model.isLogging(chat: 1))
        XCTAssertEqual(model.status[1], "A turn is running")
    }

    func testTypedLogAndNew() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))
        model.setDraft("/log", for: 1)
        model.sendMessage(chat: 1, text: " /log ")
        XCTAssertEqual(sent.types().last, "session.log")
        XCTAssertEqual(model.draft(for: 1), "")
        guard case .sessionLog(let log)? = sent.frames.last else { return XCTFail() }
        model.apply(.sessionLogged(SessionLogged(chat: session(1, unlogged: true), id: log.id)))

        // /new with unlogged work asks instead of renewing.
        model.sendMessage(chat: 1, text: "/new")
        XCTAssertEqual(model.askingToLog, 1)
        XCTAssertFalse(sent.types().contains("session.renew"), "nothing renewed yet")

        // Without a log step, /log is just text.
        let (plain, plainSent) = try self.model()
        plain.apply(.hello(hello(canLog: false)))
        plain.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertFalse(plain.canLogSession(chat: 1))
        plain.sendMessage(chat: 1, text: "/log")
        XCTAssertEqual(plainSent.types().last, "message.send")
    }

    // MARK: - New asks to log first (W2)

    func testNewAsksOnlyWhenItWouldLoseSomething() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))

        model.requestNew(chat: 1)
        XCTAssertEqual(model.askingToLog, 1)
        XCTAssertFalse(sent.types().contains("session.renew"))
        XCTAssertEqual(AskToLogDialog.title(chat: 1), "Log Session 1 before starting a new one?")

        // Cancel: nothing happens.
        model.answerAskToLog(log: nil)
        XCTAssertNil(model.askingToLog)
        XCTAssertFalse(sent.types().contains("session.renew"))

        // Start without logging.
        model.requestNew(chat: 1)
        model.answerAskToLog(log: false)
        guard case .sessionRenew(let skip)? = sent.frames.last else { return XCTFail() }
        XCTAssertFalse(skip.log)
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "busy", chat: 1, id: skip.id)))

        // Log and start new.
        model.requestNew(chat: 1)
        model.answerAskToLog(log: true)
        guard case .sessionRenew(let both)? = sent.frames.last else { return XCTFail() }
        XCTAssertTrue(both.log)
    }

    func testNewWithoutALogStepOrOnAnOlderGateway() throws {
        // No log step: New renews at once, no log.
        let (plain, plainSent) = try model()
        plain.apply(.hello(hello(canLog: false)))
        plain.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))
        plain.requestNew(chat: 1)
        XCTAssertNil(plain.askingToLog)
        guard case .sessionRenew(let renew)? = plainSent.frames.last else { return XCTFail() }
        XCTAssertFalse(renew.log)

        // A v0.3 gateway (can log, no session.log): New logs on renewal as before, and offers no Log session.
        let (old, oldSent) = try model()
        old.apply(.hello(hello(canLog: true, speaksLog: false)))
        old.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertFalse(old.canLogSession(chat: 1))
        old.requestNew(chat: 1)
        XCTAssertNil(old.askingToLog)
        guard case .sessionRenew(let oldRenew)? = oldSent.frames.last else { return XCTFail() }
        XCTAssertTrue(oldRenew.log)
    }
}
