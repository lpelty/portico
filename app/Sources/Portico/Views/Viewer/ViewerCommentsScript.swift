import WebKit

/// v0.24 (review H1): the viewer's comments script (`viewer-comments.js`)
/// runs in a content world of its own, and the app's `comments` handler is
/// registered only there. No page script, in any document the viewer shows,
/// can post to it: the rendered Markdown page runs only its own scripts, and
/// an HTML file, SVG or site never sees the handler at all.
///
/// The script shares the page's DOM (it draws the margin and reads the
/// selection there) but not its globals; the app talks to it by evaluating
/// in `world`. The Markdown editor's page keeps its own copy in its page
/// world: it shows no untrusted HTML.
@MainActor
enum ViewerCommentsScript {
    static let world = WKContentWorld.world(name: "viewer-comments")

    /// The script, run only in the rendered Markdown page (served at `/` under
    /// the viewer's scheme, with the page's `#content` and `#body`), so it
    /// never draws a margin or takes the context menu in an HTML file or site.
    /// `onlyRenderedPage: false` is for tests that load the page elsewhere.
    static func source(onlyRenderedPage: Bool = true) -> String? {
        guard let url = AppResources.url(forResource: "viewer-comments", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        guard onlyRenderedPage else { return script }
        return """
            if (location.protocol === "\(RenderedPageHandler.scheme):"
                && (location.pathname === "/" || location.pathname === "/index.html")
                && document.getElementById("content") && document.getElementById("body")) {
            \(script)
            }
            """
    }

    /// After the page's own scripts have drawn the body; main frame only.
    static func userScript(onlyRenderedPage: Bool = true) -> WKUserScript? {
        source(onlyRenderedPage: onlyRenderedPage).map {
            WKUserScript(source: $0, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
        }
    }
}
