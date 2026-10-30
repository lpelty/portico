import Foundation

// MARK: - Services (v0.4, W3)

/// One row of the services menu: the app's own Gateway row or one of the
/// deployment's services as the gateway reported it.
struct ServiceRow: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var state: ServiceState
    /// One line under the name: `running · port 54675`, `up · recall and capture`.
    var detail: String
    var canRestart: Bool = false
    /// The app's own row, from the supervisor and the socket.
    var isGateway: Bool = false

    /// The menu's second line (v0.11, item 60), only when it says
    /// something the dot does not: the gateway's port, a check's own
    /// detail ("recall and capture", without the "up"), why it is down.
    /// A bare "up", "running" or "checking" is `nil`: one line.
    var menuDetail: String? {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", "up", "running", "checking"].contains(text) { return nil }
        if state == .up, text.hasPrefix("up · ") { return String(text.dropFirst("up · ".count)) }
        return text
    }

    /// A down row's second line is its error, drawn red.
    var menuDetailIsError: Bool { state == .down }
}

/// What the strip's services control and its menu say (spec §2.4): the
/// rows, down first, and the label with its tone. Pure, so it is tested
/// without a window.
struct ServicesPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case up, down, checking }

    static let gatewayId = "gateway"

    var rows: [ServiceRow]
    var label: String
    var tone: Tone

    /// - Parameters:
    ///   - gateway: the Gateway row.
    ///   - services: the latest `services.status` (already down-first), or
    ///     `nil` before the first one. Only drawn while connected: with the
    ///     gateway away they are what it said before, not what is true.
    init(gateway: ServiceRow, services: [Service]?) {
        let reported = gateway.state == .up ? services : nil
        let others = (reported ?? []).map(Self.row)
        // The Gateway row leads, unless something else is down: a down
        // service floats to the top.
        let downOthers = others.filter { $0.state == .down }
        if gateway.state == .down || downOthers.isEmpty {
            rows = [gateway] + others
        } else {
            rows = downOthers + [gateway] + others.filter { $0.state != .down }
        }
        let down = rows.filter { $0.state == .down }
        switch down.count {
        case 0:
            if gateway.state != .up || reported == nil || rows.contains(where: { $0.state == .checking }) {
                label = "Checking…"
                tone = .checking
            } else {
                label = "All services up"
                tone = .up
            }
        case 1:
            label = "\(Self.shortName(down[0].name)) is down"
            tone = .down
        default:
            label = "\(down.count) services down"
            tone = .down
        }
    }

    /// The strip's compact word.
    static let compactLabel = "Services"

    /// `Memory (recall server)` reads `Memory` in the strip's sentence.
    static func shortName(_ name: String) -> String {
        guard let open = name.range(of: " (") else { return name }
        let short = name[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    /// A reported service as a row: `up · recall and capture`,
    /// `not responding since 9:41 · …` as the gateway wrote it.
    /// A down service's "not responding since 17:28 · reason" with the
    /// gateway's bare clock replaced by the date rule (v0.7 decision 1):
    /// "not responding since today, 5:28 PM · reason". The time comes from
    /// the service's own `since`; anything else is left as the gateway
    /// wrote it.
    static func outageDetail(
        _ detail: String, since: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let prefix = "not responding since "
        guard detail.hasPrefix(prefix), let start = SessionTime.parse(since) else { return detail }
        let rest = detail.dropFirst(prefix.count)
        let tail = rest.range(of: " · ").map { String(rest[$0.lowerBound...]) } ?? ""
        return prefix + SessionTime.full(start, now: now, calendar: calendar, locale: locale) + tail
    }

    static func row(_ service: Service) -> ServiceRow {
        let word: String = switch service.state {
        case .up: "up"
        case .down: "down"
        case .checking: "checking"
        }
        let detail: String
        if let given = service.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            detail = service.state == .up ? "\(word) · \(given)" : outageDetail(given, since: service.since)
        } else {
            detail = word
        }
        return ServiceRow(
            id: service.id, name: service.name, state: service.state, detail: detail,
            canRestart: service.canRestart ?? false)
    }

    /// The Gateway row from what the app knows itself: the supervisor's
    /// view of the process and the socket's state. Connected is up
    /// whoever started it (a settings override has no port of ours).
    static func gatewayRow(_ status: GatewaySupervisor.Status, connection: AppModel.ConnectionState) -> ServiceRow {
        let port: Int? = if case .running(let port) = status { port } else { nil }
        func row(_ state: ServiceState, _ detail: String) -> ServiceRow {
            ServiceRow(id: gatewayId, name: "Gateway", state: state, detail: detail, isGateway: true)
        }
        if connection == .connected {
            return row(.up, port.map { "running · port \($0)" } ?? "running")
        }
        switch status {
        case .starting:
            return row(.checking, "starting")
        case .running:
            if connection == .connecting { return row(.checking, "starting") }
            return row(.down, "not responding")
        case .stopped:
            if connection == .connecting { return row(.checking, "starting") }
            return row(.down, "stopped")
        case .failed(let reason):
            return row(.down, "stopped · \(reason)")
        }
    }
}

