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
    private func hello(canLog: Bool = true, speaksLog: Bool = true, version: String = "0.4.0", epoch: String = "e") -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: version, epoch: epoch,
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
              {"id":"memory","name":"Memory (recall server)","state":"down","detail":"not responding since 9:41","since":"2026-10-28T09:41:00Z","can_restart":true},
              {"id":"search","name":"Search (index)","state":"up"}]}
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
            service("memory", "Memory (recall server)", .up, detail: "recall and capture"),
            service("search", "Search (index)", .up, detail: "10 collections"),
        ])
        XCTAssertEqual(allUp.label, "All services up")
        XCTAssertEqual(allUp.tone, .up)
        XCTAssertEqual(allUp.rows.map(\.name), ["Gateway", "Memory (recall server)", "Search (index)"])
        XCTAssertEqual(allUp.rows.map(\.detail), ["running · port 54675", "up · recall and capture", "up · 10 collections"])

        let oneDown = ServicesPresentation(gateway: gatewayUp, services: [
            service("memory", "Memory (recall server)", .down, detail: "not responding since 9:41 · chat still works", restart: true),
            service("search", "Search (index)", .up),
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
        model.apply(.servicesStatus(ServicesStatus(services: [service("memory", "Memory (recall server)", .down, restart: true)])))
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "Memory is down")

        model.restartService("memory")
        guard case .serviceRestart(let restart)? = sent.frames.last else { return XCTFail("\(sent.types())") }
        XCTAssertEqual(restart.service, "memory")
        XCTAssertTrue(model.isRestarting(service: "memory"))
        model.restartService("memory")
        XCTAssertEqual(sent.types().filter { $0 == "service.restart" }.count, 1, "one restart at a time")
        model.apply(.servicesStatus(ServicesStatus(services: [service("memory", "Memory (recall server)", .up)])))
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

    func testARestartIsAnsweredOnlyByAStatusThatMovesItsService() throws {
        let (model, _) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.servicesStatus(ServicesStatus(services: [
            service("memory", "Memory", .down, detail: "not responding since 9:41", restart: true),
            service("search", "Search", .down, detail: "not responding since 9:40", restart: true),
        ])))
        model.restartService("memory")
        model.restartService("search")

        // A broadcast about another service (or nothing new) leaves both spinning.
        model.apply(.servicesStatus(ServicesStatus(services: [
            service("memory", "Memory", .down, detail: "not responding since 9:41", restart: true),
            service("search", "Search", .down, detail: "not responding since 9:40", restart: true),
            service("web", "Web", .up),
        ])))
        XCTAssertTrue(model.isRestarting(service: "memory"))
        XCTAssertTrue(model.isRestarting(service: "search"))

        // Memory's restart runs (checking): memory stops spinning, search does not.
        model.apply(.servicesStatus(ServicesStatus(services: [
            service("memory", "Memory", .checking, detail: "restarting", restart: true),
            service("search", "Search", .down, detail: "not responding since 9:40", restart: true),
        ])))
        XCTAssertFalse(model.isRestarting(service: "memory"))
        XCTAssertTrue(model.isRestarting(service: "search"))

        // Search's detail changes (still down): that answers it.
        model.apply(.servicesStatus(ServicesStatus(services: [
            service("memory", "Memory", .up, restart: true),
            service("search", "Search", .down, detail: "not responding since 9:40 · port in use", restart: true),
        ])))
        XCTAssertFalse(model.isRestarting(service: "search"))
    }

    func testAGatewayOlderThanV04HasNoServicesToWaitFor() throws {
        XCTAssertTrue(AppModel.gatewaySendsServices("0.4.0"))
        XCTAssertTrue(AppModel.gatewaySendsServices("0.4"))
        XCTAssertTrue(AppModel.gatewaySendsServices("v0.4.1-dev"))
        XCTAssertTrue(AppModel.gatewaySendsServices("0.10.0"))
        XCTAssertTrue(AppModel.gatewaySendsServices("1.0.0"))
        XCTAssertFalse(AppModel.gatewaySendsServices("0.3.9"))
        XCTAssertFalse(AppModel.gatewaySendsServices("0.3.0+local"))
        XCTAssertFalse(AppModel.gatewaySendsServices("0.1"))
        XCTAssertTrue(AppModel.gatewaySendsServices(""), "unknown: assume new")
        XCTAssertTrue(AppModel.gatewaySendsServices("dev"), "unparseable: assume new")

        let (model, _) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello(version: "0.3.2")))
        XCTAssertEqual(model.services, [])
        XCTAssertEqual(model.servicesPresentation(gateway: .running(port: 2)).label, "All services up", "the Gateway row alone")
        model.apply(.hello(hello(version: "0.4.0")))
        XCTAssertNil(model.services, "a v0.4 gateway: Checking… until it says")
    }

    func testNoServicesStatusAfterTheChatListMeansNoServices() async throws {
        let (model, _) = try model()
        model.servicesFallbackDelay = .milliseconds(50)
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertNil(model.services)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.services, [], "the wait gave up: the Gateway row alone")

        // A status that does come cancels the wait.
        let (prompt, _) = try self.model()
        prompt.servicesFallbackDelay = .milliseconds(50)
        prompt.apply(.hello(hello()))
        prompt.apply(.chatList(ChatList(chats: [session(1)])))
        prompt.apply(.servicesStatus(ServicesStatus(services: [service("memory", "Memory", .checking)])))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(prompt.services?.map(\.id), ["memory"])
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

        // Seven points a character (eight with monospaced digits), a
        // symbol two wider than its size: the arithmetic is the test's own.
        let metrics = Self.metrics
        let full = strip.width(at: .full, restart: false, update: "0.3.1", metrics: metrics)
        let compact = strip.width(at: .compact, restart: false, update: "0.3.1", metrics: metrics)
        let minimal = strip.width(at: .minimal, restart: false, update: "0.3.1", metrics: metrics)
        XCTAssertGreaterThan(full, compact)
        XCTAssertGreaterThan(compact, minimal)
        XCTAssertEqual(strip.fit(width: 1200, restart: false, update: "0.3.1", metrics: metrics), .full)
        XCTAssertEqual(strip.fit(width: full - 1, restart: false, update: "0.3.1", metrics: metrics), .compact)
        XCTAssertEqual(strip.fit(width: compact - 1, restart: false, update: "0.3.1", metrics: metrics), .minimal)
        XCTAssertEqual(strip.fit(width: 10, restart: false, update: nil, metrics: metrics), .minimal, "never wider than minimal")
        XCTAssertGreaterThan(
            strip.width(at: .full, restart: true, update: nil, metrics: metrics),
            strip.width(at: .full, restart: false, update: nil, metrics: metrics), "the stale-config button takes room")
    }

    static let metrics = StatusStripPresentation.Metrics(
        text: { CGFloat($0.count * 7) }, digits: { CGFloat($0.count * 8) }, symbol: { $0.size + 2 })

    func testTheStripFitsAtItsBoundary() {
        let strip = StatusStripPresentation(
            modelText: "Claude Opus 5.5", contextPercent: 62,
            services: ServicesPresentation(gateway: gatewayUp, services: []), gatewayText: "")
        let metrics = Self.metrics
        let full = strip.width(at: .full, restart: true, update: "0.4.1", metrics: metrics)
        // Every piece counted: padding, icons at their own sizes and gaps,
        // the context in digit widths, the services chrome, the slack.
        let M = StatusStripPresentation.Measure.self
        let expected = 2 * M.sidePadding
            + (13 + M.iconGap + 15 * 7)  // cpu · Claude Opus 5.5
            + (13 + M.iconGap + 11 * 8)  // gauge · 62% context, monospaced digits
            + (M.servicesChrome + 15 * 7 + 10)  // All services up ⌄
            + (12 + M.iconGap + CGFloat(StatusStripPresentation.restartText.count * 7))
            + (13 + M.iconGap + CGFloat(StatusStripPresentation.updateText("0.4.1").count * 7))
            + 5 * M.spacing + M.slack
        XCTAssertEqual(full, expected)
        XCTAssertEqual(strip.fit(width: full, restart: true, update: "0.4.1", metrics: metrics), .full, "exactly enough fits")
        XCTAssertEqual(strip.fit(width: full - 0.5, restart: true, update: "0.4.1", metrics: metrics), .compact)
        let compact = strip.width(at: .compact, restart: true, update: "0.4.1", metrics: metrics)
        XCTAssertEqual(strip.fit(width: compact, restart: true, update: "0.4.1", metrics: metrics), .compact)
        XCTAssertEqual(strip.fit(width: compact - 0.5, restart: true, update: "0.4.1", metrics: metrics), .minimal)
        // Not measured yet (the first frame): the full strip, not a flash of minimal.
        XCTAssertEqual(strip.fit(width: nil, restart: true, update: "0.4.1", metrics: metrics), .full)
        // The context is measured as drawn, in digit widths.
        let wideDigits = StatusStripPresentation.Metrics(
            text: metrics.text, digits: { CGFloat($0.count * 9) }, symbol: metrics.symbol)
        XCTAssertGreaterThan(strip.width(at: .full, restart: false, update: nil, metrics: wideDigits),
            strip.width(at: .full, restart: false, update: nil, metrics: metrics))
        XCTAssertGreaterThan(StatusStripPresentation.symbolWidth(M.modelIcon), 0)
        XCTAssertGreaterThan(StatusStripPresentation.digitWidth("62% context"), 0)
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

        // Without a log step (v0.5, X2), /log is not sent: a notice says why.
        let (plain, plainSent) = try self.model()
        plain.apply(.hello(hello(canLog: false)))
        plain.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertFalse(plain.canLogSession(chat: 1))
        plain.setDraft("/log", for: 1)
        plain.sendMessage(chat: 1, text: "/log")
        XCTAssertFalse(plainSent.types().contains("message.send"))
        XCTAssertFalse(plainSent.types().contains("session.log"))
        XCTAssertEqual(plain.draft(for: 1), "")
        guard case .notice(_, let text)? = plain.transcripts[1]?.last else { return XCTFail("no notice") }
        XCTAssertEqual(text, "No log step is set up for this agent, so Log session is off.")
    }

    func testLogSessionOffReason() throws {
        let (model, _) = try self.model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertNil(model.logSessionOffReason(chat: 1), "it can log")

        let (plain, _) = try self.model()
        plain.apply(.hello(hello(canLog: false)))
        plain.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertEqual(plain.logSessionOffReason(chat: 1), AppModel.noLogStep)

        // A v0.3 gateway: a log step, but no `log` command.
        let (old, oldSent) = try self.model()
        old.apply(.hello(hello(canLog: true, speaksLog: false)))
        old.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertEqual(old.logSessionOffReason(chat: 1), "This gateway logs only when starting new.")
        old.sendMessage(chat: 1, text: "/log")
        XCTAssertFalse(oldSent.types().contains { $0 == "message.send" || $0.hasPrefix("session.") }, "\(oldSent.types())")
        guard case .notice(_, let text)? = old.transcripts[1]?.last else { return XCTFail("no notice") }
        XCTAssertEqual(text, AppModel.logsOnlyOnRenewal)

        // An ended session has no card and nothing to log: no reason.
        let (ended, _) = try self.model()
        ended.apply(.hello(hello(canLog: false)))
        var done = session(1)
        done.ended = "2026-10-28T10:00:00Z"
        ended.apply(.chatList(ChatList(chats: [done])))
        XCTAssertNil(ended.logSessionOffReason(chat: 1))
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

    // MARK: - review fixes: unlogged on chat.state, pending commands on a new hello

    func testAChatStateCarriesUnloggedAndNewAsks() throws {
        let (model, sent) = try model()
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: false)])))

        guard case .chatState(let state) = try decode("""
            {"type":"chat.state","ts":"2026-10-28T12:00:00Z","chat":1,"state":"idle","seq":4,"unlogged":true}
            """) else { return XCTFail() }
        XCTAssertEqual(state.unlogged, true)
        model.apply(.chatState(state))
        XCTAssertEqual(model.summary(of: 1)?.hasUnloggedWork, true)

        model.requestNew(chat: 1)
        XCTAssertEqual(model.askingToLog, 1, "an ordinary turn left work unlogged: New asks")
        XCTAssertFalse(sent.types().contains("session.renew"))

        // A chat.state without the field (an older gateway) leaves the record alone.
        model.answerAskToLog(log: nil)
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 5)))
        XCTAssertEqual(model.summary(of: 1)?.hasUnloggedWork, true)
        model.apply(.chatState(ChatState(chat: 1, state: .idle, unlogged: false, seq: 6)))
        XCTAssertEqual(model.summary(of: 1)?.hasUnloggedWork, false)
    }

    func testANewHelloClearsAPendingLogOrRenewal() throws {
        let (model, sent) = try model()
        model.setConnection(.connected)
        model.apply(.hello(hello()))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true), session(2, unlogged: true)])))
        model.logSession(chat: 1)
        model.renew(chat: 2, log: false)
        XCTAssertTrue(model.isLogging(chat: 1))
        XCTAssertNotNil(model.renewing[2])

        // The connection dropped and a restarted gateway (new epoch) said hello.
        model.apply(.hello(hello(epoch: "e2")))
        XCTAssertFalse(model.isLogging(chat: 1), "not \"Logging…\" for good")
        XCTAssertNil(model.renewing[2])
        XCTAssertFalse(model.isSessionCommandPending(chat: 1))

        // The same gateway again: likewise; the session can be logged anew.
        model.logSession(chat: 1)
        model.apply(.hello(hello(epoch: "e2")))
        XCTAssertFalse(model.isLogging(chat: 1))
        model.apply(.chatList(ChatList(chats: [session(1, unlogged: true)])))
        model.logSession(chat: 1)
        XCTAssertEqual(sent.types().filter { $0 == "session.log" }.count, 3)
    }
}
