import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - MarkdownPage

/// Builds the HTML page the viewer shows for a markdown file: the bundled
/// `viewer.html` with the stylesheet and the vendored renderer inlined and
/// the markdown source embedded as a JSON string that `marked.parse` turns
/// into HTML in the page. Pure: reads bundle resources, touches no web view.
enum MarkdownPage {
    enum Error: Swift.Error, CustomStringConvertible {
        case missingResource(String)

        var description: String {
            switch self {
            case .missingResource(let name): "the app's resource \(name) is missing"
            }
        }
    }

    /// The page for `source`, titled `title`. Front matter at the top is
    /// taken out and drawn as the Properties block (v0.11, item 68); only
    /// the body reaches the renderer. At a text scale other than 100% the
    /// body's 15px (viewer.css) is multiplied by it (v0.15 §3).
    static func html(source: String, title: String, hiding: Set<String> = [], scale: CGFloat = 1) throws -> String {
        let template = try resource("viewer.html")
        let css = try resource("viewer.css")
        let marked = try resource("marked.min.js")
        let split = FrontMatter.split(source)
        // The block goes in first, its braces as entities, so a value that
        // reads `{{SOURCE}}` is not taken for the next placeholder.
        let shownProperties = split.frontMatter?.hiding(hiding)
        let properties = ((shownProperties?.properties.isEmpty == false ? shownProperties?.html() : nil) ?? "").replacingOccurrences(of: "{", with: "&#123;")
        return template
            .replacingOccurrences(of: "{{PROPERTIES}}", with: properties)
            .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(title))
            .replacingOccurrences(of: "{{CSS}}", with: css + scaleRule(scale))
            .replacingOccurrences(of: "{{MARKED}}", with: marked)
            .replacingOccurrences(of: "{{SOURCE}}", with: jsString(split.body))
    }

    /// The rule that scales the page's text, after the stylesheet so it
    /// wins; nothing at 100%.
    static func scaleRule(_ scale: CGFloat) -> String {
        guard scale != 1 else { return "" }
        return "\nbody { font-size: calc(15px * \(Self.scaleText(scale))); }\n"
    }

    /// `1.15`, not `1.1499999999999999`.
    private static func scaleText(_ scale: CGFloat) -> String {
        let rounded = (Double(scale) * 100).rounded() / 100
        return String(format: "%g", rounded)
    }

    /// The markdown as a JavaScript string literal. JSON encoding handles
    /// quotes, newlines and control characters; `</` is split so no closing
    /// tag inside the source can end the page's script block, and U+2028 /
    /// U+2029 are escaped because JSON allows them raw and JavaScript
    /// source (in older engines) does not.
    static func jsString(_ source: String) -> String {
        let data = (try? JSONEncoder().encode(source)) ?? Data("\"\"".utf8)
        let literal = String(decoding: data, as: UTF8.self)
        return literal
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func resource(_ name: String) throws -> String {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
            let url = AppResources.url(forResource: parts[0], withExtension: parts[1]),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw Error.missingResource(name) }
        return text
    }
}

// MARK: - RenderedPageHandler

