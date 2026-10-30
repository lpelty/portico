import Foundation
import WebKit
import XCTest

@testable import Portico

/// The markdown page rendered in a real `WKWebView` (no window, no model):
/// the vendored renderer runs, headings come out as elements, and an image
/// named relative to the markdown file loads from its directory (and one
/// above it does not). This is
/// the model-free half of the plan's "ask for a markdown report → rendered"
/// check.
@MainActor
final class WebPaneRenderTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive = []
        super.tearDown()
    }

    func testMarkdownRendersHeadingsAndRelativeImage() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("portico-render-\(UUID().uuidString)")
        let dir = parent.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try Self.tinyPNG(width: 7, height: 5).write(to: dir.appendingPathComponent("chart.png"))
        // Only in the parent folder: the page must not be able to reach it.
        try Self.tinyPNG(width: 9, height: 5).write(to: parent.appendingPathComponent("outside.png"))
        let markdown = dir.appendingPathComponent("report.md")
        try "# Weekly report\n\nSome **bold** text.\n\n![chart](chart.png)\n\n![outside](../outside.png)\n\n- one\n- two\n".write(to: markdown, atomically: true, encoding: .utf8)

        let coordinator = WebPane.Coordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let delegate = FinishDelegate()
        view.navigationDelegate = delegate
        keepAlive = [view, coordinator, delegate]
        coordinator.apply(.markdown(markdown), to: view)

        let finished = expectation(description: "page loaded")
        delegate.onFinish = { finished.fulfill() }
        wait(for: [finished], timeout: 15)

        let probe = expectation(description: "dom probed")
        var result: [String: Any] = [:]
        // Give the image a beat to decode after didFinish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            view.evaluateJavaScript(
                """
                ({
                  h1: (document.querySelector('h1') || {}).textContent || '',
                  bold: document.querySelectorAll('strong').length,
                  items: document.querySelectorAll('li').length,
                  imgWidth: (document.querySelector('img') || {}).naturalWidth || 0,
                  escapeWidth: (document.querySelectorAll('img')[1] || {}).naturalWidth || 0,
                  title: document.title
                })
                """
            ) { value, error in
                XCTAssertNil(error)
                result = value as? [String: Any] ?? [:]
                probe.fulfill()
            }
        }
        wait(for: [probe], timeout: 15)

        XCTAssertEqual(result["h1"] as? String, "Weekly report")
        XCTAssertEqual(result["bold"] as? Int, 1)
        XCTAssertEqual(result["items"] as? Int, 2)
        XCTAssertEqual(result["title"] as? String, "report.md")
        XCTAssertEqual(result["imgWidth"] as? Int, 7, "a relative image loads from the markdown's directory; got \(result)")
        XCTAssertEqual(result["escapeWidth"] as? Int, 0, "a reference above the markdown's directory is not served")
    }

    /// v0.11 (68): front matter draws as the Properties block, folds to
    /// one line, and never turns into a heading or a rule.
    func testFrontMatterDrawsAsPropertiesNotAHeading() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-fm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("note.md")
        try "---\ntitle: Round 2\nstatus: draft\ntags: [a, b]\n---\n# Round 2\n\nBody.\n"
            .write(to: markdown, atomically: true, encoding: .utf8)

        let coordinator = WebPane.Coordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        keepAlive = [view, coordinator]
        coordinator.apply(.markdown(markdown), to: view)
        try await poll("the page renders") {
            !view.isLoading && view.url?.scheme == RenderedPageHandler.scheme
        }
        // The renderer runs after the load finishes: wait for its heading.
        for _ in 0..<200 {
            if try await evaluate("({n: document.querySelectorAll('h1').length})", in: view)["n"] as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let open = try await evaluate(
            """
            ({
              headings: [...document.querySelectorAll('h1,h2,h3')].map(h => h.textContent),
              rules: document.querySelectorAll('hr').length,
              keys: [...document.querySelectorAll('.fm-key')].map(k => k.textContent),
              tags: document.querySelectorAll('.fm-tag').length,
              summaryShown: getComputedStyle(document.querySelector('.fm-summary')).display,
              height: document.querySelector('details.fm').getBoundingClientRect().height
            })
            """, in: view)
        XCTAssertEqual(open["headings"] as? [String], ["Round 2"], "no setext heading from the closing ---: \(open)")
        XCTAssertEqual(open["rules"] as? Int, 0)
        XCTAssertEqual(open["keys"] as? [String], ["title", "status", "tags"])
        XCTAssertEqual(open["tags"] as? Int, 2)
        XCTAssertEqual(open["summaryShown"] as? String, "none", "open, the folded words hide")

        let folded = try await evaluate(
            """
            document.querySelector('details.fm').open = false;
            ({
              summary: document.querySelector('.fm-summary').textContent,
              summaryShown: getComputedStyle(document.querySelector('.fm-summary')).display,
              height: document.querySelector('details.fm').getBoundingClientRect().height
            })
            """, in: view)
        XCTAssertEqual(folded["summary"] as? String, "· 3 — draft, 2 tags")
        XCTAssertNotEqual(folded["summaryShown"] as? String, "none", "folded, the words show")
        let openHeight = open["height"] as? Double ?? 0
        let foldedHeight = folded["height"] as? Double ?? 0
        XCTAssertGreaterThan(foldedHeight, 0)
        XCTAssertLessThan(foldedHeight, 40, "folded to one line (open it was \(openHeight))")
        XCTAssertGreaterThan(openHeight, foldedHeight + 40)
    }

    func testFailedNavigationIsAskedForAgainOnlyThroughTheRetryLink() async throws {
        // A URL nobody serves (the dev server went away). The pane shows
        // why once; SwiftUI's redraws, which call apply with the same load
        // on every text delta while a turn streams, must not ask for it
        // again. The failure page's link is the one way to try again.
        let port = try await freeLoopbackPort()
        let dead = URL(string: "http://127.0.0.1:\(port)/")!
        let coordinator = WebPane.Coordinator()
        let view = CountingWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: coordinator.configuration())
        coordinator.attach(view)
        keepAlive = [view, coordinator]

        coordinator.apply(.url(dead), to: view)
        XCTAssertEqual(view.loads, 1)
        try await poll("the navigation fails") { coordinator.failed == .url(dead) }

        for _ in 0..<5 { coordinator.apply(.url(dead), to: view) }
        XCTAssertEqual(view.loads, 1, "a redraw with the same load does not try the dead URL again")
        XCTAssertEqual(coordinator.failed, .url(dead), "the failure stands until a retry")

        // The failure page is up, with the message and the link.
        try await poll("the failure page is shown") { !view.isLoading && view.url?.absoluteString == "about:blank" }
        let shown = try await evaluate(
            "({text: document.body.textContent, link: (document.querySelector('a') || {}).href || ''})", in: view)
        XCTAssertTrue((shown["text"] as? String ?? "").contains("connect"), "the page says why: \(shown)")
        XCTAssertEqual(shown["link"] as? String, WebPane.Coordinator.retryURL.absoluteString)

        // Following the link asks once more (and fails again, which is a new failure, not a loop).
        _ = try await evaluate("document.querySelector('a').click(); true", in: view)
        try await poll("the link asks again") { view.loads == 2 }
        try await poll("the second attempt fails too") { coordinator.failed == .url(dead) }
        coordinator.apply(.url(dead), to: view)
        XCTAssertEqual(view.loads, 2)

        // Another load is another matter: it goes out at once.
        let other = URL(string: "http://127.0.0.1:\(port)/other")!
        coordinator.apply(.url(other), to: view)
        XCTAssertEqual(view.loads, 3)
        XCTAssertNil(coordinator.failed, "a new load clears the old failure until it fails itself")
    }

    /// A web view that counts the navigations it is asked for.
    final class CountingWebView: WKWebView {
        var loads = 0
        override func load(_ request: URLRequest) -> WKNavigation? {
            loads += 1
            return super.load(request)
        }
    }

    private func poll(_ what: String, seconds: Double = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now >= deadline { throw PollTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct PollTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting until \(what)" }
    }

    /// Run `script` (which must evaluate to something, never undefined) and
    /// return its object result, or an empty one for a scalar.
    private func evaluate(_ script: String, in view: WKWebView) async throws -> [String: Any] {
        let value = try await view.evaluateJavaScript(script)
        return value as? [String: Any] ?? [:]
    }

    final class FinishDelegate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            XCTFail("navigation failed: \(error)")
            onFinish?()
        }
    }

    /// A solid red RGB PNG of the given size, built by hand so the test
    /// needs no fixture file.
    static func tinyPNG(width: Int, height: Int) -> Data {
        func chunk(_ type: String, _ body: Data) -> Data {
            var out = Data()
            var length = UInt32(body.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typed = Data(type.utf8) + body
            out.append(typed)
            var crc = crc32(typed).bigEndian
            out.append(Data(bytes: &crc, count: 4))
            return out
        }
        var raw = Data()
        for _ in 0..<height {
            raw.append(0)
            for _ in 0..<width { raw.append(contentsOf: [0xFF, 0x00, 0x00]) }
        }
        var header = Data()
        for value in [UInt32(width), UInt32(height)] {
            var big = value.bigEndian
            header.append(Data(bytes: &big, count: 4))
        }
        header.append(contentsOf: [8, 2, 0, 0, 0])
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    /// zlib stream with one stored (uncompressed) deflate block.
    private static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let length = UInt16(data.count)
        out.append(0x01)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8(length >> 8))
        out.append(UInt8(~length & 0xFF))
        out.append(UInt8(~length >> 8))
        out.append(data)
        var adler = adler32(data).bigEndian
        out.append(Data(bytes: &adler, count: 4))
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
