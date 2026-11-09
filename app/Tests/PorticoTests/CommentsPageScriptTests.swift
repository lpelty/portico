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
    /// v0.24 (review H1): the comments script runs in its own content world,
    /// installed as `WebPane` installs it (here without the rendered-page
    /// check, since the page is loaded under a test address).
    func page(_ source: String, size: NSSize = NSSize(width: 1200, height: 800)) async throws -> WKWebView {
        let view = webView(size: size)
        view.configuration.userContentController.addUserScript(try XCTUnwrap(ViewerCommentsScript.userScript(onlyRenderedPage: false)))
        view.loadHTMLString(try MarkdownPage.html(source: source, title: "note.md"), baseURL: URL(string: "https://acme.example/"))
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let ready = try? await view.callAsyncJavaScript(
                "return document.readyState === 'complete' && !!window.__porticoComments",
                arguments: [:], in: nil, contentWorld: ViewerCommentsScript.world) as? Bool
            if ready == true { return view }
            if ContinuousClock.now >= deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The editor's pages run the comments script in their page world.
    private var editorViews: Set<ObjectIdentifier> = []

    func js(_ body: String, _ args: [String: Any] = [:], in view: WKWebView) async throws -> Any? {
        let wrapped = "return JSON.stringify((function () { \(body) })())"
        let world = editorViews.contains(ObjectIdentifier(view)) ? WKContentWorld.page : ViewerCommentsScript.world
        let text = try await view.callAsyncJavaScript(wrapped, arguments: args, in: nil, contentWorld: world) as? String
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

    /// v0.26.2 follow-up (Larry, 11-09 demos): selecting a whole line (a
    /// triple click, or a drag past its end) left Comment greyed out; one
    /// word worked. WebKit ends such a selection at the start of the next
    /// block, so it read as crossing blocks.
    func testAWholeParagraphSelectedToTheNextBlocksStartCanBeCommented() async throws {
        let view = try await page("Intro.\n\nthe permission prompt stays\n\nNext one.\n")
        _ = try await js("""
            var ps = document.querySelectorAll('#body p');
            var r = document.createRange(); r.setStart(ps[1].firstChild, 0); r.setEnd(ps[2], 0);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertNil(info?["refusal"] as? String)
        XCTAssertEqual(info?["text"] as? String, "the permission prompt stays")
        XCTAssertEqual(info?["lines"] as? [Int], [2, 2])
    }

    func testAWholeListItemSelectedToTheNextItemsStartCanBeCommented() async throws {
        let view = try await page("- one item\n- two item\n")
        _ = try await js("""
            var lis = document.querySelectorAll('li');
            var r = document.createRange(); r.setStart(lis[0].firstChild, 0); r.setEnd(lis[1].firstChild, 0);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertNil(info?["refusal"] as? String)
        XCTAssertEqual(info?["text"] as? String, "one item")
    }

    /// A real triple click, as WebKit selects a paragraph.
    func testATripleClickedParagraphCanBeCommented() async throws {
        let view = try await page("Intro.\n\nthe permission prompt stays\n\nNext one.\n")
        _ = try await js("""
            var p = document.querySelectorAll('#body p')[1];
            var s = getSelection(); s.removeAllRanges();
            s.setPosition(p.firstChild, 3); s.modify('move', 'backward', 'paragraphboundary');
            s.modify('extend', 'forward', 'paragraphboundary');
            return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertNil(info?["refusal"] as? String)
        XCTAssertEqual(info?["text"] as? String, "the permission prompt stays")
    }

    func testCRLFSourceLinesMatch() async throws {
        let view = try await page("A\r\n\r\nB para\r\nnext\r\n")
        let lines = try await js("return [...document.querySelectorAll('#body p')].map(p => p.getAttribute('data-lines'));", in: view) as? [String]
        XCTAssertEqual(lines, ["0-0", "2-3"])
    }

    // MARK: - the margin (Task 5)

    static let state: [String: Any] = [
        "on": true, "activeID": NSNull(), "readOnly": NSNull(), "draft": NSNull(), "error": NSNull(),
        "theme": [String: String](), "showResolved": true, "resolvedCount": 1,
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

    // MARK: - the context menu (Task 6)

    func testContextMenuPostsTheSelectionAndPreventsWebKitsMenu() async throws {
        let view = try await page("Intro.\n\nthe permission prompt stays\n")
        try await select("the permission", 5, 18, in: view)
        let out = try await js("""
            var sent = [];
            window.__porticoComments.post = function (m) { sent.push(m); };
            var e = new MouseEvent('contextmenu', {bubbles: true, cancelable: true, clientX: 30, clientY: 40});
            var kept = document.querySelector('#body p:last-child').dispatchEvent(e);
            return { prevented: !kept, sent: sent };
            """, in: view) as? [String: Any]
        XCTAssertEqual(out?["prevented"] as? Bool, true)
        let sent = try XCTUnwrap((out?["sent"] as? [[String: Any]])?.last)
        XCTAssertEqual(sent["type"] as? String, "menu")
        XCTAssertEqual(sent["x"] as? Double, 30)
        XCTAssertEqual((sent["selection"] as? [String: Any])?["text"] as? String, "permission prompt")
    }

    func testMarkDraftWrapsTheSnappedSelection() async throws {
        let view = try await page("Intro.\n\nthe permission prompt stays\n")
        try await select("the permission", 5, 18, in: view)
        let text = try await js("""
            window.__porticoComments.selectionInfo();
            window.__porticoComments.markDraft();
            return document.querySelector('mark.pc-draft').textContent;
            """, in: view) as? String
        XCTAssertEqual(text, "permission prompt")
    }

    // MARK: - the editor's page (Task 7)

    func testEditorPageHidesMarkupAndDrawsTheMargin() async throws {
        let view = webView(size: NSSize(width: 1400, height: 800))
        editorViews.insert(ObjectIdentifier(view))
        view.loadHTMLString(try EditorPage.html(), baseURL: URL(string: "https://acme.example/"))
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let ready = try? await view.callAsyncJavaScript(
                "return document.readyState === 'complete' && !!window.portico && !!window.__porticoComments",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
            if ready == true { break }
            if ContinuousClock.now >= deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let source = try CommentFormatTests.read("resolved.md")
        _ = try await js("portico.load({text: text, mode: 'markdown'}); return true;", ["text": source], in: view)
        try await render(Self.state, in: view)
        let out = try await js("""
            var content = document.querySelector('.cm-content');
            var card = document.querySelector('.cm-scroller #pc-margin .pc-card[data-id="rs001"]');
            return { shown: content.textContent, cards: document.querySelectorAll('#pc-margin .pc-card').length,
                     open: !!document.querySelector('mark.pc-anchor.pc-open[data-c="rs001"]'),
                     left: Math.round(content.getBoundingClientRect().left + parseFloat(getComputedStyle(content).paddingLeft)),
                     cardWidth: card ? Math.round(card.getBoundingClientRect().width) : 0 };
            """, in: view) as? [String: Any]
        let shown = try XCTUnwrap(out?["shown"] as? String)
        XCTAssertFalse(shown.contains("<!--"), "comment markup is hidden: \(shown)")
        XCTAssertTrue(shown.contains("open point"))
        XCTAssertEqual(out?["cards"] as? Int, 2)
        XCTAssertEqual(out?["open"] as? Bool, true)
        XCTAssertEqual(out?["left"] as? Int, 44)
        XCTAssertEqual(out?["cardWidth"] as? Int, 300)
    }

    // MARK: - fix round (review items 3, 4, 7, 9)

    func testAnchorAtColumnZeroRendersAsMarkdown() async throws {
        let view = try await page(try CommentFormatTests.read("anchor-col0.md"))
        let out = try await js("""
            var p = document.querySelector('#body p');
            return { strong: p && p.querySelector('strong') ? p.querySelector('strong').textContent : null,
                     mark: (document.querySelector('mark.pc-anchor.pc-open[data-c="ca001"]') || {}).textContent || null,
                     lines: p ? p.getAttribute('data-lines') : null,
                     sentinels: /[\\uE000-\\uE002]/.test(document.querySelector("#body").textContent) };
            """, in: view) as? [String: Any]
        XCTAssertEqual(out?["strong"] as? String, "world", "the paragraph is Markdown, not raw HTML")
        XCTAssertEqual(out?["mark"] as? String, "Hello")
        XCTAssertEqual(out?["lines"] as? String, "0-0")
        XCTAssertEqual(out?["sentinels"] as? Bool, false)
    }

    func testDefinitionsAndTabsKeepSourceLines() async throws {
        let view = try await page("See [x] here.\n\n[x]: http://a.example\n\nAfter para.\n\n- item\n\tnested\n")
        let lines = try await js("""
            return [...document.querySelectorAll('#body > p, #body > ul')].map(e => e.getAttribute('data-lines'));
            """, in: view) as? [String?]
        XCTAssertEqual(lines?.first ?? nil, "0-0")
        XCTAssertEqual(lines?.count, 3)
        XCTAssertEqual(lines?[1] ?? nil, "4-4", "a link definition doesn't stop the lines after it")
    }

    func testOccurrenceCountsVisibleTextOutsideCode() async throws {
        let view = try await page("Use `cat` and cat here.\n")
        _ = try await js("""
            var p = document.querySelector('#body p');
            var n = p.lastChild; // " and cat here."
            var r = document.createRange(); r.setStart(n, 5); r.setEnd(n, 8);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "cat")
        XCTAssertEqual(info?["occurrence"] as? Int, 0, "the cat in code isn't counted")
    }

    func testQuotedAndDuplicateStatusesHighlightAsTheFormatSays() async throws {
        let view = try await page(try CommentFormatTests.read("header-keys.md"))
        let open = try await js("""
            return ['hq001','hq002','hq003'].map(id => document.querySelector('mark[data-c="' + id + '"]').classList.contains('pc-open'));
            """, in: view) as? [Bool]
        XCTAssertEqual(open, [true, false, true])
    }

    // MARK: - re-review items 2, 3, 4

    func testLinesAreNotFoundInsideADroppedDefinition() async throws {
        let view = try await page("See [x].\n\n[x]: http://a.com/flow\n\nflow\n")
        let lines = try await js("return [...document.querySelectorAll('#body > p')].map(p => p.getAttribute('data-lines'));", in: view) as? [String?]
        XCTAssertEqual(lines?.last ?? nil, "4-4")
    }

    func testTheFilesOwnPrivateUseTextSurvives() async throws {
        let own = "Keep \u{E000}abcde\u{E001} and \u{E002}x\u{E003}y as written.\n"
        let view = try await page(own)
        let out = try await js("""
            return { text: document.querySelector('#body p').textContent,
                     comments: document.createTreeWalker(document.getElementById('body'), NodeFilter.SHOW_COMMENT).nextNode() !== null };
            """, in: view) as? [String: Any]
        XCTAssertEqual(out?["text"] as? String, "Keep \u{E000}abcde\u{E001} and \u{E002}x\u{E003}y as written.")
        XCTAssertEqual(out?["comments"] as? Bool, false)
    }

    func testSnapLeavesCJKAndThaiAsSelected() async throws {
        let view = try await page("前文。\n\n日本語の文章です\n\nภาษาไทยไม่มีช่องว่าง\n")
        try await select("日本語の文章です", 4, 6, in: view)
        var info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "文章")
        try await select("ภาษาไทย", 2, 5, in: view)
        info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "ษาไ")
    }

    func testSnapNeverSplitsACombiningMark() async throws {
        let view = try await page("Intro.\n\nan e\u{301}tude here\n")
        // Select from the combining accent (after the base e) to the end of "tude".
        try await select("e\u{301}tude", 1, 6, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["text"] as? String, "e\u{301}tude")
    }

    func testSnapTakesWholeGraphemeClusters() async throws {
        let view = try await page("Intro.\n\nok 👍🏽 and 👨‍👩‍👧 and 🇯🇵 end\n")
        for (needle, length, want) in [("👍🏽", 2, "👍🏽"), ("👨‍👩‍👧", 2, "👨‍👩‍👧"), ("🇯🇵", 2, "🇯🇵")] {
            try await select(needle, 0, length, in: view)
            let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
            XCTAssertEqual(info?["text"] as? String, want)
        }
    }

    // MARK: - table cells (spec §13)

    func testACellSelectionReportsItsRowAndCell() async throws {
        let view = try await page(try CommentFormatTests.read("table.md"))
        _ = try await js("""
            var td = document.querySelectorAll('tbody tr')[0].children[2];
            var r = document.createRange(); r.selectNodeContents(td);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertNil(info?["refusal"] as? String)
        XCTAssertEqual(info?["text"] as? String, "10")
        XCTAssertEqual(info?["lines"] as? [Int], [2, 5], "the table's lines")
        XCTAssertEqual(info?["row"] as? Int, 1, "the first body row")
        XCTAssertEqual(info?["cell"] as? Int, 2)
        XCTAssertEqual(info?["table"] as? Int, 0)
        _ = try await js("""
            var th = document.querySelectorAll('thead th')[1];
            var r = document.createRange(); r.selectNodeContents(th);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let head = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(head?["row"] as? Int, 0, "the header row")
        XCTAssertEqual(head?["cell"] as? Int, 1)
    }

    func testASelectionAcrossCellsIsRefusedAsCells() async throws {
        let view = try await page(try CommentFormatTests.read("table.md"))
        _ = try await js("""
            var tds = document.querySelectorAll('tbody tr')[0].children;
            var r = document.createRange(); r.setStart(tds[0].firstChild, 1); r.setEnd(tds[1].firstChild, 1);
            var s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
            """, in: view)
        let info = try await js("return window.__porticoComments.selectionInfo();", in: view) as? [String: Any]
        XCTAssertEqual(info?["refusal"] as? String, "cell")
    }

    func testHighlightsRenderInsideCells() async throws {
        let view = try await page(try CommentFormatTests.read("table-cells.md"))
        let out = try await js("""
            return [...document.querySelectorAll('mark.pc-anchor.pc-open')].map(m => [m.dataset.c, m.textContent, !!m.closest('td')]);
            """, in: view) as? [[Any]]
        XCTAssertEqual(out?.count, 2)
        XCTAssertEqual(out?[0][1] as? String, "alpha")
        XCTAssertEqual(out?[1][1] as? String, "y")
        XCTAssertEqual(out?[1][2] as? Bool, true)
        let cell = try await js("return document.querySelectorAll('tbody td')[1].textContent;", in: view) as? String
        XCTAssertEqual(cell, "x | y", "the escaped pipe is text in its cell")
    }

    // MARK: - card actions (spec §13.2)

    static func actionState(text: String = "First.", showResolved: Bool = false) -> [String: Any] {
        [
            "on": true, "activeID": "rs001", "readOnly": NSNull(), "draft": NSNull(), "error": NSNull(),
            "theme": [String: String](), "showResolved": showResolved, "resolvedCount": 1,
            "threads": [
                ["id": "rs001", "status": "open", "quote": "open point", "orphan": false,
                 "replies": [
                    ["author": "Sam", "initial": "S", "agent": false, "own": true, "index": 0, "at": "T0", "time": "2 h ago", "text": text],
                    ["author": "Agent", "initial": "A", "agent": true, "own": false, "index": 1, "time": "1 h ago", "text": "Reply."],
                 ]],
                ["id": "rs002", "status": "resolved", "quote": "settled point", "orphan": false,
                 "replies": [["author": "Agent", "initial": "A", "agent": true, "own": false, "index": 0, "time": "1 h ago", "text": "Done."]]],
            ],
        ]
    }

    func capture(_ view: WKWebView) async throws {
        _ = try await js("window.__sent = []; window.__porticoComments.post = function (m) { window.__sent.push(m); }; return true;", in: view)
    }

    func sent(_ view: WKWebView) async throws -> [[String: Any]] {
        try await js("return window.__sent;", in: view) as? [[String: Any]] ?? []
    }

    func testTheMoreMenuOffersEditOnlyForYourOwnComments() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await render(Self.actionState(), in: view)
        let menus = try await js("""
            var out = [];
            document.querySelectorAll('.pc-card[data-id="rs001"] .pc-reply').forEach(function (r) {
              r.querySelector('.pc-more').click();
              out.push([...document.querySelectorAll('.pc-menu button')].map(b => b.textContent));
              document.body.click();
            });
            return out;
            """, in: view) as? [[String]]
        XCTAssertEqual(menus, [["Edit", "Delete"], ["Delete"]])
        let focusable = try await js("return document.querySelector('.pc-more').tagName;", in: view) as? String
        XCTAssertEqual(focusable, "BUTTON", "reachable by keyboard")
    }

    func testEditSavesWithCommandReturnAndCancelsWithEscape() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await render(Self.actionState(), in: view)
        try await capture(view)
        let field = try await js("""
            document.querySelector('.pc-card[data-id="rs001"] .pc-reply .pc-more').click();
            [...document.querySelectorAll('.pc-menu button')].find(b => b.textContent === 'Edit').click();
            var f = document.querySelector('.pc-edit-field');
            var had = f.value;
            f.value = 'Changed.';
            f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true}));
            return had;
            """, in: view) as? String
        XCTAssertEqual(field, "First.")
        let messages = try await sent(view)
        XCTAssertEqual(messages.last?["type"] as? String, "edit")
        XCTAssertEqual(messages.last?["id"] as? String, "rs001")
        XCTAssertEqual(messages.last?["index"] as? Int, 0)
        XCTAssertEqual(messages.last?["text"] as? String, "Changed.")
        XCTAssertEqual(messages.last?["fp"] as? [String: String], ["author": "Sam", "at": "T0", "text": "First."])
        let cancelled = try await js("""
            document.querySelector('.pc-card[data-id="rs001"] .pc-reply .pc-more').click();
            [...document.querySelectorAll('.pc-menu button')].find(b => b.textContent === 'Edit').click();
            var f = document.querySelector('.pc-edit-field');
            f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
            return !document.querySelector('.pc-edit-field') && !!document.querySelector('.pc-card[data-id="rs001"] .pc-text');
            """, in: view) as? Bool
        XCTAssertEqual(cancelled, true)
    }

    func testDeletingAThreadWithRepliesAsksInTheCardFirst() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await render(Self.actionState(), in: view)
        try await capture(view)
        let words = try await js("""
            document.querySelector('.pc-card[data-id="rs001"] .pc-reply .pc-more').click();
            [...document.querySelectorAll('.pc-menu button')].find(b => b.textContent === 'Delete').click();
            var c = document.querySelector('.pc-confirm');
            return [c.querySelector('.pc-confirm-words').textContent, getComputedStyle(c.querySelector('.pc-danger')).backgroundColor];
            """, in: view) as? [String]
        XCTAssertEqual(words?.first, "Delete this thread and its 1 reply?")
        XCTAssertNotEqual(words?.last, "rgba(0, 0, 0, 0)")
        let before = try await sent(view).filter { $0["type"] as? String == "delete" }
        XCTAssertTrue(before.isEmpty, "nothing deleted before the confirm")
        _ = try await js("document.querySelector('.pc-confirm .pc-danger').click(); return true;", in: view)
        let after = try await sent(view)
        XCTAssertEqual(after.last?["type"] as? String, "delete")
        XCTAssertEqual(after.last?["index"] as? Int, 0)
        // A reply goes at once.
        _ = try await js("""
            document.querySelectorAll('.pc-card[data-id="rs001"] .pc-reply')[1].querySelector('.pc-more').click();
            [...document.querySelectorAll('.pc-menu button')].find(b => b.textContent === 'Delete').click();
            return true;
            """, in: view)
        let last = try await sent(view).last
        XCTAssertEqual(last?["index"] as? Int, 1)
    }

    func testLongCommentsClampWithShowMore() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        let long = Array(repeating: "A long line of comment text that wraps.", count: 20).joined(separator: " ")
        try await render(Self.actionState(text: long), in: view)
        let out = try await js("""
            var more = document.querySelector('.pc-card[data-id="rs001"] .pc-show-more');
            var text = document.querySelector('.pc-card[data-id="rs001"] .pc-text');
            var lh = parseFloat(getComputedStyle(text).lineHeight);
            var clamped = text.getBoundingClientRect().height;
            more.click();
            var more2 = document.querySelector('.pc-card[data-id="rs001"] .pc-show-more');
            return [more.textContent, Math.round(clamped / lh), more2.textContent,
                    document.querySelector('.pc-card[data-id="rs001"] .pc-text').getBoundingClientRect().height > clamped];
            """, in: view) as? [Any]
        XCTAssertEqual(out?[0] as? String, "Show more")
        XCTAssertEqual(out?[1] as? Int, 6)
        XCTAssertEqual(out?[2] as? String, "Show less")
        XCTAssertEqual(out?[3] as? Bool, true)
    }

    func testResolvedThreadsHideUntilTheSwitchIsOn() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await render(Self.actionState(), in: view)
        try await capture(view)
        let off = try await js("""
            return [!!document.querySelector('.pc-card[data-id="rs002"]'), document.querySelector('.pc-show-resolved').textContent.trim()];
            """, in: view) as? [Any]
        XCTAssertEqual(off?[0] as? Bool, false)
        XCTAssertEqual(off?[1] as? String, "Show resolved (1)")
        _ = try await js("document.querySelector('.pc-show-resolved input').click(); return true;", in: view)
        let toggled = try await sent(view).last
        XCTAssertEqual(toggled?["type"] as? String, "showResolved")
        XCTAssertEqual(toggled?["on"] as? Bool, true)
        try await render(Self.actionState(showResolved: true), in: view)
        let on = try await js("return !!document.querySelector('.pc-card[data-id=\"rs002\"] .pc-resolved-line');", in: view) as? Bool
        XCTAssertEqual(on, true)
        var none = Self.actionState()
        none["resolvedCount"] = 0
        none["threads"] = [(none["threads"] as! [[String: Any]])[0]]
        try await render(none, in: view)
        let hidden = try await js("return !!document.querySelector('.pc-show-resolved');", in: view) as? Bool
        XCTAssertEqual(hidden, false)
    }

    func testMarginFocusIsRecomputedWhenAFocusedFieldIsRedrawnAway() async throws {
        let view = try await page(try CommentFormatTests.read("resolved.md"))
        try await capture(view)
        try await render(Self.actionState(), in: view)
        _ = try await js("document.querySelector('.pc-card[data-id=\"rs001\"] .pc-input').focus(); return true;", in: view)
        var closed = Self.actionState()
        closed["activeID"] = NSNull()
        try await render(closed, in: view)
        let focus = try await sent(view).filter { $0["type"] as? String == "marginFocus" }.last
        XCTAssertEqual(focus?["on"] as? Bool, false)
    }
}
