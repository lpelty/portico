import AppKit
import Foundation

/// One MCP app card (v0.18 §2.3), per the agent's call `toolUseId`: what
/// `app.open` said, the result the page is given, and how the card stands
/// (live, frozen, its page's height).
struct AppState: Equatable, Sendable {
    var toolUseId: String
    var chat: Int
    var server: String
    var serverTitle: String
    var tool: String
    var resourceUri: String
    /// The page; `nil` for a card restored from history (no page until Reload).
    var html: String?
    var csp: [String: JSONValue]?
    var permissions: [String: JSONValue]?
    var prefersBorder: Bool
    var input: [String: JSONValue]
    /// The call's result (`app.result`), once it came.
    var result: AppResult? = nil
    /// The call ended with no result (`app.cancelled`).
    var cancelled = false
    /// Not live: its last look as an image (in memory), or the restored
    /// placeholder when there is none. Reload makes it live again.
    var frozen = false
    /// The page's height in the card, from its `size-changed`, at most `maxHeight`.
    var height: CGFloat = AppState.initialHeight
    /// A Reload is out (its request id) and not answered yet.
    var reloading: String? = nil
    /// Bumped each time the page is read again: a page made for an older one is stale.
    var generation = 0

    static let maxHeight: CGFloat = 520
    static let initialHeight: CGFloat = 120
    /// The three newest cards in a conversation stay live (ruling 31).
    static let liveLimit = 3

    init(_ open: AppOpen) {
        toolUseId = open.toolUseId
        chat = open.chat
        server = open.server
        serverTitle = open.serverTitle
        tool = open.tool
        resourceUri = open.resourceUri
        html = open.html
        csp = open.csp
        permissions = open.permissions
        prefersBorder = open.prefersBorder ?? false
        input = open.input
        frozen = open.html == nil
    }
}

/// What the card's chrome says (AQ1, AQ2), apart from the view so a test reads it.
struct AppCardPresentation: Equatable {
    let title: String
    let subtitle: String
    let accessibilityLabel: String
    /// The header's buttons, in order: Reload when frozen, then Open in viewer.
    let buttons: [String]
    /// The body of a frozen card with no image (a restored one).
    let placeholder: String?

    static let reload = "Reload"
    static let openInViewer = "Open in viewer"

    init(state: AppState, hasImage: Bool) {
        title = state.serverTitle
        subtitle = "· \(state.tool)"
        accessibilityLabel = "\(state.serverTitle) app, \(state.tool)"
        buttons = state.frozen ? [Self.reload, Self.openInViewer] : [Self.openInViewer]
        placeholder = state.frozen && !hasImage ? "\(state.serverTitle) · Reload to show it again" : nil
    }
}

/// Where a page is drawn: the card in the conversation, or its copy in the viewer.
struct AppPageKey: Hashable {
    var toolUseId: String
    var placement: MCPAppBridge.Placement
}

// MARK: - the model's side

extension AppModel {
    /// The card for the agent's call `id`, when its `app.open` came for a row the conversation has.
    func app(forToolUse id: String) -> AppState? { apps[id] }

    /// The card's page is live (one of the chat's three newest, or reloaded).
    func isLive(_ id: String, chat: Int) -> Bool { liveApps[chat]?.contains(id) ?? false }

    /// A frozen card's last look, when it was frozen in this run.
    func appSnapshot(_ id: String) -> NSImage? { appSnapshots[id] }

    /// The `app.*` frames, live or in a replay (`applyEvent`). `items` is the chat's transcript.
    func applyApp(_ event: ServerMessage, chat: Int, items: [TranscriptItem]) {
        switch event {
        case .appOpen(let open):
            applyAppOpen(open, items: items)
        case .appResult(let result):
            guard apps[result.toolUseId] != nil else { return }
            apps[result.toolUseId]?.result = result
            apps[result.toolUseId]?.cancelled = false
            for bridge in bridges(for: result.toolUseId) { bridge.deliverResult(result) }
        case .appCancelled(let cancelled):
            guard apps[cancelled.toolUseId] != nil, apps[cancelled.toolUseId]?.result == nil else { return }
            apps[cancelled.toolUseId]?.cancelled = true
            for bridge in bridges(for: cancelled.toolUseId) { bridge.deliverCancelled() }
        default:
            break
        }
    }

