import AppKit
import Foundation
import WebKit
import XCTest

@testable import Portico

/// v0.23: the comments page script (`viewer-comments.js`) in the rendered
/// Markdown page, in a real `WKWebView` as `ViewerMarksScriptTests` runs
/// the agent's script.
@MainActor
final class CommentsPageScriptTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    struct Timeout: Error {}

    func webView(size: NSSize = NSSize(width: 1200, height: 800)) -> WKWebView {
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        keepAlive.append(contentsOf: [view, window])
        return view
    }

    /// The viewer's page for `source`, loaded and rendered.
    func page(_ source: String, size: NSSize = NSSize(width: 1200, height: 800)) async throws -> WKWebView {
        let view = webView(size: size)
        view.loadHTMLString(try MarkdownPage.html(source: source, title: "note.md"), baseURL: URL(string: "https://acme.example/"))
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let ready = try? await view.callAsyncJavaScript(
                "return document.readyState === 'complete' && !!window.__porticoComments",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
            if ready == true { return view }
            if ContinuousClock.now >= deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func js(_ body: String, _ args: [String: Any] = [:], in view: WKWebView) async throws -> Any? {
        let wrapped = "return JSON.stringify((function () { \(body) })())"
        let text = try await view.callAsyncJavaScript(wrapped, arguments: args, in: nil, contentWorld: .page) as? String
        guard let data = text?.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Select `from`…`to` (character offsets) inside the first text node containing `needle`.
    func select(_ needle: String, _ from: Int, _ to: Int, in view: WKWebView) async throws {
        _ = try await js("""
            var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            var n; while ((n = w.nextNode())) { if (n.data.indexOf(needle) >= 0) break; }
            var r = document.createRange(); r.setStart(n, n.data.indexOf(needle) + from); r.setEnd(n, n.data.indexOf(needle) + to);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, ["needle": needle, "from": from, "to": to], in: view)
    }

    // MARK: - blocks and highlights (Task 4)

    func testBlocksCarrySourceLines() async throws {
        let view = try await page(try CommentFormatTests.read("list-after.md"))
        let lines = try await js("""
            return { h1: document.querySelector('h1').getAttribute('data-lines'),
                     ol: document.querySelector('ol').getAttribute('data-lines'),
                     lists: document.querySelectorAll('ol').length,
                     after: [...document.querySelectorAll('p')].pop().getAttribute('data-lines') };
            """, in: view) as? [String: Any]
        XCTAssertEqual(lines?["h1"] as? String, "0-0")
        XCTAssertEqual(lines?["ol"] as? String, "2-7")
        XCTAssertEqual(lines?["lists"] as? Int, 1, "the thread blocks don't split the list")
        XCTAssertEqual(lines?["after"] as? String, "19-19")
    }

    func testFrontMatterLinesCounted() async throws {
        let view = try await page(try CommentFormatTests.read("front-matter.md"))
        let line = try await js("return document.querySelector('#body p').getAttribute('data-lines');", in: view) as? String
        XCTAssertEqual(line, "4-4")
    }

    func testReferenceLinksStillResolve() async throws {
        let view = try await page("See [the docs][d].\n\n[d]: https://example.com/docs\n")
        let href = try await js("return document.querySelector('#body a').getAttribute('href');", in: view) as? String
        XCTAssertEqual(href, "https://example.com/docs")
    }

    func testOpenAnchorsHighlightedResolvedNot() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        let marks = try await js("""
            return [...document.querySelectorAll('mark.pc-anchor')].map(m => [m.dataset.c, m.classList.contains('pc-open'), m.textContent]);
            """, in: view) as? [[Any]]
        XCTAssertEqual(marks?.count, 2)
        XCTAssertEqual(marks?[0][0] as? String, "rs001")
        XCTAssertEqual(marks?[0][1] as? Bool, true)
        XCTAssertEqual(marks?[0][2] as? String, "open point")
        XCTAssertEqual(marks?[1][1] as? Bool, false, "resolved only: not highlighted")
        let bg = try await js("return getComputedStyle(document.querySelector('mark.pc-open')).backgroundColor;", in: view) as? String
        XCTAssertNotEqual(bg, "rgba(0, 0, 0, 0)")
    }

    func testOverlappingAnchorsBothHighlighted() async throws {
        let view = try await page(try CommentFormatTests.read("continuation.add.after.md"))
        let nested = try await js("""
            var inner = document.querySelector('mark[data-c="nw006"]');
            return { inner: inner.textContent, inOuter: !!inner.closest('mark[data-c="cn001"]'),
                     open: inner.classList.contains('pc-open') && inner.closest('mark[data-c="cn001"]').classList.contains('pc-open') };
            """, in: view) as? [String: Any]
        XCTAssertEqual(nested?["inner"] as? String, "agent write")
        XCTAssertEqual(nested?["inOuter"] as? Bool, true)
        XCTAssertEqual(nested?["open"] as? Bool, true)
    }

    func testSelectionSnapsToWords() async throws {
        let view = try await page("Intro.\n\nthe permission prompt stays\n")
        try await select("the permission", 5, 18, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "permission prompt")
        XCTAssertEqual(info?["lines"] as? [Int], [2, 2])
        XCTAssertEqual(info?["occurrence"] as? Int, 0)
        XCTAssertNil(info?["refusal"] as? String)
    }

    func testSelectionOccurrenceCountsEarlierMatchesInBlock() async throws {
        let view = try await page("The cat sat with the cat.\n")
        try await select("with the cat", 9, 12, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "cat")
        XCTAssertEqual(info?["occurrence"] as? Int, 1)
    }

    func testSelectionInCodeBlockRefused() async throws {
        let view = try await page("Text.\n\n```\ncode here\n```\n")
        try await select("code here", 0, 4, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["refusal"] as? String, "ignored")
    }

    func testSelectionAcrossListItemsRefused() async throws {
        let view = try await page("- one item\n- two item\n")
        _ = try await js("""
            var lis = document.querySelectorAll('li');
            var r = document.createRange(); r.setStart(lis[0].firstChild, 0); r.setEnd(lis[1].firstChild, 3);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["refusal"] as? String, "crosses")
    }

    func testCRLFSourceLinesMatch() async throws {
        let view = try await page("A\r\n\r\nB para\r\nnext\r\n")
        let lines = try await js("return [...document.querySelectorAll('#body p')].map(p => p.getAttribute('data-lines'));", in: view) as? [String]
        XCTAssertEqual(lines, ["0-0", "2-3"])
    }

    // MARK: - the margin (Task 5)

    static let state: [String: Any] = [
        "on": true, "activeID": NSNull(), "readOnly": NSNull(), "draft": NSNull(), "error": NSNull(),
        "theme": [String: String](),
        "threads": [
            ["id": "rs001", "status": "open", "quote": "open point", "orphan": false,
             "replies": [["author": "Sam", "initial": "S", "agent": false, "time": "2 h ago", "text": "First."]]],
            ["id": "rs002", "status": "resolved", "quote": "settled point", "orphan": false,
             "replies": [["author": "Agent", "initial": "A", "agent": true, "time": "1 h ago", "text": "Done."]]],
        ],
    ]

    func render(_ state: [String: Any], in view: WKWebView) async throws {
        _ = try await js("window.__porticoComments.render(state); return true;", ["state": state], in: view)
    }

    func testLayoutWideNarrowAndBelowMinimum() async throws {
        let view = try await page("Text.\n")
        let out = try await js("""
            var L = window.__porticoComments.layout;
            return [L(1400, 630), L(900, 630), L(780, 630), L(700, 630), L(500, 630)];
            """, in: view) as? [[String: Double]]
        XCTAssertEqual(out?[0], ["column": 630, "card": 300])
        XCTAssertEqual(out?[1], ["column": 516, "card": 300])
        XCTAssertEqual(out?[2], ["column": 420, "card": 276])
        XCTAssertEqual(out?[3], ["column": 340, "card": 276], "below the floor the cards keep 276")
        XCTAssertEqual(out?[4]["card"], 276)
    }

    func testStackPushesDown8() async throws {
        let view = try await page("Text.\n")
        let out = try await js("return window.__porticoComments.stack([0, 10, 200], [100, 50, 20]);", in: view) as? [Double]
        XCTAssertEqual(out, [0, 108, 200])
    }

    func testCommentsOnMovesTheColumnLeftAndDrawsCards() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"), size: NSSize(width: 1400, height: 800))
        try await render(Self.state, in: view)
        let geo = try await js("""
            var p = document.querySelector('#body p');
            var card = document.querySelector('.pc-card[data-id="rs001"]');
            var mark = document.querySelector('mark[data-c="rs001"]');
            return { left: p.getBoundingClientRect().left, cards: document.querySelectorAll('.pc-card').length,
                     cardTop: Math.round(card.getBoundingClientRect().top), markTop: Math.round(mark.getClientRects()[0].top),
                     width: Math.round(card.getBoundingClientRect().width), resolved: !!document.querySelector('.pc-card[data-id="rs002"] .pc-resolved-line'),
                     scroll: document.documentElement.scrollWidth <= window.innerWidth };
            """, in: view) as? [String: Any]
        XCTAssertEqual(geo?["left"] as? Double, 44)
        XCTAssertEqual(geo?["cards"] as? Int, 2)
        XCTAssertEqual(geo?["width"] as? Int, 300)
        XCTAssertEqual(geo?["cardTop"] as? Int, geo?["markTop"] as? Int)
        XCTAssertEqual(geo?["resolved"] as? Bool, true)
        XCTAssertEqual(geo?["scroll"] as? Bool, true, "no horizontal scroll")
    }

    func testHoverCardBrightensAnchor() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await render(Self.state, in: view)
        let hot = try await js("""
            var card = document.querySelector('.pc-card[data-id="rs001"]');
            card.dispatchEvent(new MouseEvent('mouseenter'));
            var on = document.querySelector('mark[data-c="rs001"]').classList.contains('pc-hot');
            card.dispatchEvent(new MouseEvent('mouseleave'));
            var off = document.querySelector('mark[data-c="rs001"]').classList.contains('pc-hot');
            return [on, off];
            """, in: view) as? [Bool]
        XCTAssertEqual(hot, [true, false])
    }

    func testClickAnchorActivatesCard() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        let sent = try await js("""
            var sent = [];
            window.__porticoComments.post = function (m) { sent.push(m); };
            document.querySelector('mark[data-c="rs001"]').dispatchEvent(new MouseEvent('click', {bubbles: true}));
            return sent;
            """, in: view) as? [[String: String]]
        XCTAssertEqual(sent?.last, ["type": "anchorClicked", "id": "rs001"])
    }

    func testEmptyStateCopy() async throws {
        let view = try await page("Nothing here.\n")
        var state = Self.state
        state["threads"] = [[String: Any]]()
        try await render(state, in: view)
        let text = try await js("return document.querySelector('#pc-margin').textContent.trim();", in: view) as? String
        XCTAssertEqual(text, "No comments. Select text and choose Comment.")
    }

    func testReadOnlyDisablesActions() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        var state = Self.state
        state["activeID"] = "rs001"
        state["readOnly"] = "The file is read-only."
        try await render(state, in: view)
        let out = try await js("""
            var field = document.querySelector('.pc-card[data-id="rs001"] textarea');
            var resolve = document.querySelector('.pc-card[data-id="rs001"] .pc-resolve');
            return [field.disabled, resolve.disabled, resolve.title];
            """, in: view) as? [Any]
        XCTAssertEqual(out?[0] as? Bool, true)
        XCTAssertEqual(out?[1] as? Bool, true)
        XCTAssertEqual(out?[2] as? String, "The file is read-only.")
    }
}
