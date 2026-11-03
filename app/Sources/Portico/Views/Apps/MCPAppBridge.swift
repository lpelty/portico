import AppKit
import Foundation
import os

/// The MCP Apps method names, copied from the stable spec text (ruling 34):
/// https://raw.githubusercontent.com/modelcontextprotocol/ext-apps/main/specification/2026-01-26/apps.mdx
/// at commit 298e884ec3f02daba085acdb02042d73bd00b355 (the file's last
/// change, 2026-01-26), fetched 2026-11-03. Not from memory.
enum MCPAppMethods {
    static let protocolVersion = "2026-01-26"

    // Lifecycle (view -> host)
    static let initialize = "ui/initialize"
    static let initialized = "ui/notifications/initialized"
    static let ping = "ping"

    // Host -> view notifications
    static let toolInput = "ui/notifications/tool-input"
    static let toolResult = "ui/notifications/tool-result"
    static let toolCancelled = "ui/notifications/tool-cancelled"
    static let hostContextChanged = "ui/notifications/host-context-changed"
    // Host -> view request
    static let resourceTeardown = "ui/resource-teardown"

    // View -> host notifications
    static let sizeChanged = "ui/notifications/size-changed"
    static let log = "notifications/message"

    // View -> host requests
    static let message = "ui/message"
    static let updateModelContext = "ui/update-model-context"
    static let openLink = "ui/open-link"
    static let requestDisplayMode = "ui/request-display-mode"
    static let toolsCall = "tools/call"
}

/// The host side of one page's JSON-RPC (spec §2.3.5: native, no
/// third-party script). What the page posts comes in as text through
/// `receive`; what the host says goes out through `post`, which the page's
/// web view delivers as a `message` event. Nothing but the initialize
/// answer reaches the page before it says `initialized` (spec lifecycle).
@MainActor
final class MCPAppBridge {
    enum Placement: Hashable, Sendable { case card, viewer }

    let toolUseId: String
    let chat: Int
    let placement: Placement
    weak var model: AppModel?
    /// Delivers one JSON text to the page.
    var post: ((String) -> Void)?
    /// The page's container size, for the host context (set by the page's view).
    var containerWidth: CGFloat = 700
    var containerHeight: CGFloat?
    private(set) var initialized = false
    private var detached = false
    private var nextRequest = 1
    /// Requests the host made (teardown), answered by the page.
    private var awaiting: [String: () -> Void] = [:]

    private static let log = Logger(subsystem: "Portico", category: "mcp-apps")

    init(toolUseId: String, chat: Int, placement: Placement, model: AppModel?) {
        self.toolUseId = toolUseId
        self.chat = chat
        self.placement = placement
        self.model = model
    }

    // MARK: - the sandbox's address and policy (ruling 32)

    /// `mcpapp-<server>`: lowercased, every character outside `[a-z0-9+.-]` a `-`.
    static func scheme(forServer server: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789+.-")
        return "mcpapp-" + String(server.lowercased().map { allowed.contains($0) ? $0 : "-" })
    }

    /// The page's address under its scheme.
    static func pageURL(forServer server: String) -> URL {
        URL(string: "\(scheme(forServer: server))://app/index.html")!
    }

    static let defaultPolicy =
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'self'"

    /// The CSP header from the resource's `csp`, else the spec's strict default.
    /// Domains that could add a directive or a keyword of their own are dropped.
    static func contentSecurityPolicy(_ csp: [String: JSONValue]?) -> String {
        guard let csp else { return defaultPolicy }
        func domains(_ key: String) -> [String] {
            guard case .array(let values)? = csp[key] else { return [] }
            return values.compactMap(\.stringValue).filter(isSafeSource)
        }
        let connect = domains("connectDomains")
        let resource = domains("resourceDomains")
        let frame = domains("frameDomains")
        let base = domains("baseUriDomains")
        func list(_ base: [String], _ extra: [String]) -> String { (base + extra).joined(separator: " ") }
        var directives = [
            "default-src 'none'",
            "script-src " + list(["'self'", "'unsafe-inline'"], resource),
            "style-src " + list(["'self'", "'unsafe-inline'"], resource),
            "img-src " + list(["'self'", "data:"], resource),
            "media-src " + list(["'self'", "data:"], resource),
        ]
        if !resource.isEmpty { directives.append("font-src " + list(["'self'"], resource)) }
        directives += [
            "connect-src " + (connect.isEmpty ? "'none'" : connect.joined(separator: " ")),
            "frame-src " + (frame.isEmpty ? "'none'" : frame.joined(separator: " ")),
            "object-src 'none'",
            "base-uri " + (base.isEmpty ? "'self'" : base.joined(separator: " ")),
        ]
        return directives.joined(separator: "; ")
    }

    /// Only `scheme://host[:port]` for http, https, ws and wss, with an
    /// optional `*.` before the host. Scheme-only sources (`https:`, `data:`,
    /// `blob:`), keywords, paths, quotes and control characters are refused.
    static func isSafeSource(_ source: String) -> Bool {
        source.wholeMatch(of: safeSource) != nil
    }