    private func applyAppOpen(_ open: AppOpen, items: [TranscriptItem]) {
        let id = open.toolUseId
        // Only in place of a row the conversation has (the order on the wire puts it first).
        guard Self.toolIndex(id, in: items) != nil else { return }
        guard var state = apps[id] else {
            apps[id] = AppState(open)
            if open.html != nil { markLive(id, chat: open.chat, items: items) }
            return
        }
        // The same card again: what the server said may have changed; the page only with new html.
        state.serverTitle = open.serverTitle
        state.csp = open.csp ?? state.csp
        state.permissions = open.permissions ?? state.permissions
        state.prefersBorder = open.prefersBorder ?? state.prefersBorder
        state.input = open.input
        let answersReload = open.id != nil && open.id == state.reloading
        if answersReload { state.reloading = nil }
        guard let html = open.html else {
            // A replay (a reconnect): a page still live keeps going.
            apps[id] = state
            return
        }
        let fresh = answersReload || state.frozen || html != state.html
        state.html = html
        if fresh {
            state.generation += 1
            state.frozen = false
            state.result = nil
            state.cancelled = false
            apps[id] = state
            appSnapshots[id] = nil
            retirePage(AppPageKey(toolUseId: id, placement: .card))
            markLive(id, chat: open.chat, items: items)
        } else {
            apps[id] = state
        }
    }

    /// `id` joins the chat's live cards; past three, the oldest other one (by transcript order) freezes.
    private func markLive(_ id: String, chat: Int, items: [TranscriptItem]) {
        var live = liveApps[chat] ?? []
        live.removeAll { $0 == id }
        live.append(id)
        while live.count > AppState.liveLimit {
            let others = live.filter { $0 != id }
            guard let oldest = others.min(by: {
                (Self.toolIndex($0, in: items) ?? Int.max) < (Self.toolIndex($1, in: items) ?? Int.max)
            }) else { break }
            live.removeAll { $0 == oldest }
            freezeApp(oldest)
        }
        liveApps[chat] = live
    }

    /// The card stops being live: its page's last look is kept as an image,
    /// the page is told it is going (at most 0.5 s), and then it goes.
    private func freezeApp(_ id: String) {
        apps[id]?.frozen = true
        let key = AppPageKey(toolUseId: id, placement: .card)
        guard let page = appPages[key] else {
            appBridges[key] = nil
            return
        }
        page.freeze { [weak self] image in
            guard let self else { return }
            if let image, self.apps[id]?.frozen == true { self.appSnapshots[id] = image }
            // A Reload may have made a new page meanwhile; only this one goes.
            if self.appPages[key] === page {
                self.removePage(key)
                self.objectWillChange.send()
            }
        }
    }

    /// Reload: read the page again; the gateway answers with `app.open` and the html.
    func reloadApp(_ id: String, chat: Int) {
        guard apps[id] != nil else { return }
        let request = Self.requestId()
        apps[id]?.reloading = request
        send(.appReload(AppReload(chat: chat, toolUseId: id, id: request)))
    }

    /// Open in viewer (and the page's `request-display-mode: fullscreen`): a
    /// fresh copy of the page in the viewer pane; the card stays.
    func openAppInViewer(_ id: String, chat: Int) {
        guard let state = apps[id], state.html != nil else { return }
        if viewerApp[chat] != id { closeAppInViewer(chat: chat) }
        viewerApp[chat] = id
        showViewerForApp(chat: chat)
    }

    /// The viewer copy goes (X, a file shown, the copy asking for `inline`).
    func closeAppInViewer(chat: Int) {
        guard let id = viewerApp[chat] else { return }
        viewerApp[chat] = nil
        let key = AppPageKey(toolUseId: id, placement: .viewer)
        if let page = appPages[key] {
            page.close { [weak self] in
                if self?.appPages[key] === page { self?.removePage(key) }
            }
        } else {
            appBridges[key] = nil
        }
    }

    /// The viewer's X on the app: the copy goes; the file under it, if any, shows again.
    func closeAppViewer(chat: Int) {
        closeAppInViewer(chat: chat)
        if current[chat] == nil { hideViewerAfterApp(chat: chat) }
    }

    // MARK: pages and bridges

    /// The bridge for `id`'s page in `placement`, made when first asked for.
    func appBridge(_ id: String, placement: MCPAppBridge.Placement) -> MCPAppBridge {
        let key = AppPageKey(toolUseId: id, placement: placement)
        if let bridge = appBridges[key] { return bridge }
        let bridge = MCPAppBridge(toolUseId: id, chat: apps[id]?.chat ?? 0, placement: placement, model: self)
        appBridges[key] = bridge
        return bridge
    }

