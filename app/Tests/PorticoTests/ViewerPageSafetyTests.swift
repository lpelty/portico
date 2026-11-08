import AppKit
import Foundation
import WebKit
import XCTest

@testable import Portico

/// v0.24 §11.1 and §11.2 (sweep #1 and #2): a viewed Markdown file runs
/// only the page's own scripts, the comments handler acts only for the page
/// rendered for the file, and a `space-action:` link runs only on the
/// person's real click. In a real `WKWebView` wired the way `WebPane` wires
/// it (a window, never shown, so the page lays out and takes mouse events).
@MainActor
final class ViewerPageSafetyTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    private final class FakeFocus: CommentsFocus {
        func isFocused(chat: Int) -> Bool { true }
        func toggleFocus(chat: Int) {}
    }

    private struct Rig {
        let coordinator: WebPane.Coordinator
        let view: WKWebView
        let window: NSWindow
        let file: URL
        let comments: ViewerComments
    }

    private static let thread = """
        # Plan

        Check the <!--c:ab12c-->round trip<!--/c:ab12c--> on every fixture.
        <!--co:ab12c by:Sam at:2026-10-17T09:00:00.000Z status:open quote:"round trip"
        Sam (2026-10-17): Byte for byte?
        -->

        """

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// `body` written to `name` and shown in a pane whose comments are for
    /// `commentsFor` (default: that same file).
    private func rig(_ body: String, name: String = "note.md", commentsFor: URL? = nil, extra: [String: Data] = [:]) async throws -> Rig {
        let dir = try tempDir()
        for (n, data) in extra { try data.write(to: dir.appendingPathComponent(n)) }
        let file = dir.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        let suite = "viewer-safety-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let comments = ViewerComments(defaults: defaults)
        let focus = FakeFocus()
        comments.focus = focus
        comments.chat = 1
        comments.helloPersonName = "Sam"
        comments.show(file: commentsFor ?? file)
        let coordinator = WebPane.Coordinator()
        coordinator.comments = comments
        let view = coordinator.makeWebView()
        let size = NSSize(width: 900, height: 700)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        keepAlive = [view, coordinator, comments, focus, window]
        let media: WebPane.Load = name.hasSuffix(".md") ? .markdown(file) : .html(file)
        coordinator.apply(media, to: view)
        try await poll("the page loads") { !view.isLoading && view.url?.scheme == RenderedPageHandler.scheme }
        try await poll("the page is complete") {
            (try? await view.evaluateJavaScript("document.readyState") as? String) == "complete"
        }
        return Rig(coordinator: coordinator, view: view, window: window, file: file, comments: comments)
    }

    private func poll(_ what: String, seconds: Double = 15, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw PollTimeout(what: what) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct PollTimeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting until \(what)" }
    }

    private func js(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - §11.1 the page runs only its own scripts

    func testInjectedScriptInMarkdownRunsNothingPostsNothingWritesNothing() async throws {
        let source = Self.thread + """
            <img src="missing.png" onerror="window.__ran = 'img'; window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged'})">

            <svg onload="window.__ran = 'svg'"><circle r="1"></circle></svg>

            <script>window.__ran = 'script'; window.webkit.messageHandlers.comments.postMessage({type: 'resolve', id: 'ab12c'})</script>

            <iframe srcdoc="<script>parent.__ran = 'frame'</script>"></iframe>

            <a id="js" href="javascript:window.__ran='link'">a link</a> <a id="vb" href=" VBScript:x">vb</a> <a id="data" href="data:text/html,hi">data</a>

            <form id="f" action="javascript:window.__ran='form'"><button id="b" formaction="javascript:window.__ran='button'">Go</button></form>

            <object data="x.swf"></object><embed src="x.swf">

            """
        let rig = try await rig(source)
        let before = Data(source.utf8)
        // The broken image's error has had time to fire.
        try await Task.sleep(for: .milliseconds(600))

        let state = try await js("""
            return {
              ran: window.__ran === undefined ? null : String(window.__ran),
              handlers: document.querySelectorAll('#body *').length === 0 ? -1 :
                Array.prototype.filter.call(document.querySelectorAll('#body *'), function (e) {
                  return Array.prototype.some.call(e.attributes, function (a) { return /^on/i.test(a.name); });
                }).length,
              scripts: document.querySelectorAll('#body script, #body iframe, #body object, #body embed').length,
              js: document.getElementById('js').getAttribute('href'),
              vb: document.getElementById('vb').getAttribute('href'),
              data: document.getElementById('data').getAttribute('href'),
              action: document.getElementById('f').getAttribute('action'),
              formaction: document.getElementById('b').getAttribute('formaction'),
              img: !!document.querySelector('#body img'),
              svg: !!document.querySelector('#body svg circle')
            };
            """, in: rig.view) as? [String: Any]
        XCTAssertTrue(state?["ran"] is NSNull, "no injected script ran: \(state ?? [:])")
        XCTAssertEqual(try Data(contentsOf: rig.file), before, "nothing was written")
        XCTAssertEqual(state?["handlers"] as? Int, 0, "every on* attribute is gone")
        XCTAssertEqual(state?["scripts"] as? Int, 0, "script, iframe, object and embed are gone")
        for key in ["js", "vb", "data", "action", "formaction"] {
            XCTAssertTrue(state?[key] is NSNull, "\(key) URL removed: \(state ?? [:])")
        }
        XCTAssertEqual(state?["img"] as? Bool, true, "the image itself stays")
        XCTAssertEqual(state?["svg"] as? Bool, true, "the svg itself stays")
    }

    func testThePageCarriesAFreshNonceCSPOnItsOwnScripts() throws {
        let one = try MarkdownPage.html(source: "# A", title: "a.md")
        let two = try MarkdownPage.html(source: "# A", title: "a.md")
        func csp(_ page: String) -> String? {
            guard let r = page.range(of: #"<meta http-equiv="Content-Security-Policy" content="([^"]*)">"#, options: .regularExpression)
            else { return nil }
            return String(page[r]).components(separatedBy: "content=\"")[1].dropLast(2).description
        }
        let policy = try XCTUnwrap(csp(one), "the page has a CSP meta tag")
        let nonce = try XCTUnwrap(policy.firstMatch(of: /script-src 'nonce-([A-Za-z0-9+\/=]+)'/)?.1).description
        XCTAssertGreaterThanOrEqual(nonce.count, 22, "at least 128 bits")
        XCTAssertNotEqual(csp(one), csp(two), "each render gets its own nonce")
        for part in ["object-src 'none'", "base-uri 'none'", "connect-src portico-view:", "frame-src portico-view:", "form-action portico-view:"] {
            XCTAssertTrue(policy.contains(part), "\(part) in \(policy)")
        }
        XCTAssertFalse(policy.contains("unsafe-inline"))
        XCTAssertFalse(policy.contains("unsafe-eval"))
        let tags = one.matches(of: /<script[^>]*>/).map { String($0.0) }
        XCTAssertEqual(tags.count, 3, "the renderer, the page script and the comments script")
        for tag in tags { XCTAssertEqual(tag, "<script nonce=\"\(nonce)\">") }
        // The CSP comes before the first script.
        XCTAssertLessThan(one.range(of: "Content-Security-Policy")!.lowerBound, one.range(of: "<script")!.lowerBound)
        // A source naming the placeholders is left as text.
        let tricky = try MarkdownPage.html(source: "{{NONCE}} {{CSP}}", title: "{{NONCE}}.md")
        XCTAssertTrue(tricky.contains("{{NONCE}}.md"), "the title keeps its braces")
    }

    func testNothingCanBeSentOutEvenFromAScriptTheAppRuns() async throws {
        let rig = try await rig("# Hello\n")
        // evaluateJavaScript is the app's own; the page's CSP still holds what it may reach.
        let directive = try await js("""
            return await new Promise(function (resolve) {
              document.addEventListener('securitypolicyviolation', function (e) { resolve(e.effectiveDirective || e.violatedDirective); }, { once: true });
              fetch('https://example.invalid/collect').catch(function () {});
              setTimeout(function () { resolve('none'); }, 3000);
            });
            """, in: rig.view) as? String
        XCTAssertEqual(directive, "connect-src")
    }

    func testOrdinaryRawHTMLStillRenders() async throws {
        let png = WebPaneRenderTests.tinyPNG(width: 7, height: 5)
        let source = """
            # Notes

            <details><summary>More</summary>

            Hidden **text**.

            </details>

            Press <kbd>⌘</kbd><kbd>K</kbd>.<br>Next line.

            | A | B |
            |---|---|
            | 1 | 2 |

            ![chart](chart.png) <img id="raw" src="chart.png" width="7"> <img id="inline" src="data:image/png;base64,\(png.base64EncodedString())">

            [site](https://example.com/) and <a id="raw-link" href="other.md#part">raw</a>

            """
        let rig = try await rig(source, extra: ["chart.png": png])
        try await Task.sleep(for: .milliseconds(300))
        let state = try await js("""
            return {
              details: !!document.querySelector('#body details summary'),
              kbd: document.querySelectorAll('#body kbd').length,
              br: document.querySelectorAll('#body br').length,
              cells: document.querySelectorAll('#body table td').length,
              chart: document.querySelector('#body img[alt=chart]').naturalWidth,
              raw: document.getElementById('raw').naturalWidth,
              inline: document.getElementById('inline').naturalWidth,
              link: document.querySelector('#body a[href^=https]').getAttribute('href'),
              rawLink: document.getElementById('raw-link').getAttribute('href')
            };
            """, in: rig.view) as? [String: Any]
        XCTAssertEqual(state?["details"] as? Bool, true)
        XCTAssertEqual(state?["kbd"] as? Int, 2)
        XCTAssertEqual(state?["br"] as? Int, 1)
        XCTAssertEqual(state?["cells"] as? Int, 2)
        XCTAssertEqual(state?["chart"] as? Int, 7, "a relative image still loads")
        XCTAssertEqual(state?["raw"] as? Int, 7)
        XCTAssertEqual(state?["inline"] as? Int, 7, "a data:image/ URL stays")
        XCTAssertEqual(state?["link"] as? String, "https://example.com/")
        XCTAssertEqual(state?["rawLink"] as? String, "other.md#part")
    }

    func testThePropertiesFoldStillReportsTheToggle() async throws {
        let rig = try await rig("---\nstatus: draft\n---\n# Note\n")
        XCTAssertFalse(rig.coordinator.propertiesOpen)
        _ = try await js("document.querySelector('details.fm').open = true; return true;", in: rig.view)
        try await poll("the toggle reaches the app") { rig.coordinator.propertiesOpen }
        let tag = try await js("return document.querySelector('details.fm').outerHTML.split('>')[0];", in: rig.view) as? String
        XCTAssertFalse(tag?.contains("ontoggle") ?? true, "no inline handler: \(tag ?? "")")
    }

    // MARK: - §11.1 the comments handler acts only for its own page

    func testCommentsStillWorkEndToEndFromThePage() async throws {
        let source = Self.thread + """
            Another paragraph with a word to note.

            | Name | Size |
            |:-----|-----:|
            | alpha | 10 |

            """
        let rig = try await rig(source)
        try await poll("the page's own comments script says it is ready") { rig.comments.webView === rig.view }
        rig.comments.setShown(true, chat: 1, focus: FakeFocus())

        // Add: select a word, Comment (the shortcut's path), type, post with the card's button.
        _ = try await js("""
            var w = document.createTreeWalker(document.getElementById('body'), NodeFilter.SHOW_TEXT), n;
            while ((n = w.nextNode())) { if (n.data.indexOf('note') >= 0) break; }
            var r = document.createRange(); r.setStart(n, n.data.indexOf('note')); r.setEnd(n, n.data.indexOf('note') + 4);
            getSelection().removeAllRanges(); getSelection().addRange(r); return true;
            """, in: rig.view)
        rig.comments.commentFromShortcut(in: rig.view)
        try await poll("the draft card shows") {
            (try? await self.js("return !!document.querySelector('.pc-draft-card textarea')", in: rig.view) as? Bool) == true
        }
        _ = try await js("""
            document.querySelector('.pc-draft-card textarea').value = 'Added here.';
            document.querySelector('.pc-draft-card .pc-post').click(); return true;
            """, in: rig.view)
        try await poll("the comment is written") { self.text(rig.file).contains("Added here.") }

        // Reply and resolve on the existing thread, from its card.
        rig.comments.activeID = "ab12c"
        rig.comments.push()
        try await poll("the thread's card is active") {
            (try? await self.js("return !!document.querySelector('.pc-card.pc-active[data-id=ab12c] textarea')", in: rig.view) as? Bool) == true
        }
        _ = try await js("""
            var t = document.querySelector('.pc-card.pc-active[data-id=ab12c] textarea'); t.value = 'A reply.';
            t.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return true;
            """, in: rig.view)
        try await poll("the reply is written") { self.text(rig.file).contains("A reply.") }
        _ = try await js("document.querySelector('.pc-card[data-id=ab12c] .pc-resolve').click(); return true;", in: rig.view)
        try await poll("the thread is resolved") { self.text(rig.file).contains("ab12c by:Sam at:2026-10-17T09:00:00.000Z status:resolved") }

        // Edit and delete the person's own reply, as the card's menu posts them.
        let edited = CommentFormat.parse(text(rig.file)).threads.first { $0.id == "ab12c" }
        let mine = try XCTUnwrap(edited?.replies.last)
        _ = try await js("""
            window.webkit.messageHandlers.comments.postMessage({type: 'edit', id: 'ab12c', index: 1, text: 'Reworded.',
              fp: {author: \(MarkdownPage.jsString(mine.author)), at: \(MarkdownPage.jsString(mine.at ?? "")), text: 'A reply.'}});
            return true;
            """, in: rig.view)
        try await poll("the edit is written") { self.text(rig.file).contains("Reworded.") }
        let reworded = try XCTUnwrap(CommentFormat.parse(text(rig.file)).threads.first { $0.id == "ab12c" }?.replies.last)
        _ = try await js("""
            window.webkit.messageHandlers.comments.postMessage({type: 'delete', id: 'ab12c', index: 1,
              fp: {author: \(MarkdownPage.jsString(reworded.author)), at: \(MarkdownPage.jsString(reworded.at ?? "")), text: 'Reworded.'}});
            return true;
            """, in: rig.view)
        try await poll("the delete is written") { !self.text(rig.file).contains("Reworded.") }

        // A table cell takes a comment too, on the page drawn again after the writes (as the viewer does).
        _ = try await js("window.__old = true; return true;", in: rig.view)
        rig.coordinator.apply(.markdown(rig.file), revision: rig.comments.paneRevision, to: rig.view)
        try await poll("the page has re-read the file") {
            (try? await self.js(
                "return window.__old !== true && document.readyState === 'complete' && !!document.querySelector('#body tbody td') && !!window.__porticoComments",
                in: rig.view) as? Bool) == true
        }
        _ = try await js("""
            var td = document.querySelectorAll('#body tbody tr')[0].children[0];
            var r = document.createRange(); r.selectNodeContents(td);
            getSelection().removeAllRanges(); getSelection().addRange(r); return true;
            """, in: rig.view)
        rig.comments.commentFromShortcut(in: rig.view)
        try await poll("the cell's draft card shows") {
            (try? await self.js("return !!document.querySelector('.pc-draft-card textarea')", in: rig.view) as? Bool) == true
        }
        _ = try await js("""
            document.querySelector('.pc-draft-card textarea').value = 'In a cell.';
            document.querySelector('.pc-draft-card .pc-post').click(); return true;
            """, in: rig.view)
        try await poll("the cell comment is written") { self.text(rig.file).contains("In a cell.") }
    }

    func testAnHTMLFileInTheViewerCannotWriteComments() async throws {
        let dir = try tempDir()
        let note = dir.appendingPathComponent("note.md")
        try Self.thread.write(to: note, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: note)
        let rig = try await rig("""
            <!doctype html><html><body><p>Page</p><script>
            window.webkit.messageHandlers.comments.postMessage({type: 'ready'});
            window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged'});
            window.__posted = true;
            </script></body></html>
            """, name: "page.html", commentsFor: note)
        try await poll("the HTML page's own script ran") {
            (try? await self.js("return window.__posted === true", in: rig.view) as? Bool) == true
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(rig.comments.webView, "the handler never attached to the HTML page")
        XCTAssertEqual(try Data(contentsOf: note), before, "nothing was written")
    }

    func testAnotherMarkdownPageCannotWriteTheShownFilesComments() async throws {
        let dir = try tempDir()
        let note = dir.appendingPathComponent("shown.md")
        try Self.thread.write(to: note, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: note)
        let rig = try await rig("# Other\n", name: "other.md", commentsFor: note)
        _ = try await js("window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged'}); return true;", in: rig.view)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try Data(contentsOf: note), before)
        XCTAssertNil(rig.comments.webView)
    }

    private func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
