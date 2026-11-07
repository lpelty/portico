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
    /// body's 15px (viewer.css) is multiplied by it (v0.15 §3). The
    /// Properties block opens unfolded only when `propertiesOpen` (v0.17 §3.7).
    static func html(source: String, title: String, hiding: Set<String> = [], scale: CGFloat = 1, propertiesOpen: Bool = false) throws -> String {
        let template = try resource("viewer.html")
        let css = try resource("viewer.css")
        let marked = try resource("marked.min.js")
        let split = FrontMatter.split(source)
        // The block goes in first, its braces as entities, so a value that
        // reads `{{SOURCE}}` is not taken for the next placeholder.
        let shownProperties = split.frontMatter?.hiding(hiding)
        // Present but unreadable: the words in its place (v0.20 §2.3), even with nothing to show.
        let drawn = shownProperties.flatMap { $0.unreadable || !$0.properties.isEmpty ? $0.html(open: propertiesOpen) : nil }
        let properties = (drawn ?? "").replacingOccurrences(of: "{", with: "&#123;")
        let comments = try resource("viewer-comments.js")
        return template
            .replacingOccurrences(of: "{{PROPERTIES}}", with: properties)
            .replacingOccurrences(of: "{{BODY_LINE}}", with: String(bodyLine(source)))
            .replacingOccurrences(of: "{{COMMENTS_CSS}}", with: CommentsTheme.css())
            .replacingOccurrences(of: "{{COMMENTS_JS}}", with: comments)
            .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(title))
            .replacingOccurrences(of: "{{CSS}}", with: css + scaleRule(scale))
            .replacingOccurrences(of: "{{MARKED}}", with: marked)
            .replacingOccurrences(of: "{{SOURCE}}", with: jsString(sentinelMarkers(source, body: split.body)))
    }

    /// v0.23: the body with each comment marker (outside code and thread
    /// blocks) as private-use sentinels — open `U+E000 id U+E001`, close
    /// `U+E002 id U+E001` — so the renderer sees plain text (a marker at a
    /// line's start would otherwise open an HTML block). The page turns them
    /// back into markers after rendering. No line breaks change, so the
    /// blocks' source lines stay right.
    static func sentinelMarkers(_ source: String, body: String) -> String {
        let shift = source.utf16.count - body.utf16.count
        var starts: [Int: (end: Int, id: String, closing: Bool)] = [:]
        for m in CommentFormat.liveMarkers(source) where m.range.lowerBound >= shift {
            starts[m.range.lowerBound - shift] = (m.range.upperBound - shift, m.id, m.closing)
        }
        // The file's own private-use sentinels are escaped first (U+E003 and a
        // digit), so its text always survives; the page puts them back.
        let units = Array(body.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if let m = starts[i] {
                out.append(m.closing ? 0xE002 : 0xE000)
                out += Array(m.id.utf16)
                out.append(0xE001)
                i = m.end
                continue
            }
            let c = units[i]
            if c >= 0xE000, c <= 0xE003 {
                out += [0xE003, 0x30 + (c - 0xE000)]
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }


    /// How many source lines come before the body the renderer gets (the
    /// front matter's), so the page's block line numbers are the file's (v0.23).
    static func bodyLine(_ source: String) -> Int {
        let body = FrontMatter.split(source).body
        let prefix = source.utf16.count - body.utf16.count
        guard prefix > 0 else { return 0 }
        return source.utf16.prefix(prefix).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
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
    var webPaneRevision: String? {
        get { self[WebPaneRevisionKey.self] }
        set { self[WebPaneRevisionKey.self] = newValue }
    }
    /// Where the file viewer's page has gone, for its header (v0.13).
    var viewerPageAddress: ViewerPageAddress? {
        get { self[ViewerPageAddressKey.self] }
        set { self[ViewerPageAddressKey.self] = newValue }
    }
    /// Whether a Properties block is drawn unfolded (v0.17 §3.7): what the
    /// next page drawn uses; a change does not draw the shown page again.
    var propertiesOpen: Bool {
        get { self[PropertiesOpenKey.self] }
        set { self[PropertiesOpenKey.self] = newValue }
    }
    /// Remembers the person's toggle of a Properties block.
    var setPropertiesOpen: ((Bool) -> Void)? {
        get { self[SetPropertiesOpenKey.self] }
        set { self[SetPropertiesOpenKey.self] = newValue }
    }
    /// v0.22 (S1): told of a `space-action:` link the person activated in
    /// the pane; set only by the open space's viewer. Elsewhere such a link
    /// goes nowhere.
    var spaceActionLink: ((URL) -> Void)? {
        get { self[SpaceActionLinkKey.self] }
        set { self[SpaceActionLinkKey.self] = newValue }
    }
    /// v0.22 (S2): a fragment to scroll the page to once, keyed so a new
    /// request is told apart from one already done; set by the open space's viewer.
    var webPaneFragment: WebPane.FragmentRequest? {
        get { self[WebPaneFragmentKey.self] }
        set { self[WebPaneFragmentKey.self] = newValue }
    }
}

private struct SpaceActionLinkKey: EnvironmentKey {
    static var defaultValue: ((URL) -> Void)? { nil }
}
private struct WebPaneFragmentKey: EnvironmentKey {
    static var defaultValue: WebPane.FragmentRequest? { nil }
}

private struct WebPaneRevisionKey: EnvironmentKey {
    static var defaultValue: String? { nil }
}
private struct ViewerPageAddressKey: EnvironmentKey {
    static var defaultValue: ViewerPageAddress? { nil }
}
private struct PropertiesOpenKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}
private struct SetPropertiesOpenKey: EnvironmentKey {
    static var defaultValue: ((Bool) -> Void)? { nil }
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
    /// "www.", and the fragment when it reads as a route ("#/settings",
    /// "#!/inbox"), so an app's in-page navigation shows (v0.15 §5.1). A
    /// fragment carrying values (an OAuth `#access_token=…`) never shows.
    static func display(_ url: URL) -> String {
        var host = url.host(percentEncoded: false) ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // The port tells two local servers apart (localhost:3000, :8080).
        if let port = url.port { host += ":\(port)" }
        let path = url.path(percentEncoded: false)
        let base = path.isEmpty || path == "/" ? host : host + path
        guard let fragment = url.fragment(percentEncoded: false), isRoute(fragment) else { return base }
        return base + "#" + fragment
    }

    private static func isRoute(_ fragment: String) -> Bool {
        (fragment.hasPrefix("/") || fragment.hasPrefix("!")) && !fragment.contains("=") && !fragment.contains("&")
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

    /// v0.22 (S2): scroll to `fragment` once; `key` tells requests apart.
    struct FragmentRequest: Equatable {
        let key: String
        let fragment: String
    }

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
        context.coordinator.propertiesOpen = context.environment.propertiesOpen
        context.coordinator.onPropertiesToggle = context.environment.setPropertiesOpen
        context.coordinator.onSpaceAction = context.environment.spaceActionLink
        context.coordinator.comments = context.environment.viewerComments
        let view = context.coordinator.makeWebView()
        context.coordinator.apply(load, revision: context.environment.webPaneRevision, to: view)
        context.coordinator.scroll(to: context.environment.webPaneFragment, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.comments = context.environment.viewerComments
        context.coordinator.propertiesOpen = context.environment.propertiesOpen
        context.coordinator.onPropertiesToggle = context.environment.setPropertiesOpen
        context.coordinator.onSpaceAction = context.environment.spaceActionLink
        context.coordinator.apply(
            load, revision: context.environment.webPaneRevision, scale: context.environment.textScale, to: view)
        context.coordinator.scroll(to: context.environment.webPaneFragment, in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.agent?.detach(view)
        coordinator.detachAddress()
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
        /// What the pane was asked to show, set directly (tests).
        var loadedForTesting: Load? {
            get { loaded }
            set { loaded = newValue }
        }
        /// The load whose navigation failed (or whose file could not be
        /// read), until a retry or another load. It stays `loaded` too:
        /// SwiftUI re-evaluates the viewer on every text delta while a
        /// turn streams, and each `updateNSView` would otherwise ask for
        /// the same dead URL again, flickering between the attempt and the
        /// failure page. The failure page carries the one way to ask again.
        private(set) var failed: Load?
        /// The outside link whose navigation failed (the pane shows the
        /// failure page, whose own URL says nothing), until it loads or
        /// another load starts. The header names it and Retry asks for it
        /// (v0.16, candidate 18).
        private var failedURL: URL?
        /// Why the last load failed (the error's short description), while
        /// the failure page is up (v0.17: a show answers "Not loaded: …").
        private(set) var failure: String?
        /// The revision and text scale the shown file was last drawn at: a
        /// visit to an outside site holds re-reads back, and coming back to
        /// a file drawn for older ones reads it once (v0.16).
        private var readRevision: String?
        private var readScale: CGFloat = 1
        /// What the open space's pane was last drawn for (`nil` elsewhere).
        private var revision: String?
        /// The text scale a Markdown page is rendered at (v0.15 §3).
        var scale: CGFloat = 1
        /// Whether a Markdown page draws its Properties block unfolded
        /// (v0.17 §3.7): used for the next page drawn, never a redraw.
        var propertiesOpen = false
        /// Told the person's toggle of a Properties block on the page.
        var onPropertiesToggle: ((Bool) -> Void)?
        /// v0.22 (S1): told of a `space-action:` link activated in the page.
        var onSpaceAction: ((URL) -> Void)?
        /// v0.23: the file viewer's comments; the page's `comments` messages go to it.
        weak var comments: ViewerComments?
        /// v0.22 (S2): the last fragment request carried out, and one waiting
        /// for the page to finish loading.
        private var doneFragmentKey: String?
        private var pendingFragment: String?
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
            configuration.userContentController.add(PropertiesToggle(self), name: PropertiesToggle.name)
            configuration.userContentController.add(CommentsMessages(self), name: CommentsMessages.name)
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

        /// A dismantled pane stops watching and lets go of the header's
        /// address, so it cannot write into a viewer it no longer shows in.
        func detachAddress() {
            urlObservation?.invalidate()
            urlObservation = nil
            address = nil
        }

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
            let revised = revision != nil && revision != self.revision
            let reread = load == loaded && failed == nil && (revised || rescaled)
            self.revision = revision
            // A re-read would take a pane that is on an outside site back
            // to the file: the revision is noted, the person stays where
            // they went (v0.16, candidate 18).
            if reread && (address?.outside != nil || failedURL != nil) { return }
            if reread {
                readRevision = self.revision
                readScale = self.scale
                return rereadKeepingScroll(load, in: view, scaleOnly: !revised)
            }
            guard load != loaded else { return }
            start(load, in: view)
        }

        /// Where the page was scrolled before a re-read, put back once the
        /// re-read page has loaded.
        private var pendingScroll: Double?

        /// `scaleOnly`: only the text size changed (no new revision). Then
        /// only a rendered Markdown page the pane shows is drawn again; a
        /// page it went to from there (a linked HTML file, a site, a file
        /// served beside it) is left alone (v0.15 final review).
        private func rereadKeepingScroll(_ load: Load, in view: WKWebView, scaleOnly: Bool = false) {
            view.evaluateJavaScript(Self.readScroll) { [weak self, weak view] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let view, self.loaded == load else { return }
                    let shown = view.url.flatMap { self.handler.source(for: $0) }
                    if scaleOnly && shown == nil { return }
                    // The pane may have gone to another Markdown page (a
                    // mark's page, Back): that is the page to draw again,
                    // with its own scroll, not the file first loaded. A
                    // rescale of the page itself is drawn the same way.
                    if case .markdown(let file, _) = load, let url = view.url, let shown,
                       scaleOnly || shown != file.standardizedFileURL.resolvingSymlinksInPath(),
                       let again = self.renderedURL(for: shown, hiding: self.handler.hiding(for: url)) {
                        self.pendingScroll = (value as? NSNumber)?.doubleValue
                        // Replace the entry, not push one: Back must not
                        // step through the same page twice, or through
                        // copies of it at older sizes.
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
            // The failure page has no address of its own: while it is up,
            // the link that failed is the address.
            var current = webView.url
            if let failedURL {
                if current == nil || current?.absoluteString == "about:blank" { current = failedURL } else { self.failedURL = nil }
            }
            let outside = ViewerPageAddress.outside(current: current, loaded: loaded)
            if address?.outside != outside { address?.outside = outside }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A page other than the failure page (Back to the file, a
            // retry) leaves no failure behind.
            if let url = webView.url, url.absoluteString != "about:blank" { failure = nil }
            noteAddress(of: webView)
            // Marks are drawn again on every load. WebKit calls this on
            // Back too, from its back-forward cache or not (v0.14).
            agent?.pageLoaded(webView)
            rereadIfDrawnForOlder(in: webView)
            if let fragment = pendingFragment, isPage(webView.url) {
                // The fragment wins over a re-read's old scroll position.
                pendingFragment = nil
                pendingScroll = nil
                webView.evaluateJavaScript(Self.scrollToFragment(fragment))
                return
            }
            guard let y = pendingScroll else { return }
            pendingScroll = nil
            webView.evaluateJavaScript(Self.restoreScroll(y))
        }

        /// Back on the file after a visit outside, when its revision (or a
        /// Markdown page's text size) moved meanwhile: read it once.
        private func rereadIfDrawnForOlder(in view: WKWebView) {
            guard let load = loaded, failed == nil, failedURL == nil, address?.outside == nil,
                  let url = view.url, url.absoluteString != "about:blank"
            else { return }
            let revised = revision != readRevision
            var rescaled = false
            if case .markdown = load { rescaled = scale != readScale }
            guard revised || rescaled else { return }
            readRevision = revision
            readScale = scale
            rereadKeepingScroll(load, in: view, scaleOnly: !revised)
        }

        /// The pane is off what it was asked to show (v0.17): on its failure
        /// page, on a site a link went to, or on another local page a link
        /// went to (fragments aside).
        func isAway(in view: WKWebView) -> Bool {
            failure != nil || ViewerPageAddress.outside(current: view.url, loaded: loaded) != nil
                || isOnAnotherLocalPage(view.url)
        }

        /// `url` is a page this pane serves that is not the file it was asked
        /// to show. Compared by the file the URL stands for, not the URL
        /// itself, so a re-render of the same file (a new text size) is home.
        private func isOnAnotherLocalPage(_ url: URL?) -> Bool {
            guard let url, url.scheme == RenderedPageHandler.scheme, let loaded else { return false }
            switch loaded {
            case .markdown(let file, _):
                return handler.source(for: url) != file.standardizedFileURL.resolvingSymlinksInPath()
            case .html(let file):
                return handler.file(for: url) != file.standardizedFileURL.resolvingSymlinksInPath()
            case .url:
                return true
            }
        }

        /// Load what the pane was asked to show again: the agent showed it
        /// again while the pane was away from it (v0.17).
        func showAgain(in view: WKWebView) {
            guard let loaded else { return }
            start(loaded, in: view)
        }

        /// Ask for the current load again: the failure page's link.
        func retry(in view: WKWebView) {
            if let link = failedURL {
                failed = nil
                failure = nil
                pendingScroll = nil
                view.load(URLRequest(url: link))
                return
            }
            guard let load = loaded else { return }
            start(load, in: view)
        }

        private func start(_ load: Load, in view: WKWebView, scroll: Double? = nil) {
            loaded = load
            failed = nil
            failedURL = nil
            failure = nil
            readRevision = revision
            readScale = scale
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
                    let page = try MarkdownPage.html(source: source, title: file.lastPathComponent, hiding: hiding, scale: scale, propertiesOpen: propertiesOpen)
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
                      let page = try? MarkdownPage.html(source: source, title: file.lastPathComponent, hiding: hiding, scale: scale, propertiesOpen: propertiesOpen)
                else { return nil }
                return handler.register(page: page, root: file.deletingLastPathComponent(), source: file, hiding: hiding)
            default:
                return nil
            }
        }

        /// `link`: an outside page that failed. Then the file's own load did
        /// not fail (`failed` stays clear, so the space goes on refreshing
        /// once the person is back); the link is the address and Retry's target.
        private func showFailure(_ message: String, in view: WKWebView, link: URL? = nil) {
            failed = link == nil ? loaded : nil
            failedURL = link
            failure = message
            pendingScroll = nil
            if let link, address?.outside != link { address?.outside = link }
            view.loadHTMLString(Self.errorPage(message), baseURL: nil)
        }

        /// A failed navigation (the dev server went away, a file vanished)
        /// shows why instead of a blank pane, with a link to try again.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Swift.Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            // The link that failed, when it was an outside page (the
            // failure page replaces it, and Retry must ask for it).
            let link = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL).flatMap {
                ViewerPageAddress.outside(current: $0, loaded: loaded)
            }
            showFailure(error.localizedDescription, in: webView, link: link)
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
            // v0.22 (S1): a space-action link never loads; a click on one in
            // a space's page goes to the model, which checks it and the
            // gateway's `spaces.act`. One a script follows is not a click,
            // nor is one in a frame, on a site a link went to, or while the
            // viewer agent acts (its clicks never run the deployment's actions).
            if let url = navigationAction.request.url, url.scheme?.lowercased() == SpaceActionLink.scheme {
                decisionHandler(.cancel)
                let taken = Self.takesSpaceAction(
                    linkActivated: navigationAction.navigationType == .linkActivated,
                    targetIsMainFrame: navigationAction.targetFrame?.isMainFrame,
                    sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame,
                    showingOwnPage: Self.isSpaceFile(loaded, away: isAway(in: webView)),
                    agentActing: agent?.actingChat != nil)
                if taken, let onSpaceAction {
                    onSpaceAction(url)
                } else {
                    AppModel.spacesLog.notice("action link ignored: not the person's click in a space's own page")
                }
                return
            }
            decisionHandler(.allow)
        }

        /// v0.22: whether a `space-action:` navigation runs: a link click,
        /// from and into the main frame, while the pane shows the space's own
        /// page, and not while the viewer agent acts.
        static func takesSpaceAction(
            linkActivated: Bool, targetIsMainFrame: Bool?, sourceIsMainFrame: Bool, showingOwnPage: Bool, agentActing: Bool
        ) -> Bool {
            linkActivated && targetIsMainFrame == true && sourceIsMainFrame && showingOwnPage && !agentActing
        }

        /// The pane shows the file it was asked to (a space is a Markdown
        /// or HTML file), not a site, another file or its failure page.
        static func isSpaceFile(_ loaded: Load?, away: Bool) -> Bool {
            switch loaded {
            case .markdown, .html: return !away
            case .url, nil: return false
            }
        }

        /// v0.22 (S2): carry out `request` once: now when the page is in, else
        /// when it finishes loading.
        func scroll(to request: WebPane.FragmentRequest?, in view: WKWebView) {
            guard let request, request.key != doneFragmentKey else { return }
            doneFragmentKey = request.key
            if view.isLoading || !isPage(view.url) {
                pendingFragment = request.fragment
            } else {
                view.evaluateJavaScript(Self.scrollToFragment(request.fragment))
            }
        }

        /// A page has loaded (not the blank view a pane starts with).
        private func isPage(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.absoluteString != "about:blank"
        }

        /// Scroll the element with that id (or, failing that, that name) to
        /// the top. The fragment goes in as a JSON string literal.
        static func scrollToFragment(_ fragment: String) -> String {
            """
            (function (id) {
              var e = document.getElementById(id) || document.getElementsByName(id)[0];
              if (e) e.scrollIntoView({ block: 'start' });
            })(\(MarkdownPage.jsString(fragment))); true
            """
        }

        /// The person folded or unfolded a Properties block (`{open}`).
        /// Taken only from Portico's own rendered Markdown page, in the main
        /// frame, while the pane shows Markdown: an HTML file, a site, or a
        /// frame inside the page cannot move the fold.
        func propertiesToggled(_ body: Any, isMainFrame: Bool, frameURL: URL?) {
            guard isMainFrame, let frameURL, frameURL.scheme == RenderedPageHandler.scheme,
                  handler.source(for: frameURL) != nil,
                  case .markdown = loaded,
                  let open = (body as? [String: Any])?["open"] as? Bool
            else { return }
            propertiesOpen = open
            onPropertiesToggle?(open)
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

/// The page's `porticoProperties` handler (v0.17 §3.7). Holds its pane
/// weakly: the web view's content controller keeps its handlers.
private final class PropertiesToggle: NSObject, WKScriptMessageHandler {
    static let name = "porticoProperties"
    weak var coordinator: WebPane.Coordinator?

    init(_ coordinator: WebPane.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            coordinator?.propertiesToggled(
                message.body, isMainFrame: message.frameInfo.isMainFrame, frameURL: message.frameInfo.request.url)
        }
    }
}

/// The page's `comments` handler (v0.23): the comments script's messages,
/// from the main frame of the rendered Markdown page only. Holds its pane weakly.
private final class CommentsMessages: NSObject, WKScriptMessageHandler {
    static let name = "comments"
    weak var coordinator: WebPane.Coordinator?

    init(_ coordinator: WebPane.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == RenderedPageHandler.scheme,
                let comments = coordinator?.comments, let view = message.webView
            else { return }
            comments.attach(view)
            comments.received(message.body)
        }
    }
}