    /// The page for `id` in `placement`: the existing one, else a new one
    /// when it may be drawn (a live card, or the viewer's copy). `nil` when
    /// there is no page to show (a frozen card whose page is gone).
    func appPage(_ id: String, placement: MCPAppBridge.Placement) -> MCPAppPage? {
        let key = AppPageKey(toolUseId: id, placement: placement)
        let existing = appPages[key]
        guard let state = apps[id], let html = state.html else { return existing }
        let mayDraw = placement == .card ? !state.frozen : viewerApp[state.chat] == id
        if let existing, existing.generation == state.generation || !mayDraw { return existing }
        guard mayDraw else { return nil }
        removePage(key)
        let page = MCPAppPage(state: state, html: html, bridge: appBridge(id, placement: placement), appVersion: appVersion)
        appPages[key] = page
        return page
    }

    private func bridges(for id: String) -> [MCPAppBridge] {
        [MCPAppBridge.Placement.card, .viewer].compactMap { appBridges[AppPageKey(toolUseId: id, placement: $0)] }
    }

    /// A page leaves the registry at once (a new one may take its place) and
    /// goes after its teardown (`ui/resource-teardown`, at most 0.5 s).
    private func retirePage(_ key: AppPageKey) {
        let bridge = appBridges.removeValue(forKey: key)
        guard let page = appPages.removeValue(forKey: key) else {
            bridge?.detach()
            return
        }
        page.close { page.dispose() }
    }

    private func removePage(_ key: AppPageKey) {
        appPages[key]?.dispose()
        appPages[key] = nil
        appBridges[key]?.detach()
        appBridges[key] = nil
    }

    /// A chat that is gone takes its cards and pages with it.
    func forgetApps(chat: Int) {
        let ids = apps.values.filter { $0.chat == chat }.map(\.toolUseId)
        for id in ids {
            retirePage(AppPageKey(toolUseId: id, placement: .card))
            retirePage(AppPageKey(toolUseId: id, placement: .viewer))
            apps[id] = nil
            appSnapshots[id] = nil
            appLinkTimes[id] = nil
            appCallsInFlight[id] = nil
        }
        liveApps[chat] = nil
        viewerApp[chat] = nil
    }

    // MARK: what the page asks for

    /// The page's `tools/call`: `app.call_tool`, answered by `app.call_result` with the same id.
    func appCallTool(_ id: String, tool: String, arguments: [String: JSONValue], reply: @escaping (AppCallResult) -> Void) {
        guard let state = apps[id] else {
            return reply(AppCallResult(toolUseId: id, ok: false, error: "Unknown app"))
        }
        // At most `maxCallsInFlight` per card: a page can't flood the gateway with consent cards.
        guard (appCallsInFlight[id] ?? 0) < AppLimits.maxCallsInFlight else {
            return reply(AppCallResult(toolUseId: id, ok: false, error: "Too many calls at once"))
        }
        appCallsInFlight[id, default: 0] += 1
        let request = Self.requestId()
        pendingAppCalls[request] = { [weak self] result in
            if let count = self?.appCallsInFlight[id] { self?.appCallsInFlight[id] = count > 1 ? count - 1 : nil }
            reply(result)
        }
        send(.appCallTool(AppCallTool(chat: state.chat, toolUseId: id, tool: tool, arguments: arguments, id: request)))
    }

    /// The page's `ui/message`: `app.message`. Answered when the gateway took it (its
    /// `user.text` with `via`, or `chat.queued`), refused when an `error` carries its id.
    func appMessage(_ id: String, text: String, reply: @escaping (String?) -> Void) {
        guard let state = apps[id] else { return reply("Unknown app") }
        let request = Self.requestId()
        pendingAppMessages.append(PendingAppMessage(id: request, chat: state.chat, reply: reply))
        send(.appMessage(AppMessage(chat: state.chat, toolUseId: id, text: text, id: request)))
    }

    /// The page's `ui/update-model-context`: `app.context` (not answered).
    func appContext(_ id: String, text: String) {
        guard let state = apps[id] else { return }
        send(.appContext(AppContext(chat: state.chat, toolUseId: id, text: text)))
    }