    nonisolated(unsafe) private static let safeSource =
        /(?i)(?:https?|wss?):\/\/(?:\*\.)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*(?::[0-9]{1,5})?/

    // MARK: - from the page

    /// One message the page posted (its JSON text).
    func receive(_ text: String) {
        guard !detached else { return }
        // Measured before decoding: a page can't make the app send the gateway a frame it closes on.
        guard text.utf8.count <= AppLimits.maxMessageBytes else {
            return replyError(id: .null, code: -32600, message: "Too large")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            return replyError(id: .null, code: -32700, message: "Parse error")
        }
        guard case .object(let message) = value else {
            return replyError(id: .null, code: -32600, message: "Invalid Request")
        }
        let id = message["id"]
        guard message["jsonrpc"] == .string("2.0") else {
            return replyError(id: id ?? .null, code: -32600, message: "Invalid Request")
        }
        guard let method = message["method"]?.stringValue else {
            // A reply to a request of ours (the teardown), or nothing we asked.
            if let id, message["result"] != nil || message["error"] != nil {
                if let key = id.stringValue { awaiting.removeValue(forKey: key)?() }
            } else {
                replyError(id: id ?? .null, code: -32600, message: "Invalid Request")
            }
            return
        }
        let params = message["params"] ?? .object([:])
        if let id {
            handleRequest(id: id, method: method, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func handleNotification(method: String, params: JSONValue) {
        switch method {
        case MCPAppMethods.initialized:
            guard !initialized else { return }
            initialized = true
            deliverStart()
        case MCPAppMethods.sizeChanged:
            guard placement == .card, let height = Self.number(params["height"]) else { return }
            model?.appSizeChanged(toolUseId, height: height)
        case MCPAppMethods.log:
            let data = params["data"].flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) } ?? ""
            Self.log.info("app \(self.toolUseId, privacy: .public): \(data.prefix(500), privacy: .private)")
        default:
            break  // a notification nobody here knows is dropped (JSON-RPC: no reply)
        }
    }

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) {
        switch method {
        case MCPAppMethods.initialize:
            reply(id: id, result: initializeResult(params))
        case MCPAppMethods.ping:
            reply(id: id, result: .object([:]))
        case MCPAppMethods.toolsCall:
            guard let name = params["name"]?.stringValue, !name.isEmpty else {
                return replyError(id: id, code: -32602, message: "tools/call needs a name")
            }
            var arguments: [String: JSONValue] = [:]
            if case .object(let given)? = params["arguments"] { arguments = given }
            guard let encoded = try? JSONEncoder().encode(arguments), encoded.count <= AppLimits.maxPayloadBytes else {
                return replyError(id: id, code: -32602, message: "The arguments are too large")
            }
            guard let model else { return replyError(id: id, code: -32000, message: "Unknown app") }
            model.appCallTool(toolUseId, tool: name, arguments: arguments) { [weak self] result in
                guard let self else { return }
                if result.ok {
                    var answer: [String: JSONValue] = ["content": .array(result.content), "isError": .bool(result.isError)]
                    if let structured = result.structuredContent { answer["structuredContent"] = .object(structured) }
                    self.reply(id: id, result: .object(answer))
                } else {
                    self.replyError(id: id, code: -32000, message: result.error ?? "The call failed")
                }
            }
        case MCPAppMethods.message:
            let text = Self.text(of: params["content"])
            guard !text.isEmpty else { return replyError(id: id, code: -32602, message: "Invalid message format") }
            guard text.utf8.count <= AppLimits.maxPayloadBytes else {
                return replyError(id: id, code: -32602, message: "The message is too long")
            }
            guard let model else { return replyError(id: id, code: -32000, message: "Unknown app") }
            model.appMessage(toolUseId, text: text) { [weak self] refusal in
                guard let self else { return }
                if let refusal {
                    self.replyError(id: id, code: -32000, message: refusal)
                } else {
                    self.reply(id: id, result: .object([:]))
                }
            }
        case MCPAppMethods.updateModelContext:
            var text = Self.text(of: params["content"])
            if let structured = params["structuredContent"], structured != .null,
               let data = try? JSONEncoder().encode(structured) {
                text += (text.isEmpty ? "" : "\n") + String(decoding: data, as: UTF8.self)
            }
            model?.appContext(toolUseId, text: String(text.prefix(AppLimits.maxContextCharacters)))
            reply(id: id, result: .object([:]))
        case MCPAppMethods.openLink:
            guard let address = params["url"]?.stringValue else {
                return replyError(id: id, code: -32602, message: "ui/open-link needs a url")
            }
            guard let model else { return replyError(id: id, code: -32000, message: "Unknown app") }
            if let refusal = model.appOpenLink(toolUseId, address: address) {
                return replyError(id: id, code: -32000, message: refusal)
            }
            reply(id: id, result: .object([:]))
        case MCPAppMethods.requestDisplayMode:
            let asked = params["mode"]?.stringValue ?? "inline"
            let mode = model?.appRequestDisplayMode(toolUseId, placement: placement, mode: asked) ?? currentMode
            reply(id: id, result: .object(["mode": .string(mode)]))
        default:
            replyError(id: id, code: -32601, message: "Method not found")
        }
    }

