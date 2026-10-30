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
    /// the body reaches the renderer.
    static func html(source: String, title: String) throws -> String {
        let template = try resource("viewer.html")
        let css = try resource("viewer.css")
        let marked = try resource("marked.min.js")
        let split = FrontMatter.split(source)
        // The block goes in first, its braces as entities, so a value that
        // reads `{{SOURCE}}` is not taken for the next placeholder.
        let properties = (split.frontMatter?.html() ?? "").replacingOccurrences(of: "{", with: "&#123;")
        return template
            .replacingOccurrences(of: "{{PROPERTIES}}", with: properties)
            .replacingOccurrences(of: "{{TITLE}}", with: escapeHTML(title))
            .replacingOccurrences(of: "{{CSS}}", with: css)
            .replacingOccurrences(of: "{{MARKED}}", with: marked)
            .replacingOccurrences(of: "{{SOURCE}}", with: jsString(split.body))
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

/// Serves a rendered markdown page to the web view under a private URL
/// scheme, `portico-view://<render>/`, and the files next to the markdown
/// (its relative images) under the same host. The page is not on disk, so
/// `loadFileURL` cannot show it, and WebKit's read grant for a file base
/// URL on `loadHTMLString` proved inconsistent (it loaded a sibling image
/// from a folder under the home directory and not from `/var/folders`, on
/// this machine). A scheme handler reads exactly what the viewer means to
/// show and nothing else.
final class RenderedPageHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "portico-view"

    struct Render {
        let page: Data
        let root: URL
    }

    private var renders: [String: Render] = [:]

    /// Register a page whose relative references resolve under `root`
    /// (a directory). Returns the URL to load.
    func register(page: String, root: URL) -> URL {
        let id = UUID().uuidString.lowercased()
        renders[id] = Render(page: Data(page.utf8), root: root.standardizedFileURL)
        return URL(string: "\(Self.scheme)://\(id)/")!
    }

    func forget(_ url: URL) {
        if let host = url.host { renders[host] = nil }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url ?? URL(string: "\(Self.scheme)://missing/")!
        guard let host = url.host, let render = renders[host] else {
            return respond(task, url: url, status: 404, type: "text/plain", body: Data("no such page".utf8))
        }
        let path = url.path
        if path.isEmpty || path == "/" || path == "/index.html" {
            return respond(task, url: url, status: 200, type: "text/html", body: render.page)
        }
        let relative = String(path.dropFirst())
        let file = render.root.appendingPathComponent(relative).standardizedFileURL
        // Stay under the root: `..` in a reference does not climb out of the markdown's folder.
        guard file.path.hasPrefix(render.root.path + "/") || file.path == render.root.path,
            let body = try? Data(contentsOf: file)
        else {
            return respond(task, url: url, status: 404, type: "text/plain", body: Data("not found".utf8))
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        respond(task, url: url, status: 200, type: type, body: body)
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

/// A `WKWebView` for the three web-rendered kinds: a markdown file (the
/// rendered page, with the file's directory as the root its relative
/// images resolve under), an HTML file (loaded as a file with read access
/// to its directory) and a URL (a local dev server, usually).
struct WebPane: NSViewRepresentable {
    enum Load: Equatable {
        case markdown(URL)
        case html(URL)
        case url(URL)
    }

    let load: Load

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView()
        context.coordinator.apply(load, to: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.apply(load, to: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: Load?
        /// The load whose navigation failed (or whose file could not be
        /// read), until a retry or another load. It stays `loaded` too:
        /// SwiftUI re-evaluates the viewer on every text delta while a
        /// turn streams, and each `updateNSView` would otherwise ask for
        /// the same dead URL again, flickering between the attempt and the
        /// failure page. The failure page carries the one way to ask again.
        private(set) var failed: Load?
        private var renderedURL: URL?
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
            return configuration
        }

        /// A web view wired to this coordinator: navigation failures
        /// reported into the pane, the retry link honoured.
        func makeWebView() -> WKWebView {
            attach(WKWebView(frame: .zero, configuration: configuration()))
        }

        /// Wire a view made from `configuration()` to this coordinator.
        @discardableResult
        func attach(_ view: WKWebView) -> WKWebView {
            view.navigationDelegate = self
            view.setValue(false, forKey: "drawsBackground")
            return view
        }

        /// Show `load` unless it is what the view already shows (or showed
        /// and failed to): a SwiftUI redraw is not a request to try again.
        func apply(_ load: Load, to view: WKWebView) {
            guard load != loaded else { return }
            start(load, in: view)
        }

        /// Ask for the current load again: the failure page's link.
        func retry(in view: WKWebView) {
            guard let load = loaded else { return }
            start(load, in: view)
        }

        private func start(_ load: Load, in view: WKWebView) {
            loaded = load
            failed = nil
            if let old = renderedURL {
                handler.forget(old)
                renderedURL = nil
            }
            switch load {
            case .markdown(let file):
                do {
                    let source = try String(contentsOf: file, encoding: .utf8)
                    let page = try MarkdownPage.html(source: source, title: file.lastPathComponent)
                    let url = handler.register(page: page, root: file.deletingLastPathComponent())
                    renderedURL = url
                    view.load(URLRequest(url: url))
                } catch {
                    showFailure("Cannot read \(file.path): \(error)", in: view)
                }
            case .html(let file):
                view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            case .url(let url):
                view.load(URLRequest(url: url))
            }
        }

        private func showFailure(_ message: String, in view: WKWebView) {
            failed = loaded
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