extension AppModel {
    /// The strip's services control and menu for the gateway as the
    /// supervisor sees it.
    func servicesPresentation(gateway: GatewaySupervisor.Status) -> ServicesPresentation {
        ServicesPresentation(
            gateway: ServicesPresentation.gatewayRow(gateway, connection: connection),
            services: services)
    }

    func isRestarting(service: String) -> Bool { restartingServices[service] != nil }

    /// Whether a row's Restart can be pressed: connected, and not while
    /// Restart all services runs (v0.8: the gateway would refuse it with
    /// `services.busy`, and holds back the status that would answer it).
    func canRestart(service: String) -> Bool {
        connection == .connected && restartingAll == nil && !isRestarting(service: service)
    }

    /// The gateway's reason a row's last restart failed, until the next try.
    func restartError(service: String) -> String? { restartErrors[service] }

    /// A row's Restart: `service.restart`; the row shows progress until a
    /// `services.status` moves that service, or the gateway's reason when
    /// an `error` carries this request's id.
    func restartService(_ service: String) {
        guard canRestart(service: service) else { return }
        let id = Self.requestId()
        restartingServices[service] = id
        lastRestartIds[service] = id
        restartErrors[service] = nil
        restartBaselines[service] = services?.first { $0.id == service }
        send(.serviceRestart(ServiceRestart(service: service, id: id)))
    }

    /// A `services.status`: the list, and the restarts it answers. A status
    /// is broadcast whenever any service changes, so one about another
    /// service leaves a restart spinning; the restarted service answers
    /// when it goes to `checking` (the command runs) or its state or
    /// detail moves, or when it is gone from the list.
    func applyServicesStatus(_ status: ServicesStatus) {
        services = status.services
        // A fresh status after Restart all services is its answer (v0.8
        // decision 4); `lastRestartAllId` stays for the error that may follow.
        // A status already on its way before the gateway took the request
        // ends the spinner early too: nothing in the frame tells them apart.
        restartingAll = nil
        for service in Array(restartingServices.keys) {
            let now = status.services.first { $0.id == service }
            let before = restartBaselines[service]
            let answered = now.map { $0.state == .checking || $0.state != before?.state || $0.detail != before?.detail } ?? true
            if answered {
                restartingServices[service] = nil
                restartBaselines[service] = nil
            }
        }
    }

    /// After a `chat.list`, while no `services.status` has come on this
    /// connection: wait `servicesFallbackDelay`, then draw the Gateway row
    /// alone rather than "Checking…" for good.
    func awaitServicesStatus() {
        guard services == nil, servicesFallback == nil else { return }
        let delay = servicesFallbackDelay
        servicesFallback = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.servicesFallback = nil
            if self.services == nil { self.services = [] }
        }
    }

    /// Whether a gateway of this version sends `services.status` (v0.4 and
    /// later). Read loosely: the leading numbers of `0.4.0`, `v0.4`,
    /// `0.4.0-dev`; a version that does not read as one is taken as new.
    static func gatewaySendsServices(_ version: String) -> Bool {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let numbers = text.prefix { $0.isNumber || $0 == "." }.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = numbers.first.flatMap({ Int($0) }) else { return true }
        let minor = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 0
        return (major, minor) >= (0, 4)
    }
}

// MARK: - Gateway controls and Restart all services (v0.8 decisions 3, 4)

/// A button on the services menu's Gateway row (v0.8 decision 3, AC1).
enum GatewayControl: Equatable, Sendable {
    case start, stop, restart

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        }
    }
}

extension ServicesPresentation {
    /// The Gateway row's buttons (v0.8 decision 3): Stop while it runs,
    /// Start while it doesn't, and always Restart, last.
    static func gatewayControls(_ gateway: ServiceRow) -> [GatewayControl] {
        [gateway.state == .up ? .stop : .start, .restart]
    }

    /// Whether a Gateway row button can be pressed now: none during a
    /// restart; Start and Restart not while the gateway is starting (as in
    /// Settings).
    static func gatewayControlEnabled(_ control: GatewayControl, gateway: ServiceRow, restarting: Bool) -> Bool {
        if restarting { return false }
        if control == .start || control == .restart { return gateway.state != .checking }
        return true
    }

    /// The menu ends with Restart all services when the deployment has one
    /// restart command (`hello.capabilities` has `services.restart_all`,
    /// v0.8 decision 4).
    static func offersRestartAll(capabilities: [String]?) -> Bool {
        capabilities?.contains(ServicesRestartAll.capability) ?? false
    }

    /// The menu's one restart control, at its foot (v0.11, item 60).
    static let restartAllTitle = "Restart all"

