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
    private func rig(
        _ body: String, name: String = "note.md", commentsFor: URL? = nil, extra: [String: Data] = [:], scale: CGFloat = 1,
        agentScript: Bool = false
    ) async throws -> Rig {
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
        coordinator.scale = scale
        let view = coordinator.makeWebView()
        if agentScript, let script = ViewerAgentScript.userScript() {
            view.configuration.userContentController.addUserScript(script)
        }
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

    private func js(_ script: String, in view: WKWebView, world: WKContentWorld = .page) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world)
    }

    /// What the comments script itself can do: run in its own world.
    private func commentsJS(_ script: String, in view: WKWebView) async throws -> Any? {
        try await js(script, in: view, world: ViewerCommentsScript.world)
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
        for part in [
            "object-src 'none'", "base-uri 'none'", "connect-src portico-view:", "frame-src portico-view:",
            "form-action portico-view:", "style-src 'nonce-\(nonce)'",
        ] {
            XCTAssertTrue(policy.contains(part), "\(part) in \(policy)")
        }
        XCTAssertFalse(policy.contains("unsafe-inline"))
        XCTAssertFalse(policy.contains("unsafe-eval"))
        let tags = one.matches(of: /<script[^>]*>/).map { String($0.0) }
        XCTAssertEqual(tags.count, 2, "the renderer and the page script (review H1: the comments script runs in its own world)")
        for tag in tags { XCTAssertEqual(tag, "<script nonce=\"\(nonce)\">") }
        let styles = one.matches(of: /<style[^>]*>/).map { String($0.0) }
        XCTAssertEqual(styles, ["<style nonce=\"\(nonce)\">"], "the stylesheet, comments and scale rules sit in one nonce'd style")
        let styleBody = one[one.range(of: "<style nonce")!.upperBound..<one.range(of: "</style>")!.lowerBound]
        XCTAssertTrue(styleBody.contains("#content"), "the viewer stylesheet is inside it")
        XCTAssertTrue(styleBody.contains(".pc-"), "the comments stylesheet is inside it")
        XCTAssertFalse(one.contains("window.__porticoComments = api"), "the comments script is not in the page")
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
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="9" height="4"><rect width="9" height="4" fill="red"/></svg>"#.utf8)
        let rig = try await rig(source.replacingOccurrences(of: "[site]", with: "![pic](pic.svg) [site]"), extra: ["chart.png": png, "pic.svg": svg])
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
              svg: document.querySelector('#body img[alt=pic]').naturalWidth,
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
        XCTAssertEqual(state?["svg"] as? Int, 9, "a sibling SVG still shows as an image")
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
        _ = try await commentsJS("""
            window.webkit.messageHandlers.comments.postMessage({type: 'edit', id: 'ab12c', index: 1, text: 'Reworded.',
              fp: {author: \(MarkdownPage.jsString(mine.author)), at: \(MarkdownPage.jsString(mine.at ?? "")), text: 'A reply.'}});
            return true;
            """, in: rig.view)
        try await poll("the edit is written") { self.text(rig.file).contains("Reworded.") }
        let reworded = try XCTUnwrap(CommentFormat.parse(text(rig.file)).threads.first { $0.id == "ab12c" }?.replies.last)
        _ = try await commentsJS("""
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
                "return window.__old !== true && document.readyState === 'complete' && !!document.querySelector('#body tbody td') && !!document.getElementById('pc-margin')",
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
            try {
              window.webkit.messageHandlers.comments.postMessage({type: 'ready'});
              window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged'});
            } catch (e) { window.__unreachable = true; }
            window.__posted = true;
            </script></body></html>
            """, name: "page.html", commentsFor: note)
        try await poll("the HTML page's own script ran") {
            (try? await self.js("return window.__posted === true", in: rig.view) as? Bool) == true
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(rig.comments.webView, "the handler never attached to the HTML page")
        XCTAssertEqual(try Data(contentsOf: note), before, "nothing was written")
        let unreachable = try await js("return window.__unreachable === true", in: rig.view) as? Bool
        XCTAssertEqual(unreachable, true, "review H1: the page's world has no comments handler at all")
    }

    func testAnotherMarkdownPageCannotWriteTheShownFilesComments() async throws {
        let dir = try tempDir()
        let note = dir.appendingPathComponent("shown.md")
        try Self.thread.write(to: note, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: note)
        let rig = try await rig("# Other\n", name: "other.md", commentsFor: note)
        // Even the comments script's own world, on another Markdown page, is refused.
        _ = try await commentsJS("window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged'}); return true;", in: rig.view)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try Data(contentsOf: note), before)
        XCTAssertNil(rig.comments.webView)
    }

    private func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - §11.2 space actions only on a real click

    private func spaceRig(_ body: String, name: String = "space.html") async throws -> (Rig, () -> [URL]) {
        let rig = try await rig(body, name: name)
        var activated: [URL] = []
        rig.coordinator.onSpaceAction = { activated.append($0) }
        return (rig, { activated })
    }

    private func center(of selector: String, in rig: Rig) async throws -> NSPoint {
        let rect = try await js("""
            var r = document.querySelector(\(MarkdownPage.jsString(selector))).getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """, in: rig.view) as? [Double]
        let p = try XCTUnwrap(rect)
        // Window coordinates: the view fills the window; AppKit's y runs up.
        return NSPoint(x: p[0], y: rig.view.bounds.height - p[1])
    }

    /// A real mouse click, as AppKit delivers one to the view: the page sees a trusted click.
    private func click(_ point: NSPoint, in rig: Rig) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseDown { rig.view.mouseDown(with: event) } else { rig.view.mouseUp(with: event) }
        }
    }

    func testAScriptsClickOnASpaceActionLinkRunsNothing() async throws {
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body>
            <a id="act" href="space-action:approve?item=1">Approve</a>
            <script>
            window.fire = function () { document.getElementById('act').click(); };
            window.dispatch = function () { document.getElementById('act').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true})); };
            window.later = function () { setTimeout(function () { document.getElementById('act').click(); }, 10); };
            window.go = function () { location.href = 'space-action:approve?item=1'; };
            </script></body></html>
            """)
        for call in ["fire()", "dispatch()", "later()", "go()"] {
            _ = try await js("\(call); return true;", in: rig.view)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activated(), [], "a.click(), a dispatched event, a timer and a redirect run nothing")
    }

    func testAPersonsRealClickStillRunsTheAction() async throws {
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body style="margin:0">
            <p><a id="act" href="space-action:approve?item=1" style="display:inline-block;padding:20px">Approve</a></p>
            <p><a id="other" href="space-action:archive" style="display:inline-block;padding:20px">Archive</a></p>
            <script>window.clicks = []; document.addEventListener('click', function (e) { clicks.push(e.isTrusted); });</script>
            </body></html>
            """)
        try click(try await center(of: "#act", in: rig), in: rig)
        try await poll("the person's click runs the action") { activated().count == 1 }
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:approve?item=1"])
        let trusted = try await js("return clicks", in: rig.view) as? [Bool]
        XCTAssertEqual(trusted, [true], "the test's click is a trusted one")

        // The click is used once: a script following the same link right after runs nothing.
        _ = try await js("document.getElementById('act').click(); return true;", in: rig.view)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activated().count, 1, "a click is used once")

        // A real click on one link does not let a script follow another.
        try click(try await center(of: "#act", in: rig), in: rig)
        try await poll("the second real click runs it again") { activated().count == 2 }
        _ = try await js("document.getElementById('other').click(); return true;", in: rig.view)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:approve?item=1", "space-action:approve?item=1"])
    }

    func testAPersonsRealClickRunsTheActionInAMarkdownSpace() async throws {
        let (rig, activated) = try await spaceRig("# Brief\n\n[Mark done](space-action:mark-done?item=t1)\n", name: "brief.md")
        try click(try await center(of: "#body a", in: rig), in: rig)
        try await poll("the person's click runs the action") { activated().count == 1 }
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:mark-done?item=t1"])
    }

    func testTheTrustedClickRecordIsUsedOnceAndOnlyWithinASecond() {
        var clicks = WebPane.TrustedClicks()
        let link = URL(string: "space-action:approve?item=1")!
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertFalse(clicks.take(link, at: t0), "no click recorded")
        clicks.note(link, at: t0)
        XCTAssertFalse(clicks.take(URL(string: "space-action:approve?item=2")!, at: t0), "another link")
        XCTAssertTrue(clicks.take(link, at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(clicks.take(link, at: t0.addingTimeInterval(0.6)), "used once")
        clicks.note(link, at: t0)
        XCTAssertFalse(clicks.take(link, at: t0.addingTimeInterval(1.01)), "older than a second")
        XCTAssertFalse(clicks.take(link, at: t0.addingTimeInterval(1.02)), "and gone")
        clicks.note(link, at: t0)
        XCTAssertFalse(clicks.take(link, at: t0.addingTimeInterval(-0.5)), "a click from the future is no click")
        // The scheme is matched without case, as the parser does.
        clicks.note(URL(string: "SPACE-ACTION:archive")!, at: t0)
        XCTAssertTrue(clicks.take(URL(string: "space-action:archive")!, at: t0))
    }

    func testTheClickRecorderIsOutOfThePagesReach() async throws {
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body><a id="act" href="space-action:approve?item=1">Approve</a></body></html>
            """)
        let reachable = try await js("""
            return (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(WebPane.Coordinator.spaceActionClickHandler)) ? 'yes' : 'no';
            """, in: rig.view) as? String
        XCTAssertEqual(reachable, "no", "the page's own scripts cannot post a click")
        // Even a forged post (were it reachable) followed by a.click() runs nothing.
        _ = try await js("""
            try { window.webkit.messageHandlers.\(WebPane.Coordinator.spaceActionClickHandler).postMessage({href: 'space-action:approve?item=1'}); } catch (e) {}
            document.getElementById('act').click(); return true;
            """, in: rig.view)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activated(), [])
    }

    // MARK: - Round 1 (review H1): a sibling document never shares the rendered page's origin

    private static let siblingScript = """
        var out = {};
        try { history.replaceState(null, '', '/'); out.replaced = location.href; } catch (e) { out.replaced = 'threw'; }
        try {
          window.webkit.messageHandlers.comments.postMessage({type: 'ready'});
          window.webkit.messageHandlers.comments.postMessage({type: 'reply', id: 'ab12c', text: 'forged by sibling'});
          out.posted = true;
        } catch (e) { out.posted = false; }
        fetch('/').then(function (r) { return r.text(); }).then(function (t) { out.read = t.indexOf('ab12c') >= 0; })
          .catch(function () { out.read = false; })
          .then(function () { window.__sibling = JSON.stringify(out); });
        """

    private func followSibling(_ link: String, extra: [String: Data]) async throws -> (Rig, [String: Any]) {
        let rig = try await rig(Self.thread + "\n[the docs](\(link))\n", extra: extra)
        let renderHost = try XCTUnwrap(rig.view.url?.host)
        try click(try await center(of: "#body a[href]", in: rig), in: rig)
        try await poll("the sibling has run its script") {
            (try? await self.js("return typeof window.__sibling === 'string'", in: rig.view) as? Bool) == true
        }
        let raw = try await js("return window.__sibling", in: rig.view) as? String
        let out = try JSONSerialization.jsonObject(with: Data((raw ?? "{}").utf8)) as? [String: Any] ?? [:]
        XCTAssertNotEqual(rig.view.url?.host, renderHost, "the sibling has an origin of its own: \(rig.view.url?.absoluteString ?? "")")
        return (rig, out)
    }

    func testReviewP1_aSiblingHTMLPageCannotPassTheCommentsRuleWithReplaceState() async throws {
        let html = Data("<!doctype html><html><body><p>Docs</p><script>\(Self.siblingScript)</script></body></html>".utf8)
        let (rig, out) = try await followSibling("docs.html", extra: ["docs.html": html])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try String(contentsOf: rig.file, encoding: .utf8), Self.thread + "\n[the docs](docs.html)\n", "nothing was written")
        XCTAssertEqual(out["posted"] as? Bool, false, "the page's world has no comments handler")
        XCTAssertEqual(out["read"] as? Bool, false, "fetch('/') cannot read the rendered page: \(out)")
        XCTAssertTrue(rig.coordinator.isAway(in: rig.view), "the pane knows it is off the file, even after replaceState('/')")
    }

    func testReviewP1_aSiblingSVGCannotPassTheCommentsRuleEither() async throws {
        let svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40"/><script><![CDATA[
            \(Self.siblingScript)
            ]]></script></svg>
            """.utf8)
        let (rig, out) = try await followSibling("pic.svg", extra: ["pic.svg": svg])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try String(contentsOf: rig.file, encoding: .utf8), Self.thread + "\n[the docs](pic.svg)\n", "nothing was written")
        XCTAssertEqual(out["posted"] as? Bool, false)
        XCTAssertEqual(out["read"] as? Bool, false, "\(out)")
        XCTAssertTrue(rig.coordinator.isAway(in: rig.view))
    }

    func testASiblingDocumentServedUnderTheRenderedPageNeverRunsScript() async throws {
        // Belt and braces: were one ever loaded as a document under the page's
        // render id, its response is sandboxed (no scripts, an opaque origin).
        let rig = try await rig("# Note\n", extra: ["docs.html": Data("<p>Docs</p>".utf8), "chart.png": WebPaneRenderTests.tinyPNG(width: 2, height: 2)])
        let headers = try await js("""
            var a = await fetch('/docs.html'); var b = await fetch('/chart.png');
            return [a.headers.get('Content-Security-Policy') || '', b.headers.get('Content-Security-Policy') || ''];
            """, in: rig.view) as? [String]
        XCTAssertEqual(headers?.first, "sandbox", "\(headers ?? [])")
        XCTAssertEqual(headers?.last, "", "an image is served as before")
    }

    func testAcceptsCommentsOnlyForTheMainFrameOfThePageRenderedForTheFile() throws {
        let dir = try tempDir()
        let note = dir.appendingPathComponent("note.md"), other = dir.appendingPathComponent("other.md")
        let html = dir.appendingPathComponent("page.html")
        for f in [note, other, html] { try "x".write(to: f, atomically: true, encoding: .utf8) }
        let suite = "viewer-safety-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let comments = ViewerComments(defaults: defaults)
        comments.show(file: note)
        let coordinator = WebPane.Coordinator()
        coordinator.comments = comments
        coordinator.loadedForTesting = .markdown(note)
        let page = coordinator.handler.register(page: "<p>", root: dir, source: note)
        let otherPage = coordinator.handler.register(page: "<p>", root: dir, source: other)
        let htmlPage = coordinator.handler.register(file: html)
        XCTAssertTrue(coordinator.acceptsComments(isMainFrame: true, frameURL: page))
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: false, frameURL: page), "a frame")
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: true, frameURL: otherPage), "another Markdown page")
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: true, frameURL: htmlPage), "an HTML file")
        XCTAssertFalse(
            coordinator.acceptsComments(isMainFrame: true, frameURL: URL(string: "portico-view://\(htmlPage.host!)/")!),
            "an HTML file's origin with its path rewritten to /")
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: true, frameURL: URL(string: "https://acme.example/")!), "a site")
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: true, frameURL: nil))
        coordinator.loadedForTesting = .html(html)
        XCTAssertFalse(coordinator.acceptsComments(isMainFrame: true, frameURL: page), "the pane shows something else")
    }

    // MARK: - Round 1 (review M1, L2): the page's own styles only; the cleaning covers SVG animation

    func testRawStylesAreDroppedAndThePagesOwnStylesStillApply() async throws {
        let source = """
            # Notes

            <p id="s" style="color: rgb(255, 0, 0)">styled</p>

            <style>#body h1 { color: rgb(0, 255, 0) !important }</style>

            <link rel="stylesheet" href="x.css">

            A <!--c:ab12c-->round trip<!--/c:ab12c--> here.
            <!--co:ab12c by:Sam at:2026-10-17T09:00:00.000Z status:open quote:"round trip"
            Sam (2026-10-17): Byte for byte?
            -->

            """
        let rig = try await rig(source, scale: 1.2)
        try await poll("the comments script drew its highlight") {
            (try? await self.js("return !!document.querySelector('mark.pc-anchor')", in: rig.view) as? Bool) == true
        }
        let state = try await js("""
            return {
              styleAttr: document.getElementById('s').getAttribute('style'),
              styles: document.querySelectorAll('#body style, #body link').length,
              h1: getComputedStyle(document.querySelector('#body h1')).color,
              font: getComputedStyle(document.body).fontSize,
              measure: getComputedStyle(document.getElementById('content')).maxWidth,
              mark: getComputedStyle(document.querySelector('mark.pc-anchor')).backgroundColor
            };
            """, in: rig.view) as? [String: Any]
        XCTAssertTrue(state?["styleAttr"] is NSNull, "\(state ?? [:])")
        XCTAssertEqual(state?["styles"] as? Int, 0)
        XCTAssertNotEqual(state?["h1"] as? String, "rgb(0, 255, 0)")
        XCTAssertEqual(state?["font"] as? String, "18px", "the zoom rule applies (15px × 1.2)")
        XCTAssertNotEqual(state?["measure"] as? String, "none", "the viewer stylesheet applies")
        XCTAssertNotEqual(state?["mark"] as? String, "rgba(0, 0, 0, 0)", "the comments stylesheet applies: \(state ?? [:])")
    }

    func testTheAgentsMarksStillDrawUnderThePagesStylePolicy() async throws {
        let rig = try await rig("# Elevation\n\nGains 420 m.\n", agentScript: true)
        rig.view.reload()
        try await poll("the agent's script is in") {
            (try? await self.js("return !!window.__porticoAgent && document.readyState === 'complete' && !!document.querySelector('#body h1')", in: rig.view) as? Bool) == true
        }
        let position = try await js("""
            var a = window.__porticoAgent; a.outline();
            var ref = document.querySelector('#body h1').getAttribute('data-portico-ref');
            var loc = a.markLocate(ref, a.page);
            a.showMarks([{n: 1, note: 'Here', locator: loc.locator}], '#3366ff');
            var box = document.querySelector('portico-marks').shadowRoot.querySelector('.box');
            return getComputedStyle(box).position;
            """, in: rig.view) as? String
        XCTAssertEqual(position, "absolute", "the marks' own stylesheet applies")
    }

    func testReviewP3_svgAnimationAndDataLinksAreCleaned() async throws {
        let source = """
            # Note

            <svg width="20" height="20"><a id="anim"><set attributeName="href" to="javascript:window.__ran='set'"/><animate attributeName="href" values="javascript:1"/><animateMotion dur="1s"/><animateTransform attributeName="transform"/><rect width="20" height="20"/></a></svg>

            <a id="dl" href="data:image/svg+xml,%3Csvg%3E%3C/svg%3E">pic</a> <svg><a id="xl" xlink:href="data:image/png;base64,AA"><text>x</text></a></svg>

            """
        let rig = try await rig(source)
        let state = try await js("""
            return {
              animations: document.querySelectorAll('#body set, #body animate, #body animateMotion, #body animateTransform').length,
              dl: document.getElementById('dl').getAttribute('href'),
              xl: document.getElementById('xl').getAttributeNS('http://www.w3.org/1999/xlink', 'href')
            };
            """, in: rig.view) as? [String: Any]
        XCTAssertEqual(state?["animations"] as? Int, 0, "\(state ?? [:])")
        XCTAssertTrue(state?["dl"] is NSNull, "data:image/ is allowed only in src")
        XCTAssertTrue(state?["xl"] is NSNull, "nor in xlink:href")
    }

    // MARK: - Round 1 (review M1, L1, N1): the click recorder

    func testReviewP2_anInvisibleOverlayActionLinkInAMarkdownSpaceTakesNoClick() async throws {
        let (rig, activated) = try await spaceRig("""
            # Notes

            <a href="space-action:delete?item=9" style="position:fixed;inset:0;opacity:0;z-index:99"></a>

            <a id="more" href="#notes">Read more</a>

            """, name: "notes.md")
        try click(try await center(of: "#more", in: rig), in: rig)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activated(), [], "a click meant for Read more runs nothing")
    }

    func testAnInvisibleOrCoveredLinkInAnHTMLSpaceTakesNoClick() async throws {
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body style="margin:0">
            <p><a id="more" href="#notes" style="display:inline-block;padding:20px">Read more</a></p>
            <a id="ghost" href="space-action:delete?item=9" style="position:fixed;inset:0;opacity:0.05;z-index:99"></a>
            </body></html>
            """)
        try click(try await center(of: "#more", in: rig), in: rig)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await js("""
            var g = document.getElementById('ghost'); g.style.opacity = '1'; g.style.visibility = 'hidden'; return true;
            """, in: rig.view)
        try click(try await center(of: "#more", in: rig), in: rig)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(activated(), [], "a nearly transparent or hidden link takes no click")
    }

    func testImageMapAndXlinkActionLinksTakeARealClick() async throws {
        let png = WebPaneRenderTests.tinyPNG(width: 4, height: 4).base64EncodedString()
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body style="margin:0">
            <img id="map" src="data:image/png;base64,\(png)" usemap="#m" width="100" height="100" style="display:block">
            <map name="m"><area shape="rect" coords="0,0,100,100" href="space-action:approve?item=map"></map>
            <svg width="100" height="100" style="display:block" xmlns:xlink="http://www.w3.org/1999/xlink">
              <a id="xl" xlink:href="space-action:approve?item=svg"><rect width="100" height="100" fill="blue"/></a>
            </svg>
            </body></html>
            """)
        try click(try await center(of: "#map", in: rig), in: rig)
        try await poll("the image map's click runs") { activated().count == 1 }
        try click(try await center(of: "#xl rect", in: rig), in: rig)
        try await poll("the xlink's click runs") { activated().count == 2 }
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:approve?item=map", "space-action:approve?item=svg"])
    }

    func testAPageCannotSwapTheLinkAtClickTime() async throws {
        // Review L1: the recorder listens on window, capture, from document start, so it sees the link first.
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body style="margin:0">
            <p><a id="notes" href="#top" style="display:inline-block;padding:20px">Open notes</a></p>
            <script>
            window.addEventListener('click', function (e) {
              var a = e.target.closest('a'); if (a) a.setAttribute('href', 'space-action:delete?item=42');
            }, true);
            </script></body></html>
            """)
        try click(try await center(of: "#notes", in: rig), in: rig)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(activated(), [])
    }

    /// Documented limitation (PROTOCOL.md `space.act`, CHANGELOG): the rule stops
    /// actions with no real click, but a page that runs script the deployment
    /// does not control can still steer a real one, here by swapping the link on
    /// mousedown. This asserts today's behaviour so a change to it is noticed.
    func testDocumentedLimitation_aScriptedPageCanSteerARealClickBySwappingTheLinkOnMousedown() async throws {
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body style="margin:0">
            <p><a id="notes" href="#top" style="display:inline-block;padding:20px">Open notes</a></p>
            <script>
            document.getElementById('notes').addEventListener('mousedown', function () {
              this.setAttribute('href', 'space-action:delete?item=42');
            });
            </script></body></html>
            """)
        try click(try await center(of: "#notes", in: rig), in: rig)
        try await poll("the steered click runs (the documented limitation)") { activated().count == 1 }
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:delete?item=42"])
    }

    func testReturnOnAFocusedActionLinkStillRunsIt() async throws {
        // A keyboard activation is a trusted click with no pointer position: the focused link counts.
        let (rig, activated) = try await spaceRig("""
            <!doctype html><html><body><a id="act" href="space-action:approve?item=kb">Approve</a></body></html>
            """)
        rig.window.makeFirstResponder(rig.view)
        _ = try await js("document.getElementById('act').focus(); return document.activeElement.id;", in: rig.view)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: rig.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            if type == .keyDown { rig.view.keyDown(with: event) } else { rig.view.keyUp(with: event) }
        }
        try await poll("Return on the focused link runs it") { activated().count == 1 }
        XCTAssertEqual(activated().map(\.absoluteString), ["space-action:approve?item=kb"])
    }
}
