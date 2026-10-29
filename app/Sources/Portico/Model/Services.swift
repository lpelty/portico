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
}

/// What the strip's services control and its menu say (spec §2.4): the
/// rows, down first, and the label with its tone. Pure, so it is tested
/// without a window.
struct ServicesPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case up, down, checking }

    static let gatewayId = "gateway"
    static let footer = "The gateway reports these. The deployment lists its own services."

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

    /// `Memory (Hindsight)` reads `Memory` in the strip's sentence.
    static func shortName(_ name: String) -> String {
        guard let open = name.range(of: " (") else { return name }
        let short = name[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    /// A reported service as a row: `up · recall and capture`,
    /// `not responding since 9:41 · …` as the gateway wrote it.
    static func row(_ service: Service) -> ServiceRow {
        let word: String = switch service.state {
        case .up: "up"
        case .down: "down"
        case .checking: "checking"
        }
        let detail: String
        if let given = service.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            detail = service.state == .up ? "\(word) · \(given)" : given
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

    /// A row's Restart: `service.restart`; the row shows progress until a
    /// `services.status` moves that service.
    func restartService(_ service: String) {
        guard connection == .connected, !isRestarting(service: service) else { return }
        let id = Self.requestId()
        restartingServices[service] = id
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