    private var currentMode: String { placement == .viewer ? "fullscreen" : "inline" }

    // MARK: - to the page

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        var sandbox: [String: JSONValue] = ["permissions": .object([:])]
        if let csp = model?.apps[toolUseId]?.csp { sandbox["csp"] = .object(csp) }
        let version = model?.appVersion ?? "0"
        return .object([
            "protocolVersion": .string(MCPAppMethods.protocolVersion),
            "hostCapabilities": .object([
                "openLinks": .object([:]),
                "serverTools": .object([:]),
                "logging": .object([:]),
                "sandbox": .object(sandbox),
            ]),
            "hostInfo": .object(["name": .string("Portico"), "version": .string(version)]),
            "hostContext": .object(hostContext()),
        ])
    }

    /// Ruling 35's host context. Style variables are not sent in v0.18.
    func hostContext() -> [String: JSONValue] {
        var dimensions: [String: JSONValue] = ["width": .double(Double(containerWidth))]
        if placement == .viewer, let containerHeight {
            dimensions["height"] = .double(Double(containerHeight))
        } else {
            dimensions["maxHeight"] = .int(Int(AppState.maxHeight))
        }
        return [
            "theme": .string(Self.theme()),
            "displayMode": .string(currentMode),
            "availableDisplayModes": .array([.string("inline"), .string("fullscreen")]),
            "containerDimensions": .object(dimensions),
            "locale": .string(Locale.current.identifier(.bcp47)),
            "timeZone": .string(TimeZone.current.identifier),
            "platform": .string("desktop"),
            "userAgent": .string("Portico/\(model?.appVersion ?? "0")"),
        ]
    }

    static func theme() -> String {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    /// After `initialized`: the input, then the result (or the cancel) when it is known.
    private func deliverStart() {
        let state = model?.apps[toolUseId]
        notify(MCPAppMethods.toolInput, .object(["arguments": .object(state?.input ?? [:])]))
        if let result = state?.result {
            deliverResult(result)
        } else if state?.cancelled == true {
            deliverCancelled()
        }
    }

    func deliverResult(_ result: AppResult) {
        guard initialized else { return }  // sent after `initialized` from the model's state
        var params: [String: JSONValue] = ["content": .array(result.content), "isError": .bool(result.isError)]
        if let structured = result.structuredContent { params["structuredContent"] = .object(structured) }
        notify(MCPAppMethods.toolResult, .object(params))
    }

    func deliverCancelled() {
        guard initialized else { return }
        notify(MCPAppMethods.toolCancelled, .object(["reason": .string("The call ended with no result")]))
    }

    /// The appearance (or the container) changed.
    func hostContextChanged(_ partial: [String: JSONValue]) {
        guard initialized else { return }
        notify(MCPAppMethods.hostContextChanged, .object(partial))
    }

    /// `ui/resource-teardown`, then `done` once the page answers or after `timeout`,
    /// whichever is first. A page that never initialized is not asked.
    func teardown(reason: String, timeout: Duration = .milliseconds(500), done: @escaping () -> Void) {
        guard initialized, !detached, post != nil else { return done() }
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done()
        }
        let key = "host-\(nextRequest)"
        let id = JSONValue.string(key)
        nextRequest += 1
        awaiting[key] = finish
        send(.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(MCPAppMethods.resourceTeardown),
                      "params": .object(["reason": .string(reason)])]))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.awaiting[key] = nil
            finish()
        }
    }

    /// The page is gone: nothing more goes to it or comes from it.
    func detach() {
        detached = true
        post = nil
        awaiting = [:]
    }

    private func notify(_ method: String, _ params: JSONValue) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    private func reply(id: JSONValue, result: JSONValue) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func replyError(id: JSONValue, code: Int, message: String) {
        send(.object(["jsonrpc": .string("2.0"), "id": id,
                      "error": .object(["code": .int(code), "message": .string(message)])]))
    }

    private func send(_ value: JSONValue) {
        guard !detached, let post, let data = try? JSONEncoder().encode(value) else { return }
        post(String(decoding: data, as: UTF8.self))
    }

    // MARK: - reading params

    private static func number(_ value: JSONValue?) -> CGFloat? {
        switch value {
        case .int(let i)?: CGFloat(i)
        case .double(let d)?: CGFloat(d)
        default: nil
        }
    }

    /// The text of a content block, or of a list of them (text blocks only).
    static func text(of content: JSONValue?) -> String {
        switch content {
        case .object(let block)?:
            return block["type"] == .string("text") ? (block["text"]?.stringValue ?? "") : ""
        case .array(let blocks)?:
            return blocks.map { text(of: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .string(let s)?:
            return s
        default:
            return ""
        }
    }
}
