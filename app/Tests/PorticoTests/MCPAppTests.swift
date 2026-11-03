import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import Portico

/// v0.18 §2.3: an MCP app's page in a card in place of the tool row, its
/// sandbox, the host side of its JSON-RPC, three live cards, frozen cards
/// with Reload, and the viewer copy.
@MainActor
final class MCPAppTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    // MARK: - fixtures

    private func isolatedSettings() -> Portico.Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Portico.Settings(defaults: defaults)
    }

    /// A model showing chat 1, what it sends kept in `sent`.
    private final class Sent { var frames: [ClientMessage] = [] }

    private func model(_ sent: Sent = Sent()) -> AppModel {
        let model = AppModel(settings: isolatedSettings())
        model.outbound = { sent.frames.append($0) }
        model.selected = 1
        return model
    }

    private func started(_ id: String, chat: Int = 1, tool: String = "mcp__acme-tracker__show_project") -> ServerMessage {
        .toolStarted(ToolStarted(
            chat: chat, turn: 1, toolUseId: id, tool: tool, summary: "show_project",
            input: ["project": .string("Acme launch")]))
    }

    private func finished(_ id: String, chat: Int = 1) -> ServerMessage {
        .toolFinished(ToolFinished(chat: chat, turn: 1, toolUseId: id, ok: true, summary: "done"))
    }

    private func open(_ id: String, chat: Int = 1, html: String? = "<!doctype html><title>Acme</title>",
                      csp: [String: JSONValue]? = nil, requestId: String? = nil) -> ServerMessage {
        .appOpen(AppOpen(
            chat: chat, toolUseId: id, server: "acme-tracker", serverTitle: "Acme Tracker", tool: "show_project",
            resourceUri: "ui://tracker/project.html", html: html, csp: csp, prefersBorder: true,
            input: ["project": .string("Acme launch")], id: requestId))
    }

    private func result(_ id: String, chat: Int = 1) -> ServerMessage {
        .appResult(AppResult(
            chat: chat, toolUseId: id, content: [.object(["type": .string("text"), "text": .string("3 of 4 done")])],
            structuredContent: ["tasks": .int(4), "done": .int(3)], isError: false))
    }

    /// A card for `id`: its tool row, then its page.
    private func card(_ model: AppModel, _ id: String, chat: Int = 1, html: String? = "<!doctype html><title>Acme</title>") {
        model.apply(started(id, chat: chat))
        model.apply(open(id, chat: chat, html: html))
    }

    /// What a bridge posted to the page, decoded.
    private final class Posted {
        var messages: [JSONValue] = []
        func last() -> JSONValue? { messages.last }
    }

    private func bridge(_ model: AppModel, _ id: String, placement: MCPAppBridge.Placement = .card) -> (MCPAppBridge, Posted) {
        let posted = Posted()
        let bridge = model.appBridge(id, placement: placement)
        bridge.post = { text in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { posted.messages.append(value) }
        }
        return (bridge, posted)
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> String {
        json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func spin(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Waits up to `timeout` for `condition`, running the main loop meanwhile.
    private func wait(_ timeout: Double = 5, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return try await condition()
    }

    /// A hosted page for `id`'s card in a borderless window.
    private func hosted(_ model: AppModel, _ id: String, placement: MCPAppBridge.Placement = .card) throws -> WKWebView {
        let page = try XCTUnwrap(model.appPage(id, placement: placement), "no page for \(id)")
        let size = NSSize(width: 700, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        page.webView.frame = NSRect(origin: .zero, size: size)
        window.contentView = page.webView
        keepAlive += [window, page, model]
        return page.webView
    }

    // MARK: - the sandbox's address and policy

    func testSchemeForServer() {
        XCTAssertEqual(MCPAppBridge.scheme(forServer: "Acme Tracker"), "mcpapp-acme-tracker")
        XCTAssertEqual(MCPAppBridge.scheme(forServer: "a_b/c"), "mcpapp-a-b-c")
    }

    func testCSPDefaultAndDeclared() {
        XCTAssertEqual(
            MCPAppBridge.contentSecurityPolicy(nil),
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'self'")
        let declared = MCPAppBridge.contentSecurityPolicy([
            "connectDomains": .array([.string("https://api.acme.example")]),
            "resourceDomains": .array([.string("https://cdn.acme.example")]),
        ])
        let directives = Dictionary(uniqueKeysWithValues: declared.split(separator: ";").map { part -> (String, String) in
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            return (words[0], words.count > 1 ? words[1] : "")
        })
        XCTAssertEqual(directives["connect-src"], "https://api.acme.example")
        for name in ["script-src", "style-src", "img-src"] {
            XCTAssertTrue(directives[name]?.contains("https://cdn.acme.example") ?? false, "\(name): \(directives[name] ?? "-")")
        }
        XCTAssertEqual(directives["frame-src"], "'none'")
        // A declared domain can't add a directive of its own.
        let injected = MCPAppBridge.contentSecurityPolicy(["connectDomains": .array([.string("https://a.example; script-src *")])])
        XCTAssertFalse(injected.contains("script-src *"), injected)
    }

    // MARK: - the card in the conversation

    func testCardReplacesTheToolRow() {
        let model = model()
        card(model, "toolu_01")
        XCTAssertNotNil(model.app(forToolUse: "toolu_01"))
        let items = model.transcripts[1] ?? []
        guard case .tool(let row)? = items.first(where: { $0.id == "tool:toolu_01" }) else { return XCTFail("no row") }
        XCTAssertEqual(ToolRowContent.kind(of: row, model: model), .app)

        // An app.open for a call the conversation doesn't have keeps the rows as they are.
        model.apply(started("toolu_02"))
        model.apply(open("toolu_99"))
        XCTAssertNil(model.app(forToolUse: "toolu_99"))
        guard case .tool(let other)? = (model.transcripts[1] ?? []).first(where: { $0.id == "tool:toolu_02" }) else { return XCTFail("no row") }
        XCTAssertEqual(ToolRowContent.kind(of: other, model: model), .row)
    }

    func testSizeChangedClampsTo520() {
        let model = model()
        card(model, "toolu_01")
        let (bridge, _) = bridge(model, "toolu_01")
        bridge.receive(json(["jsonrpc": "2.0", "method": "ui/notifications/size-changed", "params": ["width": 700, "height": 2000]]))
        XCTAssertEqual(model.app(forToolUse: "toolu_01")?.height, 520)
        bridge.receive(json(["jsonrpc": "2.0", "method": "ui/notifications/size-changed", "params": ["width": 700, "height": 120]]))
        XCTAssertEqual(model.app(forToolUse: "toolu_01")?.height, 120)
    }

    // MARK: - the page's requests

    func testToolsCallRoundTrip() throws {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let (bridge, posted) = bridge(model, "toolu_01")
        bridge.receive(request(7, "tools/call", ["name": "update_task", "arguments": ["task": "Launch email", "status": "done"]]))
        guard case .appCallTool(let call)? = sent.frames.last else { return XCTFail("no app.call_tool: \(sent.frames)") }
        XCTAssertEqual(call.tool, "update_task")
        XCTAssertEqual(call.toolUseId, "toolu_01")
        XCTAssertEqual(call.chat, 1)
        XCTAssertEqual(call.arguments, ["task": .string("Launch email"), "status": .string("done")])
        let id = try XCTUnwrap(call.id)
        model.apply(.appCallResult(AppCallResult(
            toolUseId: "toolu_01", ok: true, content: [.object(["type": .string("text"), "text": .string("Done")])],
            structuredContent: ["status": .string("done")], id: id)))
        let answer = try XCTUnwrap(posted.last())
        XCTAssertEqual(answer["id"], .int(7))
        XCTAssertEqual(answer["result"]?["structuredContent"]?["status"], .string("done"))
        XCTAssertEqual(answer["result"]?["isError"], .bool(false))

        bridge.receive(request(8, "tools/call", ["name": "delete_project", "arguments": [:]]))
        guard case .appCallTool(let second)? = sent.frames.last else { return XCTFail("no second call") }
        model.apply(.appCallResult(AppCallResult(toolUseId: "toolu_01", ok: false, error: "Denied", id: second.id)))
        let denied = try XCTUnwrap(posted.last())
        XCTAssertEqual(denied["id"], .int(8))
        XCTAssertNil(denied["result"])
        XCTAssertEqual(denied["error"]?["message"], .string("Denied"))
    }

    func testMalformedMessagesGetErrorsNotCrashes() {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let before = sent.frames.count
        let (bridge, posted) = bridge(model, "toolu_01")
        bridge.receive("42")
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32600))
        bridge.receive("not json at all")
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32700))
        bridge.receive(json(["id": 3, "method": "tools/call", "params": ["name": "update_task"]]))
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32600))
        XCTAssertEqual(posted.last()?["id"], .int(3))
        bridge.receive(request(4, "resources/write"))
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32601))
        XCTAssertEqual(posted.last()?["id"], .int(4))
        // A notification nobody knows is dropped without a reply.
        let replies = posted.messages.count
        bridge.receive(json(["jsonrpc": "2.0", "method": "ui/notifications/something-new"]))
        XCTAssertEqual(posted.messages.count, replies)
        XCTAssertEqual(sent.frames.count, before, "nothing reached the gateway: \(sent.frames.suffix(sent.frames.count - before))")
    }

    func testMessageAndContextAreSent() throws {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let (bridge, posted) = bridge(model, "toolu_01")
        bridge.receive(request(1, "ui/message", ["role": "user", "content": ["type": "text", "text": "Mark Launch email done"]]))
        guard case .appMessage(let message)? = sent.frames.last else { return XCTFail("no app.message") }
        XCTAssertEqual(message.text, "Mark Launch email done")
        XCTAssertEqual(message.toolUseId, "toolu_01")
        // Its echo answers the page.
        model.apply(.userText(UserText(chat: 1, turn: 2, text: "Mark Launch email done", via: "Acme Tracker")))
        XCTAssertEqual(posted.last()?["id"], .int(1))
        XCTAssertNotNil(posted.last()?["result"])

        // A command is refused by the gateway; the page hears why.
        bridge.receive(request(2, "ui/message", ["role": "user", "content": ["type": "text", "text": "/clear"]]))
        guard case .appMessage(let command)? = sent.frames.last else { return XCTFail("no app.message") }
        model.apply(.error(ErrorMessage(code: "app.refused", message: "Apps can't run commands", chat: 1, id: command.id)))
        XCTAssertEqual(posted.last()?["id"], .int(2))
        XCTAssertEqual(posted.last()?["error"]?["message"], .string("Apps can't run commands"))

        bridge.receive(request(3, "ui/update-model-context", [
            "content": [["type": "text", "text": "Project: Acme launch. 3 of 4 tasks done."]],
        ]))
        guard case .appContext(let context)? = sent.frames.last else { return XCTFail("no app.context") }
        XCTAssertEqual(context.text, "Project: Acme launch. 3 of 4 tasks done.")
        XCTAssertEqual(context.toolUseId, "toolu_01")
        XCTAssertEqual(posted.last()?["id"], .int(3))
        XCTAssertNotNil(posted.last()?["result"])
    }

    func testOpenLinkGoesToTheViewer() {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let (bridge, posted) = bridge(model, "toolu_01")
        bridge.receive(request(1, "ui/open-link", ["url": "https://acme.example/pricing"]))
        XCTAssertEqual(model.current[1]?.kind, .url)
        XCTAssertEqual(model.current[1]?.location, "https://acme.example/pricing")
        XCTAssertTrue(model.isViewerShown(for: 1))
        XCTAssertNotNil(posted.last()?["result"])

        bridge.receive(request(2, "ui/open-link", ["url": "file:///etc/hosts"]))
        XCTAssertEqual(posted.last()?["id"], .int(2))
        XCTAssertNotNil(posted.last()?["error"])
        XCTAssertEqual(model.current[1]?.location, "https://acme.example/pricing")
    }

    // MARK: - fix round 1: what a page may send

    func testOversizedMessagesAreRefused() {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let before = sent.frames.count
        let (bridge, posted) = bridge(model, "toolu_01")

        // Over 1 MiB raw: refused before it is decoded.
        let huge = String(repeating: "a", count: AppLimits.maxMessageBytes)
        bridge.receive(request(1, "ui/update-model-context", ["content": [["type": "text", "text": huge]]]))
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32600))
        XCTAssertEqual(posted.last()?["error"]?["message"], .string("Too large"))

        // A message text over 256 KiB.
        let long = String(repeating: "é", count: AppLimits.maxPayloadBytes / 2 + 1)  // 2 bytes each
        bridge.receive(request(2, "ui/message", ["role": "user", "content": ["type": "text", "text": long]]))
        XCTAssertEqual(posted.last()?["id"], .int(2))
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32602))

        // tools/call arguments over 256 KiB once encoded.
        let blob = String(repeating: "b", count: AppLimits.maxPayloadBytes)
        bridge.receive(request(3, "tools/call", ["name": "update_task", "arguments": ["note": blob]]))
        XCTAssertEqual(posted.last()?["id"], .int(3))
        XCTAssertEqual(posted.last()?["error"]?["code"], .int(-32602))
        XCTAssertEqual(sent.frames.count, before, "nothing oversized reached the gateway")

        // Context is cut to 16 000 characters before it goes.
        bridge.receive(request(4, "ui/update-model-context", [
            "content": [["type": "text", "text": String(repeating: "c", count: 20_000)]],
        ]))
        guard case .appContext(let context)? = sent.frames.last else { return XCTFail("no app.context") }
        XCTAssertEqual(context.text.count, AppLimits.maxContextCharacters)
    }

    func testCSPSourceAllowlist() {
        for good in ["https://api.acme.example", "wss://live.acme.example:8443", "https://*.acme.example", "http://localhost:3000", "ws://acme.example"] {
            XCTAssertTrue(MCPAppBridge.isSafeSource(good), good)
        }
        for bad in ["https:", "data:", "blob:", "*", "'unsafe-eval'", "'self'", "https://acme.example/path",
                    "https://acme.example/'x", "https://a.example; script-src *", "https://a\u{7}.example",
                    "ftp://acme.example", "https://acme.example:99999x", "acme.example", "https://*", ""] {
            XCTAssertFalse(MCPAppBridge.isSafeSource(bad), bad)
        }
        let policy = MCPAppBridge.contentSecurityPolicy([
            "connectDomains": .array([.string("https:"), .string("https://api.acme.example")]),
            "resourceDomains": .array([.string("data:"), .string("blob:")]),
        ])
        XCTAssertTrue(policy.contains("connect-src https://api.acme.example;"), policy)
        XCTAssertFalse(policy.contains("data: data:"), policy)
        XCTAssertFalse(policy.contains("blob:"), policy)
    }

    func testCallAndLinkLimitsPerCard() {
        let sent = Sent()
        let model = model(sent)
        card(model, "toolu_01")
        let (bridge, posted) = bridge(model, "toolu_01")
        for n in 1...4 { bridge.receive(request(n, "tools/call", ["name": "update_task", "arguments": [:]])) }
        XCTAssertEqual(sent.frames.filter { if case .appCallTool = $0 { true } else { false } }.count, 4)
        bridge.receive(request(5, "tools/call", ["name": "update_task", "arguments": [:]]))
        XCTAssertEqual(posted.last()?["id"], .int(5))
        XCTAssertEqual(posted.last()?["error"]?["message"], .string("Too many calls at once"))
        // One answered: there is room again.
        guard case .appCallTool(let first)? = sent.frames.first(where: { if case .appCallTool = $0 { true } else { false } }) else {
            return XCTFail("no call")
        }
        model.apply(.appCallResult(AppCallResult(toolUseId: "toolu_01", ok: true, id: first.id)))
        bridge.receive(request(6, "tools/call", ["name": "update_task", "arguments": [:]]))
        XCTAssertEqual(sent.frames.filter { if case .appCallTool = $0 { true } else { false } }.count, 5)

        var now = Date(timeIntervalSince1970: 1_000)
        model.appClock = { now }
        bridge.receive(request(7, "ui/open-link", ["url": "https://acme.example/a"]))
        XCTAssertNotNil(posted.last()?["result"])
        now += 0.5
        bridge.receive(request(8, "ui/open-link", ["url": "https://acme.example/b"]))
        XCTAssertEqual(posted.last()?["error"]?["message"], .string("Slow down"))
        XCTAssertEqual(model.current[1]?.location, "https://acme.example/a")
        now += 1
        bridge.receive(request(9, "ui/open-link", ["url": "https://acme.example/b"]))
        XCTAssertNotNil(posted.last()?["result"])
        XCTAssertEqual(model.current[1]?.location, "https://acme.example/b")
    }

    func testSizeChangedUnchangedPublishesNothing() {
        let model = model()
        card(model, "toolu_01")
        let (bridge, _) = bridge(model, "toolu_01")
        bridge.receive(json(["jsonrpc": "2.0", "method": "ui/notifications/size-changed", "params": ["width": 700, "height": 300]]))
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        bridge.receive(json(["jsonrpc": "2.0", "method": "ui/notifications/size-changed", "params": ["width": 700, "height": 300]]))
        XCTAssertEqual(changes, 0)
        watch.cancel()
    }

    // MARK: - three live cards, frozen cards, Reload

    func testOnlyThreeCardsStayLive() {
        let sent = Sent()
        let model = model(sent)
        for n in 1...4 { card(model, "toolu_0\(n)") }
        XCTAssertFalse(model.isLive("toolu_01", chat: 1))
        XCTAssertTrue(model.app(forToolUse: "toolu_01")?.frozen ?? false)
        for n in 2...4 { XCTAssertTrue(model.isLive("toolu_0\(n)", chat: 1), "toolu_0\(n)") }

        model.reloadApp("toolu_01", chat: 1)
        guard case .appReload(let reload)? = sent.frames.last else { return XCTFail("no app.reload") }
        XCTAssertEqual(reload.toolUseId, "toolu_01")
        model.apply(open("toolu_01", requestId: reload.id))
        XCTAssertTrue(model.isLive("toolu_01", chat: 1))
        XCTAssertFalse(model.isLive("toolu_02", chat: 1))
        XCTAssertTrue(model.app(forToolUse: "toolu_02")?.frozen ?? false)
        XCTAssertTrue(model.isLive("toolu_03", chat: 1))
        XCTAssertTrue(model.isLive("toolu_04", chat: 1))
    }

    func testRestoredCardsAreFrozenWithReload() throws {
        let sent = Sent()
        let model = model(sent)
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            started("toolu_01"), finished("toolu_01"), open("toolu_01", html: nil), result("toolu_01"),
        ], truncated: false)))
        let state = try XCTUnwrap(model.app(forToolUse: "toolu_01"))
        XCTAssertTrue(state.frozen)
        XCTAssertFalse(model.isLive("toolu_01", chat: 1))
        let shown = AppCardPresentation(state: state, hasImage: false)
        XCTAssertEqual(shown.placeholder, "Acme Tracker · Reload to show it again")
        XCTAssertTrue(shown.buttons.contains("Reload"))
        model.reloadApp("toolu_01", chat: 1)
        guard case .appReload(let reload)? = sent.frames.last else { return XCTFail("no app.reload") }
        XCTAssertEqual(reload.chat, 1)
        XCTAssertNotNil(reload.id)
    }

    // MARK: - the viewer copy

    func testOpenInViewerAndFullscreen() throws {
        let model = model()
        card(model, "toolu_01")
        model.openAppInViewer("toolu_01", chat: 1)
        XCTAssertEqual(model.viewerApp[1], "toolu_01")
        XCTAssertTrue(model.isViewerShown(for: 1))
        XCTAssertNotNil(model.app(forToolUse: "toolu_01"), "the card stays")
        XCTAssertTrue(model.isLive("toolu_01", chat: 1))

        // A file shown afterwards takes the viewer back.
        model.openArtifact(file: "/tmp/notes.md", in: 1)
        XCTAssertNil(model.viewerApp[1])

        // The page asks for fullscreen: the same, and it hears the mode it got.
        let (bridge, posted) = bridge(model, "toolu_01")
        bridge.receive(request(5, "ui/request-display-mode", ["mode": "fullscreen"]))
        XCTAssertEqual(model.viewerApp[1], "toolu_01")
        XCTAssertEqual(posted.last()?["id"], .int(5))
        XCTAssertEqual(posted.last()?["result"]?["mode"], .string("fullscreen"))

        // The viewer copy asking for inline closes it.
        let (viewer, viewerPosted) = self.bridge(model, "toolu_01", placement: .viewer)
        viewer.receive(request(6, "ui/request-display-mode", ["mode": "inline"]))
        XCTAssertNil(model.viewerApp[1])
        XCTAssertEqual(viewerPosted.last()?["result"]?["mode"], .string("inline"))
    }

    func testCardAccessibility() throws {
        let model = model()
        card(model, "toolu_01")
        let state = try XCTUnwrap(model.app(forToolUse: "toolu_01"))
        let live = AppCardPresentation(state: state, hasImage: false)
        XCTAssertEqual(live.accessibilityLabel, "Acme Tracker app, show_project")
        XCTAssertEqual(live.title, "Acme Tracker")
        XCTAssertEqual(live.subtitle, "· show_project")
        XCTAssertEqual(live.buttons, ["Open in viewer"])
        var frozen = state
        frozen.frozen = true
        XCTAssertEqual(AppCardPresentation(state: frozen, hasImage: true).buttons, ["Reload", "Open in viewer"])

        // The header draws these as `Button`s (AppHeaderButton), labelled with their titles;
        // SwiftUI builds no accessibility tree without an assistive client, so the
        // drawn tree is not walked here.
    }

    // MARK: - hosted: the page itself

    /// A page that answers its own `ui/initialize`, says `initialized`, and
    /// keeps everything it hears with whether `initialized` had gone yet.
    private static let recordingPage = """
        <!doctype html><html><head><meta charset=utf-8><title>Acme</title></head><body><main>Acme launch</main>
        <script>
        window.heard = []; var initialized = false;
        window.addEventListener("message", function (e) {
          window.heard.push({ initialized: initialized, data: e.data, sourceIsWindow: e.source === window });
          if (e.data && e.data.id === 1 && e.data.result) {
            initialized = true;
            window.parent.postMessage({ jsonrpc: "2.0", method: "ui/notifications/initialized", params: {} }, "*");
          }
        });
        window.parent.postMessage({ jsonrpc: "2.0", id: 1, method: "ui/initialize",
          params: { appInfo: { name: "acme", version: "1" }, appCapabilities: {}, protocolVersion: "2026-01-26" } }, "*");
        </script></body></html>
        """

    private func heard(_ view: WKWebView) async throws -> [[String: Any]] {
        let text = try await view.evaluateJavaScript("JSON.stringify(window.heard || [])") as? String ?? "[]"
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
    }

    private func methods(_ heard: [[String: Any]]) -> [String] {
        heard.compactMap { ($0["data"] as? [String: Any])?["method"] as? String }
    }

    func testInitializeThenInputThenResult() async throws {
        let model = model()
        card(model, "toolu_01", html: Self.recordingPage)
        let view = try hosted(model, "toolu_01")
        let gotInput = try await wait { methods(try await heard(view)).contains(MCPAppMethods.toolInput) }
        let soFar = try await heard(view)
        XCTAssertTrue(gotInput, "the page never got its input: \(soFar)")
        var all = try await heard(view)
        // The initialize answer came first, as a reply; nothing else before initialized.
        let early = all.filter { ($0["initialized"] as? Bool) == false }
        XCTAssertEqual(early.count, 1, "\(early)")
        XCTAssertNotNil((early.first?["data"] as? [String: Any])?["result"])
        XCTAssertTrue(all.allSatisfy { ($0["sourceIsWindow"] as? Bool) == true })
        let input = all.first { (($0["data"] as? [String: Any])?["method"] as? String) == MCPAppMethods.toolInput }
        let arguments = ((input?["data"] as? [String: Any])?["params"] as? [String: Any])?["arguments"] as? [String: Any]
        XCTAssertEqual(arguments?["project"] as? String, "Acme launch")
        XCTAssertFalse(methods(all).contains(MCPAppMethods.toolResult))

        model.apply(finished("toolu_01"))
        model.apply(result("toolu_01"))
        let gotResult = try await wait { methods(try await heard(view)).contains(MCPAppMethods.toolResult) }
        XCTAssertTrue(gotResult)
        all = try await heard(view)
        let delivered = all.first { (($0["data"] as? [String: Any])?["method"] as? String) == MCPAppMethods.toolResult }
        let params = (delivered?["data"] as? [String: Any])?["params"] as? [String: Any]
        XCTAssertEqual((params?["structuredContent"] as? [String: Any])?["done"] as? Int, 3)
    }

    func testNavigationIsBlocked() async throws {
        let model = model()
        card(model, "toolu_01", html: "<!doctype html><title>Acme</title><body>Acme</body>")
        let view = try hosted(model, "toolu_01")
        let loaded = try await wait { (try? await view.evaluateJavaScript("document.title") as? String) == "Acme" }
        XCTAssertTrue(loaded)
        let before = view.url
        XCTAssertEqual(before?.absoluteString, "mcpapp-acme-tracker://app/index.html")
        _ = try? await view.evaluateJavaScript("location = 'https://acme.example'; 1")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(view.url, before)
        let title = try await view.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "Acme")
    }

    func testCSPHeaderIsEnforced() async throws {
        let model = model()
        let page = """
            <!doctype html><title>Acme</title><script>
            try { eval("1"); window.evalRan = "yes" } catch (e) { window.evalRan = "no" }
            </script>
            """
        card(model, "toolu_01", html: page)
        let view = try hosted(model, "toolu_01")
        let ran = try await wait { (try? await view.evaluateJavaScript("window.evalRan") as? String) != nil }
        XCTAssertTrue(ran)
        let result = try await view.evaluateJavaScript("window.evalRan") as? String
        XCTAssertEqual(result, "no", "the default policy has no 'unsafe-eval'")
    }
}