    /// What Restart all does: the deployment's restart command for all its
    /// services when it has one (asks first, v0.8 decision 4); otherwise a
    /// restart of the gateway, the one thing the app restarts itself (asks
    /// while a turn runs, AC1). The rows carry no buttons of their own
    /// (AG3); a row's own Restart, Stop and Start are on its context menu.
    static func restartAllAction(offersRestartAll: Bool) -> GatewayAction {
        offersRestartAll ? .restartAll : .restart
    }
}

/// An action that may ask first (v0.8 decisions 3, 4).
enum GatewayAction: Equatable, Sendable {
    /// The gateway: Stop, Restart (services menu, Settings, the strip).
    case stop, restart
    /// Restart all services: the deployment's one restart command.
    case restartAll
}

/// The window a confirmation shows in: the one whose button asked.
enum ConfirmPlace: Equatable, Sendable {
    case window, settings
}

/// The question asked before a gateway or services action (v0.8 decisions
/// 3, 4): Stop and Restart ask only while a turn runs in some session;
/// Restart all services always asks. Pure, so its words are tested
/// without a window.
struct GatewayConfirmation: Equatable, Sendable {
    var action: GatewayAction
    /// The sessions with a turn running (or a card waiting), ascending.
    var running: [Int]
    var place: ConfirmPlace = .window

    static func needed(_ action: GatewayAction, running: [Int]) -> Bool {
        switch action {
        case .stop, .restart: !running.isEmpty
        case .restartAll: true
        }
    }

    /// `A turn is running in Session 3.`, `Turns are running in Sessions 2
    /// and 3.`; `nil` when none is.
    static func runningSentence(_ running: [Int]) -> String? {
        let numbers = running.map(String.init)
        switch numbers.count {
        case 0: return nil
        case 1: return "A turn is running in Session \(numbers[0])."
        default:
            let list = numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
            return "Turns are running in Sessions \(list)."
        }
    }

    /// `A turn is running in Session 3. Restart anyway?`
    var title: String {
        let running = Self.runningSentence(running)
        switch action {
        case .stop: return [running, "Stop anyway?"].compactMap { $0 }.joined(separator: " ")
        case .restart: return [running, "Restart anyway?"].compactMap { $0 }.joined(separator: " ")
        case .restartAll: return "Restart all services?"
        }
    }

    var body: String {
        switch action {
        case .stop:
            return "Stopping the gateway interrupts every running turn. Start brings it back."
        case .restart:
            return "Restarting the gateway interrupts every running turn. It starts again with the config as it is now."
        case .restartAll:
            let what = "This runs the deployment's restart command for all its services, then checks them again."
            return [Self.runningSentence(running), what].compactMap { $0 }.joined(separator: " ")
        }
    }

    var confirmTitle: String {
        switch action {
        case .stop: "Stop gateway"
        case .restart: "Restart gateway"
        case .restartAll: "Restart all"
        }
    }
}

extension AppModel {
    /// The sessions where a turn is running or a card waits, ascending:
    /// what a gateway stop or restart would interrupt.
    var sessionsWithTurns: [Int] {
        chats.map(\.chat).filter { isBusy(chat: $0) }.sorted()
    }

    /// The menu offers Restart all services (v0.8 decision 4).
    var offersRestartAll: Bool {
        ServicesPresentation.offersRestartAll(capabilities: hello?.capabilities)
    }

    /// A Gateway row, Settings or strip button (v0.8 decisions 3, 4): ask
    /// first when `GatewayConfirmation.needed`, in the window at `place`;
    /// otherwise act now. Returns whether it asked.
    @discardableResult
    func request(_ action: GatewayAction, from place: ConfirmPlace = .window) -> Bool {
        let running = sessionsWithTurns
        guard GatewayConfirmation.needed(action, running: running) else {
            perform(action)
            return false
        }
        confirming = GatewayConfirmation(action: action, running: running, place: place)
        return true
    }

    /// The confirmation's answer: Cancel (`false`) or go ahead.
    func answerConfirmation(_ proceed: Bool) {
        guard let asked = confirming else { return }
        confirming = nil
        if proceed { perform(asked.action) }
    }

    /// The same model actions as Settings › Gateway's buttons.
    private func perform(_ action: GatewayAction) {
        switch action {
        case .stop: Task { await stopGateway() }
        case .restart: Task { await restartGateway() }
        case .restartAll: restartAllServices()
        }
    }

    /// Restart all services: `services.restart_all`; the menu shows
    /// progress until a fresh `services.status`, or the gateway's reason
    /// when an `error` carries this request's id.
    func restartAllServices() {
        guard connection == .connected, offersRestartAll, restartingAll == nil else { return }
        let id = Self.requestId()
        restartingAll = id
        lastRestartAllId = id
        restartAllError = nil
        send(.servicesRestartAll(ServicesRestartAll(id: id)))
    }
}
