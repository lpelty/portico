import AppKit
import Foundation
import WebKit
import XCTest

@testable import Portico

/// v0.14 marks, the page-script side (spec §3.1, §6): `markLocate`,
/// `showMarks`, `scrollToMark` and `hideMarks` on `window.__porticoAgent`,
/// in a real `WKWebView` with the viewer's user script installed, as
/// `ViewerAgentTests` runs it.
@MainActor
final class ViewerMarksScriptTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    // MARK: - fixtures

    private static let accent = "#3366ff"

    private static let trail = """
        <h2>Elevation</h2>
        <p>Gains 420 m over the first two miles.</p>
        <button>Start trail</button>
        """

    /// A web view (in a borderless window that is never shown) with the
    /// viewer's script installed at document start, as `WebPane` installs it.
    private func webView(size: NSSize = NSSize(width: 800, height: 600)) throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(try XCTUnwrap(ViewerAgentScript.userScript()))
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        keepAlive.append(contentsOf: [view, window])
        return view
    }

    /// Load `body` as a fresh page and wait until it is in and the script ran.
    private func load(_ body: String, in view: WKWebView) async throws {
        let token = UUID().uuidString
        view.loadHTMLString(
            "<!doctype html><html><head><meta charset=utf-8><title>Trail</title></head><body data-load=\"\(token)\">\(body)</body></html>",
            baseURL: URL(string: "https://acme.example/trail"))
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            let ready = try? await view.callAsyncJavaScript(
                "return !!document.body && document.body.dataset.load === token && document.readyState === 'complete' && !!window.__porticoAgent",
                arguments: ["token": token], in: nil, contentWorld: .page) as? Bool
            if ready == true { return }
            if ContinuousClock.now >= deadline { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    struct Timeout: Error {}

    /// Run `body` (a function body) with `args`; whatever it returns comes
    /// back through JSON, so objects and arrays decode plainly.
    private func js(_ body: String, _ args: [String: Any] = [:], in view: WKWebView) async throws -> Any? {
        let wrapped = "return JSON.stringify((function () { \(body) })())"
        let text = try await view.callAsyncJavaScript(wrapped, arguments: args, in: nil, contentWorld: .page) as? String
        guard let data = text?.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// `js`, its answer required to be a `T`.
    private func js<T>(_ body: String, _ args: [String: Any] = [:], in view: WKWebView, as type: T.Type,
                       file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let value = try await js(body, args, in: view)
        return try XCTUnwrap(value as? T, "not a \(T.self): \(String(describing: value))", file: file, line: line)
    }

    /// Locate the h2 and the button by ref after `outline()`; their locators.
    private func locateTrail(in view: WKWebView) async throws -> [[String: Any]] {
        let answer = try await js("""
            var a = window.__porticoAgent;
            a.outline();
            var h = document.querySelector('h2').getAttribute('data-portico-ref');
            var b = document.querySelector('button').getAttribute('data-portico-ref');
            return [a.markLocate(h, a.page), a.markLocate(b, a.page)];
            """, in: view) as? [[String: Any]]
        let found = try XCTUnwrap(answer)
        XCTAssertEqual(found.count, 2)
        for item in found { XCTAssertEqual(item["ok"] as? Bool, true, "\(item)") }
        return found
    }

    private func list(_ located: [[String: Any]]) -> [[String: Any]] {
        located.enumerated().map { index, item in
            ["n": index + 1, "note": "Mark \(index + 1)", "locator": item["locator"] ?? [:]]
        }
    }

    private func show(_ list: [[String: Any]], in view: WKWebView) async throws -> [[String: Any]] {
        try await js(
            "return window.__porticoAgent.showMarks(list, accent);",
            ["list": list, "accent": Self.accent], in: view, as: [[String: Any]].self)
    }

    private func boxCount(in view: WKWebView) async throws -> Int {
        try await js("""
            var host = document.querySelector('portico-marks');
            return host ? host.shadowRoot.querySelectorAll('.box').length : 0;
            """, in: view, as: Int.self)
    }

    // MARK: - tests

    func testLocateAndShowDrawsOneBoxPerMark() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let located = try await locateTrail(in: view)
        XCTAssertEqual(located[0]["label"] as? String, "heading 2: Elevation")
        XCTAssertEqual(located[1]["label"] as? String, "button: Start trail")
        let heading = try XCTUnwrap(located[0]["locator"] as? [String: Any])
        XCTAssertEqual(heading["path"] as? String, "body > h2:nth-of-type(1)")
        XCTAssertEqual(heading["tag"] as? String, "h2")
        XCTAssertEqual(heading["text"] as? String, "Elevation")

        let shown = try await show(list(located), in: view)
        XCTAssertEqual(shown.map { $0["found"] as? Bool }, [true, true])
        let boxes = try await boxCount(in: view)
        XCTAssertEqual(boxes, 2)
        let host = try await js("""
            var host = document.querySelector('portico-marks');
            var s = getComputedStyle(host);
            var badge = host.shadowRoot.querySelector('.badge');
            var note = host.shadowRoot.querySelector('.note');
            return { parent: host.parentNode === document.documentElement, aria: host.getAttribute('aria-hidden'),
              position: s.position, events: s.pointerEvents, z: s.zIndex,
              badge: badge.textContent, note: note.textContent };
            """, in: view, as: [String: Any].self)
        XCTAssertEqual(host["parent"] as? Bool, true)
        XCTAssertEqual(host["aria"] as? String, "true")
        XCTAssertEqual(host["position"] as? String, "absolute")
        XCTAssertEqual(host["events"] as? String, "none")
        XCTAssertEqual(host["z"] as? String, "2147483647")
        XCTAssertEqual(host["badge"] as? String, "1")
        XCTAssertEqual(host["note"] as? String, "Mark 1")
    }

    func testLocateByTextExactThenPartial() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let answer = try await js("""
            var a = window.__porticoAgent;
            return [a.markLocate('Elevation'), a.markLocate('start'), a.markLocate('Nowhere'), a.markLocate('e999', a.page)];
            """, in: view, as: [[String: Any]].self)
        XCTAssertEqual(answer[0]["label"] as? String, "heading 2: Elevation")
        XCTAssertEqual(answer[1]["label"] as? String, "button: Start trail")
        XCTAssertEqual(answer[2]["notFound"] as? Bool, true)
        XCTAssertEqual(answer[3]["notFound"] as? Bool, true)
    }

    func testShowMarksReplacesNotStacks() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        for _ in 0..<3 { _ = try await show(marks, in: view) }
        let hosts = try await js("return document.querySelectorAll('portico-marks').length;", in: view) as? Int
        XCTAssertEqual(hosts, 1)
        let boxes = try await boxCount(in: view)
        XCTAssertEqual(boxes, 2)
        // An empty list removes the overlay; so does hideMarks.
        _ = try await show([], in: view)
        let afterEmpty = try await js("return document.querySelectorAll('portico-marks').length;", in: view) as? Int
        XCTAssertEqual(afterEmpty, 0)
        _ = try await show(marks, in: view)
        _ = try await js("window.__porticoAgent.hideMarks(); return 0;", in: view)
        let afterHide = try await js("return document.querySelectorAll('portico-marks').length;", in: view) as? Int
        XCTAssertEqual(afterHide, 0)
    }

    func testFindAgainAfterReload() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        try await load(Self.trail, in: view)
        let shown = try await show(marks, in: view)
        XCTAssertEqual(shown.count, 2)
        XCTAssertEqual(shown.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(shown.map { $0["found"] as? Bool }, [true, true])
        let boxes = try await boxCount(in: view)
        XCTAssertEqual(boxes, 2)
    }

    func testFindAgainByTextWhenPathMoved() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        try await load("<h2>Overview</h2>" + Self.trail, in: view)
        let shown = try await show(Array(marks.prefix(1)), in: view)
        XCTAssertEqual(shown.first?["found"] as? Bool, true)
        // The box is on "Elevation" (now the second h2), not on "Overview".
        let tops = try await js("""
            var box = document.querySelector('portico-marks').shadowRoot.querySelector('.box');
            var el = document.querySelectorAll('h2')[1];
            return [parseFloat(box.style.top), el.getBoundingClientRect().top + scrollY];
            """, in: view, as: [Double].self)
        XCTAssertEqual(tops[0], tops[1], accuracy: 1)
    }

    func testLostElement() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        try await load("<h2>Elevation</h2><p>Gains 420 m over the first two miles.</p>", in: view)
        let shown = try await show(marks, in: view)
        XCTAssertEqual(shown.map { $0["found"] as? Bool }, [true, false])
        let boxes = try await boxCount(in: view)
        XCTAssertEqual(boxes, 1)
        let badge = try await js(
            "return document.querySelector('portico-marks').shadowRoot.querySelector('.badge').textContent;", in: view) as? String
        XCTAssertEqual(badge, "1")
    }

    func testOverlayDoesNotBlockClicks() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        _ = try await show(list(try await locateTrail(in: view)), in: view)
        let answer = try await js("""
            window.clicked = 0;
            var button = document.querySelector('button');
            button.addEventListener('click', function () { window.clicked += 1; });
            var r = button.getBoundingClientRect();
            var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            if (hit) hit.click();
            return { button: hit === button, host: !!hit && hit.tagName, clicked: window.clicked };
            """, in: view, as: [String: Any].self)
        XCTAssertEqual(answer["button"] as? Bool, true, "\(answer)")
        XCTAssertEqual(answer["clicked"] as? Int, 1)
    }

    func testBoxFollowsInnerScroller() async throws {
        let view = try webView()
        try await load("""
            <h2>Elevation</h2>
            <div id="scroller" style="height:200px;overflow:auto;border:1px solid #ccc">
              <div style="height:300px">Notes</div>
              <button>Start trail</button>
              <div style="height:400px"></div>
            </div>
            """, in: view)
        _ = try await show(list(try await locateTrail(in: view)), in: view)
        _ = try await js("document.getElementById('scroller').scrollTop = 150; return 0;", in: view)
        // The scroll event is dispatched on the next rendering update. Until
        // then the button is below the scroller's bottom and its box hidden.
        let deadline = ContinuousClock.now + .seconds(5)
        var tops: [Double] = []
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            tops = try await js("""
                var box = document.querySelector('portico-marks').shadowRoot.querySelectorAll('.box')[1];
                var el = document.querySelector('button');
                var top = box.style.display === 'none' ? -1e6 : parseFloat(box.style.top);
                return [top, el.getBoundingClientRect().top + scrollY];
                """, in: view, as: [Double].self)
        } while abs(tops[0] - tops[1]) > 1 && ContinuousClock.now < deadline
        XCTAssertEqual(tops[0], tops[1], accuracy: 1)
    }

    func testNoteNeverAddsHorizontalScroll() async throws {
        let view = try webView(size: NSSize(width: 400, height: 300))
        try await load("""
            <style>body{margin:0}</style>
            <h2>Elevation</h2>
            <button style="position:absolute;right:0;top:80px;width:360px">Start trail</button>
            """, in: view)
        let located = try await locateTrail(in: view)
        let marks: [[String: Any]] = [
            ["n": 1, "note": "Gains 420 m over the first two miles of the ridge", "locator": located[1]["locator"] ?? [:]],
            ["n": 2, "note": String(repeating: "Steep switchbacks ", count: 6), "locator": located[0]["locator"] ?? [:]],
        ]
        let shown = try await show(marks, in: view)
        XCTAssertEqual(shown.map { $0["found"] as? Bool }, [true, true])
        let answer = try await js("""
            var s = document.scrollingElement;
            var notes = document.querySelector('portico-marks').shadowRoot.querySelectorAll('.note');
            var width = document.documentElement.clientWidth;
            var inside = Array.prototype.every.call(notes, function (n) {
              var r = n.getBoundingClientRect();
              return r.left >= -0.5 && r.right <= width + 0.5;
            });
            return { scrollWidth: s.scrollWidth, clientWidth: s.clientWidth, inside: inside, count: notes.length };
            """, in: view, as: [String: Any].self)
        XCTAssertEqual(answer["count"] as? Int, 2)
        XCTAssertEqual(answer["inside"] as? Bool, true, "\(answer)")
        let scrollWidth = try XCTUnwrap(answer["scrollWidth"] as? Int)
        let clientWidth = try XCTUnwrap(answer["clientWidth"] as? Int)
        XCTAssertLessThanOrEqual(scrollWidth, clientWidth, "\(answer)")
    }

    func testScrollToMark() async throws {
        let view = try webView()
        try await load("""
            <h2>Elevation</h2>
            <div style="height:2400px">Notes</div>
            <button>Start trail</button>
            <div style="height:600px"></div>
            """, in: view)
        // Only the button is marked, as mark 1.
        _ = try await show(list(Array(try await locateTrail(in: view).suffix(1))), in: view)
        let before = try await js(
            "return document.querySelector('button').getBoundingClientRect().top > innerHeight;", in: view, as: Bool.self)
        XCTAssertTrue(before, "the button starts below the fold")
        let answer = try await js("""
            var a = window.__porticoAgent;
            var ok = a.scrollToMark(1);
            var r = document.querySelector('button').getBoundingClientRect();
            return { ok: ok, inView: r.top >= 0 && r.bottom <= innerHeight, missing: a.scrollToMark(7) };
            """, in: view, as: [String: Any].self)
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["inView"] as? Bool, true)
        XCTAssertEqual(answer["missing"] as? Bool, false)
    }

    // MARK: - final fix wave (v0.14)

    /// Polls `body` (a JS function body answering a Bool) until true or `timeout`.
    private func until(_ body: String, timeout: Duration = .seconds(4), in view: WKWebView) async throws -> Bool {
        let due = ContinuousClock.now + timeout
        while ContinuousClock.now < due {
            if try await js(body, in: view) as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(30))
        }
        return try await js(body, in: view) as? Bool == true
    }

    private static let secondBoxShown = """
        var host = document.querySelector('portico-marks');
        var box = host && host.shadowRoot.querySelectorAll('.box')[1];
        return !!box && box.style.display !== 'none';
        """

    private static let secondBoxHidden = """
        var host = document.querySelector('portico-marks');
        var box = host && host.shadowRoot.querySelectorAll('.box')[1];
        return !!box && box.style.display === 'none';
        """

    /// Fix 4: a phone-frame prototype: the button scrolls out of an inner
    /// overflow:auto screen and its box (badge and note with it) is hidden;
    /// scrolled back, it shows again.
    func testBoxHiddenWhenScrolledOutOfInnerScroller() async throws {
        let view = try webView()
        try await load("""
            <h2>Elevation</h2>
            <div id="screen" style="width:300px;height:200px;overflow:auto;border:1px solid #ccc">
              <div style="height:600px">Notes</div>
              <button>Start trail</button>
              <div style="height:400px"></div>
            </div>
            """, in: view)
        _ = try await show(list(try await locateTrail(in: view)), in: view)
        let hidden = try await until(Self.secondBoxHidden, in: view)
        XCTAssertTrue(hidden, "the button is below the screen's bottom: no box floats outside it")
        let first = try await js("""
            return document.querySelector('portico-marks').shadowRoot.querySelectorAll('.box')[0].style.display !== 'none';
            """, in: view, as: Bool.self)
        XCTAssertTrue(first, "the heading, outside any scroller, keeps its box")
        _ = try await js("document.getElementById('screen').scrollTop = 520; return 0;", in: view)
        let shown = try await until(Self.secondBoxShown, in: view)
        XCTAssertTrue(shown, "scrolled into the screen, the box shows")
        _ = try await js("document.getElementById('screen').scrollTop = 0; return 0;", in: view)
        let again = try await until(Self.secondBoxHidden, in: view)
        XCTAssertTrue(again, "scrolled out again, hidden again")
    }

    /// Fix 3: a mark whose element the page builds later is drawn once it
    /// appears, and `markStatus` reports it found.
    func testLateElementIsDrawnWhenItAppears() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        try await load("<h2>Elevation</h2>", in: view)
        let shown = try await show(marks, in: view)
        XCTAssertEqual(shown.map { $0["found"] as? Bool }, [true, false])
        _ = try await js("""
            setTimeout(function () {
              var b = document.createElement('button'); b.textContent = 'Start trail'; document.body.appendChild(b);
            }, 300);
            return 0;
            """, in: view)
        let drawn = try await until("""
            var host = document.querySelector('portico-marks');
            return !!host && host.shadowRoot.querySelectorAll('.box').length === 2;
            """, in: view)
        XCTAssertTrue(drawn, "the late button gets its box")
        let status = try await js("return window.__porticoAgent.markStatus();", in: view, as: [[String: Any]].self)
        XCTAssertEqual(status.map { $0["n"] as? Int }, [1, 2])
        XCTAssertEqual(status.map { $0["found"] as? Bool }, [true, true])
    }

    /// Fix 3, bounded: the watch ends about 2 s after the marks are shown;
    /// an element that turns up later is not drawn (a redraw finds it).
    func testLateWatchEnds() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        let marks = list(try await locateTrail(in: view))
        try await load("<h2>Elevation</h2>", in: view)
        _ = try await show(marks, in: view)
        try await Task.sleep(for: .milliseconds(2600))
        _ = try await js("""
            var b = document.createElement('button'); b.textContent = 'Start trail'; document.body.appendChild(b); return 0;
            """, in: view)
        try await Task.sleep(for: .milliseconds(400))
        let boxes = try await boxCount(in: view)
        XCTAssertEqual(boxes, 1, "the watch has ended")
        let status = try await js("return window.__porticoAgent.markStatus();", in: view, as: [[String: Any]].self)
        XCTAssertEqual(status.map { $0["found"] as? Bool }, [true, false])
    }

    /// Fix 3: content inserted above a marked element moves it; its box
    /// follows within the watch (the element's size did not change, so
    /// the resize observer alone never fired).
    func testBoxFollowsContentInsertedAbove() async throws {
        let view = try webView()
        try await load(Self.trail, in: view)
        _ = try await show(list(try await locateTrail(in: view)), in: view)
        // Past the resize observer's first callback, which would place it anyway.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await js("""
            var p = document.createElement('div'); p.style.height = '150px'; p.textContent = 'Banner';
            document.body.insertBefore(p, document.body.firstChild); return 0;
            """, in: view)
        let follows = try await until("""
            var box = document.querySelector('portico-marks').shadowRoot.querySelectorAll('.box')[1];
            var el = document.querySelector('button');
            return Math.abs(parseFloat(box.style.top) - (el.getBoundingClientRect().top + scrollY)) <= 1;
            """, in: view)
        XCTAssertTrue(follows, "the box moved with its button")
    }
}