    /// The page's `size-changed`: the card's page is that tall, at most 520.
    func appSizeChanged(_ id: String, height: CGFloat) {
        guard let state = apps[id], height.isFinite else { return }
        let clamped = min(max(height, 1), AppState.maxHeight)
        guard clamped != state.height else { return }
        apps[id]?.height = clamped
    }

    /// The page's `ui/open-link` for card `id`: at most one a second per card,
    /// then `openLink`. `nil` when it opened, else the reason it didn't.
    func appOpenLink(_ id: String, address: String) -> String? {
        guard let state = apps[id] else { return "Unknown app" }
        guard AppModel.isWebAddress(address) else { return "Only web addresses open in the viewer" }
        let now = appClock()
        if let last = appLinkTimes[id], now.timeIntervalSince(last) < AppLimits.linkInterval { return "Slow down" }
        appLinkTimes[id] = now
        return openLink(address, chat: state.chat) ? nil : "Only web addresses open in the viewer"
    }

    /// The page's `request-display-mode`. From the card, `fullscreen` opens the
    /// viewer copy; from the viewer copy, `inline` closes it. Answers the mode it is in.
    func appRequestDisplayMode(_ id: String, placement: MCPAppBridge.Placement, mode: String) -> String {
        guard let state = apps[id] else { return "inline" }
        switch (placement, mode) {
        case (.card, "fullscreen"):
            openAppInViewer(id, chat: state.chat)
            return viewerApp[state.chat] == id ? "fullscreen" : "inline"
        case (.viewer, "inline"):
            closeAppViewer(chat: state.chat)
            return "inline"
        case (.viewer, _):
            return "fullscreen"
        default:
            return "inline"
        }
    }

    // MARK: answers from the gateway

    /// `app.call_result`: the call it answers hears it.
    func applyAppCallResult(_ result: AppCallResult) {
        guard let id = result.id, let reply = pendingAppCalls.removeValue(forKey: id) else { return }
        reply(result)
    }

    /// An `error` with the id of a page's call or message: the page hears the reason.
    func applyAppRefusal(_ error: ErrorMessage) {
        guard let id = error.id else { return }
        if let reply = pendingAppCalls.removeValue(forKey: id) {
            reply(AppCallResult(toolUseId: "", ok: false, error: error.message))
        }
        if let index = pendingAppMessages.firstIndex(where: { $0.id == id }) {
            pendingAppMessages.remove(at: index).reply(error.message)
        }
        if let id = apps.first(where: { $0.value.reloading == error.id })?.key {
            apps[id]?.reloading = nil
        }
    }

    /// The gateway took a page's message: its queueing (`chat.queued` with its
    /// id), or its echo (`user.text` with `via`, by id when it carries one,
    /// else the chat's oldest message out).
    func noteAppMessageTaken(chat: Int, id: String?, echo: Bool) {
        var index = id.flatMap { id in pendingAppMessages.firstIndex { $0.id == id } }
        if index == nil, echo { index = pendingAppMessages.firstIndex { $0.chat == chat } }
        guard let index else { return }
        pendingAppMessages.remove(at: index).reply(nil)
    }

    /// A new connection: nothing sent on the old one will be answered.
    func failPendingAppRequests() {
        let calls = pendingAppCalls
        pendingAppCalls = [:]
        appCallsInFlight = [:]
        for reply in calls.values { reply(AppCallResult(toolUseId: "", ok: false, error: "The call failed")) }
        let messages = pendingAppMessages
        pendingAppMessages = []
        for message in messages { message.reply("The message wasn't sent") }
        for id in apps.keys { apps[id]?.reloading = nil }
    }
}

/// A page's `ui/message` the gateway hasn't taken or refused yet.
struct PendingAppMessage {
    var id: String
    var chat: Int
    var reply: (String?) -> Void
}

/// What a page may ask of the app at once (v0.18 fix round 1). The gateway
/// closes the socket on a frame over 16 MiB, so nothing a page sends gets near it.
enum AppLimits {
    /// One message from the page, as UTF-8 bytes, before it is decoded.
    static let maxMessageBytes = 1 << 20
    /// A `ui/message` text, or a `tools/call`'s encoded arguments, as UTF-8 bytes.
    static let maxPayloadBytes = 256 << 10
    /// An `app.context` text, in characters (the gateway keeps as much).
    static let maxContextCharacters = 16_000
    /// `tools/call`s out at once per card.
    static let maxCallsInFlight = 4
    /// Seconds between two `ui/open-link`s from one card.
    static let linkInterval: TimeInterval = 1
}
