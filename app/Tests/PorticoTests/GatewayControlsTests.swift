import Foundation
import XCTest

@testable import Portico

/// v0.8 in the model: the services menu's Gateway row controls and their
/// ask-first during a turn (decision 3), and Restart all services when the
/// deployment has one command for it (decision 4's app side). Model-only.
@MainActor
final class GatewayControlsTests: XCTestCase {

    // MARK: - helpers

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func model() throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v08-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    private func hello(restartAll: Bool, epoch: String = "e") -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.8.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["new"],
            capabilities: ["files", "sessions", "context"] + (restartAll ? [ServicesRestartAll.capability] : []),
            presentation: "single", canLog: false)
    }

    private func session(_ chat: Int, _ state: ChatStateWord) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-29T09:00:00Z")
    }

    private func connected(_ model: AppModel, restartAll: Bool = true, sessions: [ChatSummary] = []) {
        model.setConnection(.connected)
        model.apply(.hello(hello(restartAll: restartAll)))
        model.apply(.chatList(ChatList(chats: sessions)))
    }

    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    // MARK: - decision 3: the Gateway row

    func testTheGatewayRowOffersStopWhileRunningStartWhileNotAndAlwaysRestart() {
        let up = ServicesPresentation.gatewayRow(.running(port: 54675), connection: .connected)
        let stopped = ServicesPresentation.gatewayRow(.stopped, connection: .disconnected)
        let starting = ServicesPresentation.gatewayRow(.starting, connection: .connecting)
        let failed = ServicesPresentation.gatewayRow(.failed("exited 1"), connection: .disconnected)
        XCTAssertEqual(ServicesPresentation.gatewayControls(up), [.stop, .restart])
        XCTAssertEqual(ServicesPresentation.gatewayControls(stopped), [.start, .restart])
        XCTAssertEqual(ServicesPresentation.gatewayControls(failed), [.start, .restart])
        XCTAssertEqual(ServicesPresentation.gatewayControls(starting), [.start, .restart])
        XCTAssertEqual([GatewayControl.start, .stop, .restart].map(\.title), ["Start", "Stop", "Restart"])
    }

    func testStartAndRestartWaitWhileStartingAndNothingIsPressableDuringARestart() {
        let starting = ServicesPresentation.gatewayRow(.starting, connection: .connecting)
        let stopped = ServicesPresentation.gatewayRow(.stopped, connection: .disconnected)
        let up = ServicesPresentation.gatewayRow(.running(port: 54675), connection: .connected)
        XCTAssertFalse(ServicesPresentation.gatewayControlEnabled(.start, gateway: starting, restarting: false))
        XCTAssertFalse(ServicesPresentation.gatewayControlEnabled(.restart, gateway: starting, restarting: false),
                       "not while it is still starting, as Start")
        XCTAssertTrue(ServicesPresentation.gatewayControlEnabled(.restart, gateway: stopped, restarting: false))
        XCTAssertTrue(ServicesPresentation.gatewayControlEnabled(.restart, gateway: up, restarting: false))
        XCTAssertTrue(ServicesPresentation.gatewayControlEnabled(.stop, gateway: up, restarting: false))
        XCTAssertTrue(ServicesPresentation.gatewayControlEnabled(.start, gateway: stopped, restarting: false))
        for control in [GatewayControl.start, .stop, .restart] {
            XCTAssertFalse(ServicesPresentation.gatewayControlEnabled(control, gateway: stopped, restarting: true))
        }
    }

    func testStopAndRestartAskOnlyWhileATurnRunsAndRestartAllAlwaysAsks() {
        XCTAssertFalse(GatewayConfirmation.needed(.stop, running: []))
        XCTAssertFalse(GatewayConfirmation.needed(.restart, running: []))
        XCTAssertTrue(GatewayConfirmation.needed(.stop, running: [3]))
        XCTAssertTrue(GatewayConfirmation.needed(.restart, running: [3]))
        XCTAssertTrue(GatewayConfirmation.needed(.restartAll, running: []))
    }

    func testTheConfirmationsWords() {
        XCTAssertNil(GatewayConfirmation.runningSentence([]))
        XCTAssertEqual(GatewayConfirmation(action: .restart, running: [3]).title, "A turn is running in Session 3. Restart anyway?")
        XCTAssertEqual(GatewayConfirmation(action: .stop, running: [3]).title, "A turn is running in Session 3. Stop anyway?")
        XCTAssertEqual(
            GatewayConfirmation(action: .restart, running: [2, 3]).title, "Turns are running in Sessions 2 and 3. Restart anyway?")
        XCTAssertEqual(GatewayConfirmation.runningSentence([2, 3, 5]), "Turns are running in Sessions 2, 3 and 5.")
        XCTAssertEqual(GatewayConfirmation(action: .restart, running: [3]).confirmTitle, "Restart gateway")
        XCTAssertEqual(GatewayConfirmation(action: .stop, running: [3]).confirmTitle, "Stop gateway")

        let all = GatewayConfirmation(action: .restartAll, running: [])
        XCTAssertEqual(all.title, "Restart all services?")
        XCTAssertEqual(all.body, "This runs the deployment's restart command for all its services, then checks them again.")
        XCTAssertEqual(all.confirmTitle, "Restart all")
        XCTAssertTrue(
            GatewayConfirmation(action: .restartAll, running: [4]).body.hasPrefix("A turn is running in Session 4. "),
            "a running turn is said there too")
    }

    func testARunningTurnOrAWaitingCardAsksInTheWindowWhoseButtonWasPressed() throws {
        let (model, sent) = try model()
        connected(model, sessions: [session(2, .waitingOnYou), session(3, .working), session(4, .idle)])
        XCTAssertEqual(model.sessionsWithTurns, [2, 3])

        XCTAssertTrue(model.request(.restart, from: .settings))
        XCTAssertEqual(model.confirming, GatewayConfirmation(action: .restart, running: [2, 3], place: .settings))
        model.answerConfirmation(false)
        XCTAssertNil(model.confirming)
        XCTAssertFalse(sent.types().contains("gateway.stop"), "Cancel does nothing")

        XCTAssertTrue(model.request(.stop))
        XCTAssertEqual(model.confirming?.place, .window)
        model.answerConfirmation(true)
        XCTAssertNil(model.confirming)
        // Stop is the same action as Settings' (`stopGateway`): it runs in a task.
        let deadline = Date().addingTimeInterval(2)
        while !sent.types().contains("gateway.stop"), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(sent.types().contains("gateway.stop"))
    }

    func testWithNoTurnRunningStopActsAtOnce() throws {
        let (model, sent) = try model()
        connected(model, sessions: [session(3, .idle)])
        XCTAssertFalse(model.request(.stop))
        XCTAssertNil(model.confirming)
        let deadline = Date().addingTimeInterval(2)
        while !sent.types().contains("gateway.stop"), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(sent.types().contains("gateway.stop"))
    }

    // MARK: - decision 4: Restart all services

    func testRestartAllEncodesAndDecodesAsAgreed() throws {
        let message = ClientMessage.servicesRestartAll(ServicesRestartAll(id: "r1", ts: "2026-10-29T12:00:00Z"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "services.restart_all")
        XCTAssertEqual(json?["id"] as? String, "r1")
        XCTAssertEqual(json?["ts"] as? String, "2026-10-29T12:00:00Z")
        XCTAssertEqual(json.map { Set($0.keys) }, ["type", "id", "ts"], "no other fields")
        let back = try JSONDecoder().decode(
            ClientMessage.self, from: Data(#"{"type":"services.restart_all","id":"r1","ts":"2026-10-29T12:00:00Z"}"#.utf8))
        XCTAssertEqual(back, message)

        guard case .error(let error) = try decode("""
            {"type":"error","ts":"2026-10-29T12:00:01Z","id":"r1","code":"services.restart_failed","message":"restart exited 1: unit not found"}
            """) else { return XCTFail() }
        XCTAssertEqual(error.code, "services.restart_failed")
        XCTAssertEqual(error.id, "r1")
    }

    func testTheMenuEndsWithRestartAllOnlyWithTheCapability() throws {
        XCTAssertTrue(ServicesPresentation.offersRestartAll(capabilities: ["files", "services.restart_all"]))
        XCTAssertFalse(ServicesPresentation.offersRestartAll(capabilities: ["files", "sessions"]))
        XCTAssertFalse(ServicesPresentation.offersRestartAll(capabilities: nil), "before the first hello")

        let (model, _) = try model()
        XCTAssertFalse(model.offersRestartAll)
        connected(model, restartAll: false)
        XCTAssertFalse(model.offersRestartAll, "unset: the menu is as in v0.7")
        model.apply(.hello(hello(restartAll: true, epoch: "e2")))
        XCTAssertTrue(model.offersRestartAll)
    }

    func testRestartAllAsksSendsSpinsAndAFreshStatusAnswersIt() throws {
        let (model, sent) = try model()
        connected(model)
        XCTAssertTrue(model.request(.restartAll), "asks even with no turn running")
        XCTAssertEqual(model.confirming, GatewayConfirmation(action: .restartAll, running: []))
        XCTAssertTrue(sent.frames.isEmpty)
        model.answerConfirmation(true)
        guard case .servicesRestartAll(let request)? = sent.frames.last else { return XCTFail("\(sent.types())") }
        XCTAssertEqual(model.restartingAll, request.id)

        // One at a time.
        model.restartAllServices()
        XCTAssertEqual(sent.types().filter { $0 == "services.restart_all" }.count, 1)

        model.apply(.servicesStatus(ServicesStatus(services: [Service(id: "memory", name: "Memory", state: .up)])))
        XCTAssertNil(model.restartingAll)
        XCTAssertNil(model.restartAllError)
    }

    func testAFailedRestartAllSaysWhyUntilTheNextTry() throws {
        let (model, sent) = try model()
        connected(model)
        model.restartAllServices()
        guard case .servicesRestartAll(let request)? = sent.frames.last, let id = request.id else { return XCTFail() }

        // Someone else's error leaves it spinning.
        model.apply(.error(ErrorMessage(code: "gateway.error", message: "other", id: "not-ours")))
        XCTAssertEqual(model.restartingAll, id)
        XCTAssertNil(model.restartAllError)

        // The gateway's order: the status read after the attempt, then the error.
        model.apply(.servicesStatus(ServicesStatus(services: [Service(id: "memory", name: "Memory", state: .down)])))
        XCTAssertNil(model.restartingAll, "the status ends the spinner")
        model.apply(.error(ErrorMessage(code: "services.restart_failed", message: "restart exited 1: unit not found", id: id)))
        XCTAssertNil(model.restartingAll)
        XCTAssertEqual(model.restartAllError, "restart exited 1: unit not found")

        // A refusal before anything ran (no status first) says why too.
        model.restartAllServices()
        guard case .servicesRestartAll(let again)? = sent.frames.last, let busyId = again.id else { return XCTFail() }
        model.apply(.error(ErrorMessage(code: "services.busy", message: "already running", id: busyId)))
        XCTAssertNil(model.restartingAll)
        XCTAssertEqual(model.restartAllError, "already running")

        model.restartAllServices()
        XCTAssertNil(model.restartAllError, "cleared on the next try")
        XCTAssertNotNil(model.restartingAll)

        // A new gateway (the restart may have restarted it too) starts clean.
        model.apply(.hello(hello(restartAll: true, epoch: "e2")))
        XCTAssertNil(model.restartingAll)
    }

    // MARK: - a row's View (v0.26.6, PORT-43)

    func testARowShowsViewOnlyForAWebAddress() {
        func row(_ view: String?, state: ServiceState = .up) -> ServiceRow {
            ServicesPresentation.row(Service(id: "memory", name: "Memory", state: state, view: view))
        }
        XCTAssertEqual(row("http://localhost:8080/ui").view, "http://localhost:8080/ui")
        XCTAssertEqual(row("https://status.example.com", state: .stuck).view, "https://status.example.com", "in every state")
        XCTAssertEqual(row("http://localhost:8080", state: .down).view, "http://localhost:8080")
        XCTAssertNil(row(nil).view)
        XCTAssertNil(row("file:///etc/hosts").view)
        XCTAssertNil(row("javascript:alert(1)").view)
        XCTAssertNil(row("localhost:8080").view)
        let gateway = ServicesPresentation.gatewayRow(.running(port: 1), connection: .connected)
        XCTAssertNil(gateway.view, "the Gateway row has no page")
    }

    func testAServiceOlderGatewaysSendDecodesWithNoView() throws {
        let old = try JSONDecoder().decode(Service.self, from: Data(#"{"id":"memory","name":"Memory","state":"up"}"#.utf8))
        XCTAssertNil(old.view)
        let new = try JSONDecoder().decode(
            Service.self, from: Data(#"{"id":"memory","name":"Memory","state":"up","view":"http://localhost:8080"}"#.utf8))
        XCTAssertEqual(new.view, "http://localhost:8080")
    }

    func testViewOpensThatAddressInTheShownChatsViewer() throws {
        let (model, _) = try model()
        connected(model, sessions: [ChatSummary(chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])
        let row = ServicesPresentation.row(Service(id: "memory", name: "Memory", state: .stuck, view: "http://localhost:8080/ui"))
        model.selected = 3
        XCTAssertTrue(model.canViewService)
        XCTAssertTrue(model.viewService(row))
        XCTAssertEqual(model.current[3]?.location, "http://localhost:8080/ui", "that address and no other")
        XCTAssertTrue(model.isViewerShown(for: 3))
        XCTAssertFalse(model.viewService(ServicesPresentation.row(Service(id: "search", name: "Search", state: .up))), "no address, nothing opens")
    }

    /// The agent may look at a service's page and scroll it, never click or type: the page
    /// is found by where it is served from, whichever way this Mac is spelled.
    func testAServicesPageIsFoundByItsOrigin() throws {
        let services = [
            Service(id: "memory", name: "Memory", state: .up, view: "http://localhost:8080/ui"),
            Service(id: "status", name: "Status", state: .up, view: "https://status.example.com"),
            Service(id: "search", name: "Search", state: .up),
        ]
        func found(_ address: String) -> String? {
            ServicesPresentation.service(at: URL(string: address)!, in: services)?.id
        }
        XCTAssertEqual(found("http://localhost:8080/ui"), "memory")
        XCTAssertEqual(found("http://localhost:8080/banks/main/config?tab=2#save"), "memory", "any page of it")
        XCTAssertEqual(found("http://127.0.0.1:8080/"), "memory")
        XCTAssertEqual(found("http://[::1]:8080/"), "memory")
        XCTAssertEqual(found("https://status.example.com:443/x"), "status", "the default port is the same place")
        XCTAssertNil(found("http://localhost:3000/"), "another local server stays the agent's to use")
        XCTAssertNil(found("https://localhost:8080/"), "another scheme is another place")
        XCTAssertNil(found("http://example.com:8080/"))
        XCTAssertTrue(ViewerAgent.canAct(url: URL(string: "http://localhost:8080/ui")!, actHosts: []), "the local rule alone would let it through")
    }

    /// Reviews 20261115-164629-3ce6b9 and 20261115-171702-e92dc6: the refusal the agent's
    /// click and type go through holds when the services list empties under an open page,
    /// through a reconnect, and after the app is quit and launched again.
    func testTheAgentIsRefusedOnAViewedServicesPageWhateverTheListSaysLater() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-view-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        let sessions = [ChatSummary(chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")]
        connected(model, sessions: sessions)
        model.selected = 3
        let page = URL(string: "http://localhost:8080/banks/main")!
        func refusal(_ model: AppModel) -> String? {
            ViewerAgent.refusal(at: page, actHosts: [], servicePage: model.servicePage(at: page)?.name)
        }
        XCTAssertNil(refusal(model), "an ordinary local page is the agent's to use")

        // Listed, before anyone pressed View: already look-only.
        model.apply(.servicesStatus(ServicesStatus(services: [
            Service(id: "memory", name: "Memory", state: .stuck, view: "http://localhost:8080/ui?token=secret"),
        ])))
        XCTAssertEqual(refusal(model), ViewerAgent.Message.servicePage("Memory"))
        XCTAssertTrue(try XCTUnwrap(refusal(model)).contains("looked at and scrolled, not used"))

        // View opens it; then the status read fails and the list holds one failed row.
        XCTAssertTrue(model.viewService(ServicesPresentation.row(try XCTUnwrap(model.services?.first))))
        model.apply(.servicesStatus(ServicesStatus(services: [Service(id: "status", name: "Services", state: .down)])))
        XCTAssertEqual(refusal(model), ViewerAgent.Message.servicePage("Memory"), "the list no longer names it; the page is still the service's")
        // A reconnect: the new gateway's hello empties the list until its first status.
        model.apply(.hello(hello(restartAll: true, epoch: "e2")))
        XCTAssertNil(model.services)
        XCTAssertEqual(refusal(model), ViewerAgent.Message.servicePage("Memory"), "nor after a reconnect")

        // Quit and launched again: a new model on the same settings, the page put back by the
        // viewer's restore (which never goes through View), and no services list yet.
        let relaunched = AppModel(settings: Settings(defaults: defaults))
        relaunched.outbound = { _ in }
        connected(relaunched, sessions: sessions)
        XCTAssertNil(relaunched.services)
        XCTAssertTrue(relaunched.openLink(page.absoluteString, chat: 3))
        XCTAssertEqual(refusal(relaunched), ViewerAgent.Message.servicePage("Memory"), "nor after a restart")
        XCTAssertEqual(Settings(defaults: defaults).viewedServicePages, ["http://localhost:8080": "Memory"], "where it is served from, never its path or query")

        // The other rule is unchanged: an outside site is refused as before, a listed one allowed.
        let outside = URL(string: "https://example.com/")!
        XCTAssertEqual(ViewerAgent.refusal(at: outside, actHosts: [], servicePage: nil), ViewerAgent.Message.outsideSite("example.com"))
        XCTAssertNil(ViewerAgent.refusal(at: outside, actHosts: ["example.com"], servicePage: nil))
    }

    // MARK: - a row's Restart beside Restart all services

    private func withRestartableMemory(_ model: AppModel) {
        model.apply(.servicesStatus(ServicesStatus(services: [
            Service(id: "memory", name: "Memory", state: .down, detail: "not responding since 9:41", canRestart: true),
        ])))
    }

    func testARowRestartWaitsWhileAllServicesRestart() throws {
        let (model, sent) = try model()
        connected(model)
        withRestartableMemory(model)
        XCTAssertTrue(model.canRestart(service: "memory"))
        model.restartAllServices()
        XCTAssertFalse(model.canRestart(service: "memory"), "the row's Restart is disabled meanwhile")
        model.restartService("memory")
        XCTAssertEqual(sent.types().filter { $0 == "service.restart" }, [], "not sent")
        XCTAssertFalse(model.isRestarting(service: "memory"))

        withRestartableMemory(model)  // Restart all's answer
        XCTAssertTrue(model.canRestart(service: "memory"))
        model.restartService("memory")
        XCTAssertEqual(sent.types().filter { $0 == "service.restart" }.count, 1)
    }

    func testAFailedRowRestartSaysWhyUnderTheRowUntilTheNextTry() throws {
        let (model, sent) = try model()
        connected(model)
        withRestartableMemory(model)
        model.restartService("memory")
        guard case .serviceRestart(let request)? = sent.frames.last, let id = request.id else { return XCTFail() }

        // Someone else's error says nothing under the row.
        model.apply(.error(ErrorMessage(code: "gateway.error", message: "other", id: "not-ours")))
        XCTAssertNil(model.restartError(service: "memory"))

        // As for Restart all: the status that answers it, then the error.
        model.apply(.servicesStatus(ServicesStatus(services: [
            Service(id: "memory", name: "Memory", state: .checking, detail: "restarting", canRestart: true),
        ])))
        XCTAssertFalse(model.isRestarting(service: "memory"))
        model.apply(.error(ErrorMessage(code: "gateway.error", message: "service.restart failed: boom", id: id)))
        XCTAssertEqual(model.restartError(service: "memory"), "service.restart failed: boom")

        // A refusal (nothing ran, no status first) says why too.
        model.restartService("memory")
        XCTAssertNil(model.restartError(service: "memory"), "cleared on the next try")
        guard case .serviceRestart(let again)? = sent.frames.last, let busyId = again.id else { return XCTFail() }
        model.apply(.error(ErrorMessage(code: "services.busy", message: "restarting all", id: busyId)))
        XCTAssertFalse(model.isRestarting(service: "memory"))
        XCTAssertEqual(model.restartError(service: "memory"), "restarting all")

        // A new gateway starts clean.
        model.apply(.hello(hello(restartAll: true, epoch: "e2")))
        XCTAssertNil(model.restartError(service: "memory"))
    }

    func testRestartAllIsNotSentWithoutTheCapabilityOrTheSocket() throws {
        let (model, sent) = try model()
        connected(model, restartAll: false)
        model.restartAllServices()
        XCTAssertTrue(sent.frames.isEmpty)

        model.apply(.hello(hello(restartAll: true, epoch: "e2")))
        model.setConnection(.disconnected)
        model.restartAllServices()
        XCTAssertTrue(sent.frames.isEmpty)
    }

    func testAnOutageSaysWhenOnTheDateRuleNotTheGatewaysClock() {
        // The gateway writes "since 17:28" (its own clock, no day); the app
        // rewrites it from the service's `since` (v0.8, v0.7 decision 1).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let now = SessionTime.parse("2026-10-29T19:00:00Z")!
        XCTAssertEqual(
            ServicesPresentation.outageDetail(
                "not responding since 17:28 · connection refused on :8100", since: "2026-10-29T17:28:00Z",
                now: now, calendar: utc, locale: us),
            "not responding since today, 5:28 PM · connection refused on :8100")
        XCTAssertEqual(
            ServicesPresentation.outageDetail(
                "not responding since 23:10", since: "2026-10-28T23:10:00Z", now: now, calendar: utc, locale: us),
            "not responding since yesterday, 11:10 PM")
        XCTAssertEqual(
            ServicesPresentation.outageDetail("permission denied", since: "2026-10-29T17:28:00Z", now: now, calendar: utc, locale: us),
            "permission denied", "only the gateway's outage line is rewritten")
        XCTAssertEqual(
            ServicesPresentation.outageDetail("not responding since 17:28", since: nil, now: now, calendar: utc, locale: us),
            "not responding since 17:28", "no since, no rewrite")
    }

    func testAnotherWindowTakingTheGatewayStopsTheRetriesUntilStart() {
        // Two windows on one gateway used to knock each other off forever:
        // the gateway replaces the older connection, and the older one
        // reconnected within a second (v0.9).
        let model = AppModel()
        XCTAssertFalse(model.replacedElsewhere)
        model.apply(.error(ErrorMessage(code: "session.replaced", message: "another app attached to this gateway")))
        XCTAssertTrue(model.replacedElsewhere)
        XCTAssertEqual(
            AppModel.replacedText(brand: "Portico"), "Another Portico window is using this gateway. Agent › Start brings it back here.")
        model.startGateway()
        XCTAssertFalse(model.replacedElsewhere, "Start takes it back")
    }
}