/// Serves the viewer's pages to the web view under a private URL scheme,
/// `portico-view://<render>/`: a rendered markdown page (at `/`), or an
/// HTML file (at `/<its name>`), and the files under its folder (relative
/// images, CSS, scripts). A markdown page is not on disk, so `loadFileURL`
/// cannot show it, and WebKit's read grant for a file base URL on
/// `loadHTMLString` proved inconsistent. An HTML file comes through here
/// too (v0.12): under a file URL WebKit hides a script's uncaught error
/// as "Script error." (an opaque origin); here the page has an origin of
/// its own and the agent hears the real message.
///
/// A served page can read, by `fetch`, any file under its own folder; no
/// further. Symlinks are resolved before that check (a link inside the
/// folder to a file outside is refused), and dot-files and anything in a
/// dot-folder (`.git`, `.env`) are never served. An opened HTML file that
/// is itself a link is served from the folder it really lives in.
final class RenderedPageHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "portico-view"

    struct Render {
        /// The rendered page served at `/`; `nil` for an HTML file, which
        /// is served from the folder like everything else.
        let page: Data?
        let root: URL
        /// The HTML file's own name, served even when it starts with a dot.
        let entry: String?
        /// The Markdown file a rendered page was made from (v0.14), so a
        /// mark on it keeps its file across re-renders and Back.
        var source: URL? = nil
        /// The front-matter keys that page hid, kept for a re-render.
        var hiding: Set<String> = []
    }

    private var renders: [String: Render] = [:]

    /// Register a page whose relative references resolve under `root`
    /// (a directory). Returns the URL to load.
    func register(page: String, root: URL, source: URL? = nil, hiding: Set<String> = []) -> URL {
        let id = UUID().uuidString.lowercased()
        renders[id] = Render(
            page: Data(page.utf8), root: Self.resolved(root), entry: nil, source: source.map(Self.resolved), hiding: hiding)
        return URL(string: "\(Self.scheme)://\(id)/")!
    }

    /// Register an HTML file, served from its folder. Returns the URL to load.
    func register(file: URL) -> URL {
        let id = UUID().uuidString.lowercased()
        // An opened file that is itself a link is served from where it really is.
        let file = Self.resolved(file)
        let name = file.lastPathComponent
        renders[id] = Render(page: nil, root: file.deletingLastPathComponent(), entry: name)
        return URL(string: "\(Self.scheme)://\(id)/")!.appendingPathComponent(name)
    }

    /// The file a rendered URL stands for (v0.14): for an HTML file (or a
    /// file beside it) the root plus the path; `nil` for a rendered
    /// Markdown page (see `source(for:)`) and for anything not served here.
    func file(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, let host = url.host, let render = renders[host] else { return nil }
        if render.page != nil, Self.isRenderedPage(url.path) { return nil }
        return Self.file(url.path, in: render)
    }

    /// The Markdown file a rendered page's URL was made from, if any.
    func source(for url: URL) -> URL? {
        guard url.scheme == Self.scheme, let host = url.host, let render = renders[host],
              render.page != nil, Self.isRenderedPage(url.path) else { return nil }
        return render.source
    }

    /// The front-matter keys a rendered page's URL hid when first shown.
    func hiding(for url: URL) -> Set<String> {
        guard url.scheme == Self.scheme, let host = url.host else { return [] }
        return renders[host]?.hiding ?? []
    }

    private static func isRenderedPage(_ path: String) -> Bool {
        path.isEmpty || path == "/" || path == "/index.html"
    }

    func forget(_ url: URL) {
        if let host = url.host { renders[host] = nil }
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The file `path` names under `render`'s root, or `nil` when it is
    /// outside it (after symlinks) or is or lies in a dot-file or dot-folder.
    static func file(_ path: String, in render: Render) -> URL? {
        let relative = String(path.drop { $0 == "/" })
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.contains(where: { $0.hasPrefix(".") }), relative != render.entry { return nil }
        let file = resolved(render.root.appendingPathComponent(relative))
        // A root of `/` already ends in the separator.
        let prefix = render.root.path.hasSuffix("/") ? render.root.path : render.root.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        // The resolved path must not land in a dot-folder either (a link to `.git/config`).
        let inside = file.path.dropFirst(prefix.count).split(separator: "/")
        if inside.contains(where: { $0.hasPrefix(".") }), String(inside.joined(separator: "/")) != render.entry { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://missing/")!
        guard let host = url.host, let render = renders[host] else {
            return respond(task, url: url, status: 404, type: "text/plain", body: Data("no such page".utf8))
        }
        let path = url.path
        if let page = render.page, Self.isRenderedPage(path) {
            return respond(task, url: url, status: 200, type: "text/html; charset=utf-8", body: page)
        }
        guard let file = Self.file(path, in: render), let body = try? Data(contentsOf: file) else {
            return respond(task, url: url, status: 404, type: "text/plain", body: Data("not found".utf8))
        }
        respond(task, url: url, status: 200, type: Self.contentType(of: file, body: body), body: body)
    }

    /// The `Content-Type` for a served file. HTML with no charset of its
    /// own near the top is UTF-8 (WebKit would otherwise guess Latin-1).
    static func contentType(of file: URL, body: Data) -> String {
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard type == "text/html" else { return type }
        let head = String(decoding: body.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("charset") ? type : "text/html; charset=utf-8"
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, type: String, body: Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": String(body.count)])!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

// MARK: - WebPane

extension EnvironmentValues {
    /// Set by the open space's viewer: a new value re-reads the same file
    /// in place, keeping the scroll position (the file changed on disk).
    @Entry var webPaneRevision: String? = nil
    /// Where the file viewer's page has gone, for its header (v0.13).
    @Entry var viewerPageAddress: ViewerPageAddress? = nil
}

/// A `WKWebView` for the three web-rendered kinds: a markdown file (the
/// rendered page, with the file's directory as the root its relative
/// images resolve under), an HTML file (served from its directory by the
/// same handler) and a URL (a local dev server, usually).
/// The outside site the viewer's page has gone to, when a link left the
/// file it opened (v0.13 decision 5, Pen AL4); `nil` while it shows what
/// it opened.
@MainActor
final class ViewerPageAddress: ObservableObject {
    @Published var outside: URL?

    /// `current` when it is a web page that is not what the viewer opened.
    static func outside(current: URL?, loaded: WebPane.Load?) -> URL? {
        guard let current, let scheme = current.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        // An address the viewer opened stays itself across its own pages and
        // redirects (figma.com to www.figma.com/login, a local dev server's
        // pages): outside means another site.
        if case .url(let opened) = loaded, site(opened) == site(current) { return nil }
        return current
    }

    private static func site(_ url: URL) -> String {
        var host = url.host(percentEncoded: false)?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    /// The address as the header shows it: host and path, no scheme or
    /// "www.", and the fragment when there is one, so a hash change shows
    /// (v0.15 §5.1).
    static func display(_ url: URL) -> String {
        var host = url.host(percentEncoded: false) ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path(percentEncoded: false)
        let fragment = url.fragment(percentEncoded: false).map { "#" + $0 } ?? ""
        return (path.isEmpty || path == "/" ? host : host + path) + fragment
    }

    /// AL4: the note beside an outside site's address, as the act rule
    /// has it (the Work viewer and a space say the same).
    static func note(for url: URL, actHosts: [String]) -> String {
        ViewerAgent.canAct(url: url, actHosts: actHosts) ? "outside site" : "outside site · look and scroll only"
    }
}

struct WebPane: NSViewRepresentable {
    enum Load: Equatable {
        case markdown(URL, hiding: Set<String> = [])
        case html(URL)
        case url(URL)

        /// How the viewer loads `shown`, when it draws as a web page:
        /// Markdown, HTML and URLs; `nil` for the other kinds.
        init?(_ shown: ArtifactPresentation) {
            switch shown.media {
            case .markdown: guard let file = shown.fileURL else { return nil }; self = .markdown(file, hiding: shown.hiddenFrontMatterKeys)
            case .html: guard let file = shown.fileURL else { return nil }; self = .html(file)
            case .url: guard let url = shown.externalURL else { return nil }; self = .url(url)
            default: return nil
            }
        }
    }

    let load: Load

    /// The page the pane renders for `load` at a text scale: a Markdown
    /// file's page, scaled (v0.15 §3). An HTML file and a site are shown
    /// as they are, at their true size (`nil`: nothing is rendered).
    static func renderedPage(for load: Load, scale: CGFloat) -> String? {
        guard case .markdown(let file, let hiding) = load,
              let source = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        return try? MarkdownPage.html(source: source, title: file.lastPathComponent, hiding: hiding, scale: scale)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.agent = context.environment.viewerAgent
        context.coordinator.slot = context.environment.viewerSlot
        context.coordinator.address = context.environment.viewerPageAddress
        context.coordinator.scale = context.environment.textScale
        let view = context.coordinator.makeWebView()
        context.coordinator.apply(load, revision: context.environment.webPaneRevision, to: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(
            load, revision: context.environment.webPaneRevision, scale: context.environment.textScale, to: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.agent?.detach(view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// The agent that may act in this pane (v0.12): the viewer's panes
        /// have one, the document view's do not.
        var agent: ViewerAgent?
        /// Which of the viewer column's viewers the pane is in (Work's or
        /// the open space's); `nil`: the one on screen when it attaches.
        var slot: ViewerAgent.Slot?
        /// The file viewer's header address (v0.13); `nil` elsewhere.
        weak var address: ViewerPageAddress?
        private var loaded: Load?
        /// The load whose navigation failed (or whose file could not be
        /// read), until a retry or another load. It stays `loaded` too:
        /// SwiftUI re-evaluates the viewer on every text delta while a
        /// turn streams, and each `updateNSView` would otherwise ask for
        /// the same dead URL again, flickering between the attempt and the
        /// failure page. The failure page carries the one way to ask again.
        private(set) var failed: Load?
        /// What the open space's pane was last drawn for (`nil` elsewhere).
        private var revision: String?
        /// The text scale a Markdown page is rendered at (v0.15 §3).
        var scale: CGFloat = 1
        let handler = RenderedPageHandler()

        /// The link on the failure page that asks for the load again. It
        /// is under the pane's private scheme so nothing else can reach it,
        /// and the navigation delegate acts on it before any handler would.
        static let retryURL = URL(string: "\(RenderedPageHandler.scheme)://retry/")!

        /// The configuration a web view for this coordinator needs: the
        /// rendered-page scheme registered (it must be before the view exists).
        func configuration() -> WKWebViewConfiguration {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.setURLSchemeHandler(handler, forURLScheme: RenderedPageHandler.scheme)
            // The agent's script from document start, so page errors are
            // captured from load (spec §3.2).
            if agent != nil, let script = ViewerAgentScript.userScript() {
                configuration.userContentController.addUserScript(script)
            }
            return configuration
        }

        /// A web view wired to this coordinator: navigation failures
        /// reported into the pane, the retry link honoured.
        func makeWebView() -> WKWebView {
            attach(WKWebView(frame: .zero, configuration: configuration()))
        }

        /// A page or site that sets no background shows on white, as a
        /// browser shows it (v0.13 decision 4); rendered markdown is styled
        /// by the app and lets the pane show through.
        static func drawsBackground(for load: Load) -> Bool {
            if case .markdown = load { return false }
            return true
        }

        /// Watches the view's URL: a hash change or `history.pushState`
        /// moves it without a commit or a finish (v0.15 §5.1).
        private var urlObservation: NSKeyValueObservation?

        /// Wire a view made from `configuration()` to this coordinator.
        @discardableResult
        func attach(_ view: WKWebView) -> WKWebView {
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            urlObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
                // WebKit reports it on the main thread.
                MainActor.assumeIsolated { self?.noteAddress(of: view) }
            }
            return view
        }

        /// Show `load` unless it is what the view already shows (or showed
        /// and failed to): a SwiftUI redraw is not a request to try again.
        /// A new `revision` for the same load (an open space whose file
        /// changed) reads it again, keeping where the reader had scrolled.
        /// A new text `scale` re-renders a Markdown page the same way, in
        /// place; an HTML file or a site is not touched.
        func apply(_ load: Load, revision: String? = nil, scale: CGFloat? = nil, to view: WKWebView) {
            var rescaled = false
            if let scale, scale != self.scale {
                self.scale = scale
                if case .markdown = load { rescaled = true }
            }
            let reread = load == loaded && failed == nil
                && ((revision != nil && revision != self.revision) || rescaled)
            self.revision = revision
            if reread { return rereadKeepingScroll(load, in: view) }
            guard load != loaded else { return }
            start(load, in: view)
        }

        /// Where the page was scrolled before a re-read, put back once the
        /// re-read page has loaded.
        private var pendingScroll: Double?

        private func rereadKeepingScroll(_ load: Load, in view: WKWebView) {
            view.evaluateJavaScript(Self.readScroll) { [weak self, weak view] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.loaded == load else { return }
                    // The pane may have gone to another Markdown page (a
                    // mark's page, Back): that is the page to draw again,
                    // with its own scroll, not the file first loaded.
                    if case .markdown(let file, _) = load, let url = view.url,
                       let shown = self.handler.source(for: url),
                       shown != file.standardizedFileURL.resolvingSymlinksInPath(),
                       let again = self.renderedURL(for: shown, hiding: self.handler.hiding(for: url)) {
                        self.pendingScroll = (value as? NSNumber)?.doubleValue
                        // Replace the entry, not push one: Back must not
                        // step through the same page twice.
                        view.evaluateJavaScript("location.replace('\(again.absoluteString)')")
                        return
                    }
                    self.start(load, in: view, scroll: (value as? NSNumber)?.doubleValue)
                }
            }
        }

        static let readScroll = "(document.scrollingElement || document.documentElement).scrollTop"

        /// Put the scroll back, trying for a moment while late content (an
        /// image decoding) is still making the page tall enough.
        static func restoreScroll(_ y: Double) -> String {
            """
            (function (y) {
              var n = 0;
              function go() {
                var s = document.scrollingElement || document.documentElement;
                s.scrollTop = y;
                if (Math.abs(s.scrollTop - y) > 1 && n++ < 60) setTimeout(go, 16);
              }
              go();
            })(\(y)); true
            """
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            noteAddress(of: webView)
        }

        private func noteAddress(of webView: WKWebView) {
            let outside = ViewerPageAddress.outside(current: webView.url, loaded: loaded)
            if address?.outside != outside { address?.outside = outside }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            noteAddress(of: webView)
            // Marks are drawn again on every load. WebKit calls this on
            // Back too, from its back-forward cache or not (v0.14).
            agent?.pageLoaded(webView)
            guard let y = pendingScroll else { return }
            pendingScroll = nil
            webView.evaluateJavaScript(Self.restoreScroll(y))
        }

        /// Ask for the current load again: the failure page's link.
        func retry(in view: WKWebView) {
            guard let load = loaded else { return }
            start(load, in: view)
        }

        private func start(_ load: Load, in view: WKWebView, scroll: Double? = nil) {
            loaded = load
            failed = nil
            pendingScroll = scroll
            view.setValue(Self.drawsBackground(for: load), forKey: "drawsBackground")
            agent?.attach(view, showing: load, coordinator: self, slot: slot)
            // Earlier pages stay registered for the coordinator's life: the
            // web view's Back (and the agent's viewer_back) can return to
            // them across an artifact switch.
            switch load {
            case .markdown(let file, let hiding):
                do {
                    let source = try String(contentsOf: file, encoding: .utf8)
                    let page = try MarkdownPage.html(source: source, title: file.lastPathComponent, hiding: hiding, scale: scale)
                    let url = handler.register(page: page, root: file.deletingLastPathComponent(), source: file, hiding: hiding)
                    view.load(URLRequest(url: url))
                } catch {
                    showFailure("Cannot read \(file.path): \(error)", in: view)
                }
            case .html(let file):
                // Served by the scheme handler from its folder, so its
                // scripts' errors keep their message (v0.12).
                guard FileManager.default.isReadableFile(atPath: file.path) else {
                    return showFailure("Cannot read \(file.path)", in: view)
                }
                let url = handler.register(file: file)
                view.load(URLRequest(url: url))
            case .url(let url):
                view.load(URLRequest(url: url))
            }
        }

        /// A URL for `file` served by this pane, to load in place so Back
        /// returns (v0.14, going to a mark on another page): an HTML file
        /// from its folder, a Markdown file rendered; `nil` otherwise.
        /// `hiding`: the front-matter keys the page hid when first shown.
        func renderedURL(for file: URL, hiding: Set<String> = []) -> URL? {
            switch file.pathExtension.lowercased() {
            case "html", "htm":
                guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
                return handler.register(file: file)
            case "md", "markdown":
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                      let page = try? MarkdownPage.html(source: source, title: file.lastPathComponent, hiding: hiding, scale: scale)
                else { return nil }
                return handler.register(page: page, root: file.deletingLastPathComponent(), source: file, hiding: hiding)
            default:
                return nil
            }
        }

        private func showFailure(_ message: String, in view: WKWebView) {
            failed = loaded
            pendingScroll = nil
            view.loadHTMLString(Self.errorPage(message), baseURL: nil)
        }

        /// A failed navigation (the dev server went away, a file vanished)
        /// shows why instead of a blank pane, with a link to try again.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Swift.Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            showFailure(error.localizedDescription, in: webView)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.request.url == Self.retryURL {
                decisionHandler(.cancel)
                retry(in: webView)
                return
            }
            decisionHandler(.allow)
        }

        static func errorPage(_ message: String) -> String {
            """
                <!doctype html><html><head><meta charset="utf-8"><style>
                body{font:14px -apple-system,sans-serif;color:#888;padding:24px;margin:0}
                a{color:#888}
                </style></head><body><p>\(MarkdownPage.escapeHTML(message))</p>
                <p><a href="\(retryURL.absoluteString)">Try again</a></p></body></html>
                """
        }
    }
}
