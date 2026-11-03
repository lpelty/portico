import AppKit
import SwiftUI
import WebKit
import os

/// One MCP app's page (spec §2.3.5): a `WKWebView` with a non-persistent
/// data store, its own origin (`mcpapp-<server>://app/index.html`), the
/// resource's CSP as a response header, no navigation of its own, camera
/// and microphone refused, and one script message handler (`mcpapp`).
/// Nothing is shared with Portico's other web views. Kept by the model
/// (`AppModel.appPage`), so a card scrolled away and back keeps its page.
@MainActor
final class MCPAppPage: NSObject {
    let webView: WKWebView
    let bridge: MCPAppBridge
    /// The card's page generation it was made for (a Reload makes a new one).
    let generation: Int
    let pageURL: URL
    private let handler: MCPAppSchemeHandler
    private let messages: MCPAppMessageProxy
    private let allowsFrames: Bool
    private var loadedOnce = false
    private var appearance: NSKeyValueObservation?
    private var disposed = false

    private static let log = Logger(subsystem: "Portico", category: "mcp-apps")

    /// The shim (`app-bridge.js`), read once from the app's resources.
    static let shim: String? = AppResources.bundle.url(forResource: "app-bridge", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    init(state: AppState, html: String, bridge: MCPAppBridge, appVersion: String) {
        self.bridge = bridge
        generation = state.generation
        pageURL = MCPAppBridge.pageURL(forServer: state.server)
        handler = MCPAppSchemeHandler(html: html, policy: MCPAppBridge.contentSecurityPolicy(state.csp))
        messages = MCPAppMessageProxy()
        if case .array(let frames)? = state.csp?["frameDomains"] { allowsFrames = !frames.isEmpty } else { allowsFrames = false }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        if let shim = Self.shim {
            content.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            Self.log.error("app-bridge.js is missing from the app's resources")
        }
        content.add(messages, contentWorld: .page, name: "mcpapp")
        configuration.userContentController = content
        configuration.setURLSchemeHandler(handler, forURLScheme: MCPAppBridge.scheme(forServer: state.server))
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.applicationNameForUserAgent = "Portico/\(appVersion)"
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: AppState.initialHeight), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityLabel("\(state.serverTitle) app page")
        messages.bridge = bridge
        bridge.post = { [weak self] text in self?.deliver(text) }
        appearance = webView.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.bridge.hostContextChanged(["theme": .string(MCPAppBridge.theme())]) }
        }
        webView.load(URLRequest(url: pageURL))
    }

    /// One JSON text to the page, as a `message` event from `window`.
    private func deliver(_ text: String) {
        guard !disposed else { return }
        webView.callAsyncJavaScript(
            "window.__porticoDeliver && window.__porticoDeliver(m)", arguments: ["m": text], in: nil, in: .page
        ) { _ in }
    }

    /// Freeze: the page's last look as an image, then the teardown (at most
    /// 0.5 s), then `done`. The page is disposed by the caller.
    func freeze(done: @escaping (NSImage?) -> Void) {
        guard !disposed else { return done(nil) }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            Task { @MainActor in
                guard let self else { return done(image) }
                self.bridge.teardown(reason: "The card was frozen") { done(image) }
            }
        }
    }

    /// Close: the teardown (at most 0.5 s), then `done`.
    func close(done: @escaping () -> Void) {
        guard !disposed else { return done() }
        bridge.teardown(reason: "The viewer closed", done: done)
    }

    /// The page goes: no more messages either way.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        bridge.detach()
        messages.bridge = nil
        appearance = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension MCPAppPage: WKNavigationDelegate, WKUIDelegate {
    /// The first load of the page's own address, and frames the resource
    /// declared (CSP decides which), go; every other navigation is
    /// cancelled. A link the person follows opens in the viewer instead.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if mainFrame, !loadedOnce, action.request.url == pageURL {
            loadedOnce = true
            return .allow
        }
        // An in-page anchor (`#section`) moves within the page; it loads nothing.
        if mainFrame, loadedOnce, let url = action.request.url, url.fragment != nil,
           var base = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            base.fragment = nil
            if base.url == pageURL { return .allow }
        }
        if !mainFrame, allowsFrames { return .allow }
        if mainFrame, action.navigationType == .linkActivated, Self.isWeb(action.request.url), let url = action.request.url {
            bridge.model?.openLink(url.absoluteString, chat: bridge.chat)
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if action.navigationType == .linkActivated, Self.isWeb(action.request.url), let url = action.request.url {
            bridge.model?.openLink(url.absoluteString, chat: bridge.chat)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }
}

/// The page's one script message handler, holding its bridge weakly (the
/// content controller keeps its handlers strongly).
final class MCPAppMessageProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: MCPAppBridge?

    @MainActor
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let text: String
        if let string = message.body as? String {
            text = string
        } else if JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = "null"
        }
        bridge?.receive(text)
    }
}

/// Serves the page at `index.html` under its scheme, with its CSP; nothing else.
final class MCPAppSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: Data
    private let policy: String

    init(html: String, policy: String) {
        self.html = Data(html.utf8)
        self.policy = policy
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let found = url.host == "app" && url.path == "/index.html"
        let body = found ? html : Data("not found".utf8)
        var headers = [
            "Content-Type": found ? "text/html; charset=utf-8" : "text/plain",
            "Content-Length": String(body.count),
            "Cache-Control": "no-store",
        ]
        if found { headers["Content-Security-Policy"] = policy }
        let response = HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A card's (or the viewer's) page, drawn from the model's `MCPAppPage`.
struct MCPAppView: NSViewRepresentable {
    let toolUseId: String
    let placement: MCPAppBridge.Placement
    let model: AppModel

    func makeNSView(context: Context) -> MCPAppContainer {
        let container = MCPAppContainer()
        container.show(model.appPage(toolUseId, placement: placement))
        return container
    }

    func updateNSView(_ container: MCPAppContainer, context: Context) {
        container.show(model.appPage(toolUseId, placement: placement))
    }
}

/// Holds one page's web view, filling it, and tells the page how wide it is.
final class MCPAppContainer: NSView {
    private weak var page: MCPAppPage?

    @MainActor
    func show(_ next: MCPAppPage?) {
        guard next !== page || next?.webView.superview !== self else { return }
        page?.webView.removeFromSuperview()
        page = next
        guard let next else { return }
        next.webView.removeFromSuperview()
        next.webView.frame = bounds
        next.webView.autoresizingMask = [.width, .height]
        addSubview(next.webView)
        noteSize()
    }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { noteSize() }
    }

    @MainActor
    private func noteSize() {
        guard let page, bounds.width > 0 else { return }
        page.bridge.containerWidth = bounds.width
        page.bridge.containerHeight = bounds.height
    }
}
