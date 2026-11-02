import AppKit
import WebKit
import XCTest

@testable import Portico

/// v0.13 decision 5 (Pen AL4): after a link leaves the file, the header
/// shows the site's address.
@MainActor
final class ViewerPageAddressTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/chat/signup-form.html")

    func test_a_web_page_reached_from_a_file_is_outside() {
        let site = URL(string: "https://example.com/docs/start")!
        XCTAssertEqual(ViewerPageAddress.outside(current: site, loaded: .html(file)), site)
        XCTAssertEqual(ViewerPageAddress.outside(current: site, loaded: .markdown(file)), site)
    }

    func test_the_file_itself_and_the_opened_address_are_not_outside() {
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "portico-view://page/signup-form.html")!, loaded: .html(file)))
        XCTAssertNil(ViewerPageAddress.outside(current: file, loaded: .html(file)))
        XCTAssertNil(ViewerPageAddress.outside(current: nil, loaded: .html(file)))
        let opened = URL(string: "https://www.figma.com/file/abc")!
        XCTAssertNil(ViewerPageAddress.outside(current: opened, loaded: .url(opened)))
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "https://figma.com/login")!, loaded: .url(opened)),
                     "the opened site's own pages and redirects are not outside")
        let dev = URL(string: "http://localhost:5173/")!
        XCTAssertNil(ViewerPageAddress.outside(current: URL(string: "http://localhost:5173/settings")!, loaded: .url(dev)))
        let other = URL(string: "https://example.com/")!
        XCTAssertEqual(ViewerPageAddress.outside(current: other, loaded: .url(opened)), other)
    }

    func test_display_is_host_and_path_without_scheme_or_www() {
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/")!), "example.com")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://www.figma.com/file/abc?x=1")!), "figma.com/file/abc")
    }
}

/// v0.15 §5.1–5.2: the header's address follows a page's in-page
/// navigation (a hash change, `pushState`), which fires no commit; the
/// opened file's own anchors stay the file (Review Focus 4). A real
/// `WKWebView` in a borderless window, never shown. Needs an awake,
/// unlocked display (WebKit does not navigate normally while locked).
@MainActor
final class ViewerPageAddressNavigationTests: XCTestCase {
    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    func test_display_keeps_a_route_fragment_only() {
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/app#/settings")!), "example.com/app#/settings")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/#!/inbox")!), "example.com#!/inbox")
        // Not a route: an in-page anchor, or values (an OAuth redirect's token).
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/next#b")!), "example.com/next")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/cb#access_token=abc&state=x")!), "example.com/cb")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/cb#/done?code=1")!), "example.com/cb")
        XCTAssertEqual(ViewerPageAddress.display(URL(string: "https://example.com/cb#/a&b")!), "example.com/cb")
    }

    /// The space header's button: Open externally (the full URL) while
    /// outside, Refresh otherwise when the gateway can (v0.15 §5.2).
    func test_the_space_header_offers_open_externally_when_outside() {
        let token = URL(string: "https://example.com/cb#access_token=abc")!
        XCTAssertEqual(SpaceViewer.headerAction(outside: token, canRefresh: true), .openExternally(token),
                       "Open externally, not Refresh, and with the whole URL")
        XCTAssertEqual(SpaceViewer.headerAction(outside: token, canRefresh: false), .openExternally(token))
        XCTAssertEqual(SpaceViewer.headerAction(outside: nil, canRefresh: true), .refresh)
        XCTAssertNil(SpaceViewer.headerAction(outside: nil, canRefresh: false))
    }

    func test_the_note_follows_the_act_rule() {
        let site = URL(string: "https://www.figma.com/file/x")!
        XCTAssertEqual(ViewerPageAddress.note(for: site, actHosts: ["figma.com"]), "outside site")
        XCTAssertEqual(ViewerPageAddress.note(for: site, actHosts: []), "outside site · look and scroll only")
    }

    private struct Rig {
        let coordinator: WebPane.Coordinator
        let address: ViewerPageAddress
        let view: WKWebView
    }

    /// An HTML file with an anchor, opened in a pane wired to an address.
    private func rig() throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("trail-detail.html")
        try """
            <!doctype html><html><head><meta charset=utf-8><title>Trail</title></head>
            <body><h1>Acme trail</h1><div style="height:3000px"></div><h2 id="notes">Notes</h2></body></html>
            """.write(to: file, atomically: true, encoding: .utf8)
        let address = ViewerPageAddress()
        let coordinator = WebPane.Coordinator()
        coordinator.address = address
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = view
        keepAlive = [window, view, coordinator, address]
        coordinator.apply(.html(file), to: view)
        return Rig(coordinator: coordinator, address: address, view: view)
    }

    private func poll(_ what: String, seconds: Double = 10, _ condition: @MainActor () -> Bool) async throws {
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

    private func shown(_ rig: Rig) -> String? { rig.address.outside.map(ViewerPageAddress.display) }

    func test_an_outside_pages_hash_and_push_state_update_the_address() async throws {
        let rig = try rig()
        try await poll("the file loads") { !rig.view.isLoading && rig.view.url?.lastPathComponent == "trail-detail.html" }
        XCTAssertNil(rig.address.outside)

        // A link left the file (offline: the page as if from the site).
        rig.view.loadHTMLString(
            "<!doctype html><html><body><h1>Elsewhere</h1><h2 id=b>B</h2></body></html>",
            baseURL: URL(string: "https://example.com/start")!)
        try await poll("the outside page has loaded and is noted") {
            !rig.view.isLoading && rig.view.url?.host == "example.com" && self.shown(rig) == "example.com/start"
        }

        _ = try await rig.view.evaluateJavaScript("history.pushState({}, '', '/next'); true")
        try await poll("pushState moves the address (now \(shown(rig) ?? "nil"))") { self.shown(rig) == "example.com/next" }

        _ = try await rig.view.evaluateJavaScript("location.hash = '#/b'; true")
        try await poll("a hash route moves the address (now \(shown(rig) ?? "nil"))") { self.shown(rig) == "example.com/next#/b" }
        _ = try await rig.view.evaluateJavaScript("location.hash = '#access_token=abc'; true")
        try await poll("the token hash is followed") { rig.address.outside?.fragment == "access_token=abc" }
        XCTAssertEqual(shown(rig), "example.com/next", "a token in the hash never shows")

        _ = try await rig.view.evaluateJavaScript("history.replaceState({}, '', '/start'); true")
        try await poll("replaceState moves it too (now \(shown(rig) ?? "nil"))") { self.shown(rig) == "example.com/start" }
    }

    /// Review Focus 4: the opened file's own anchors are the file.
    func test_the_opened_files_own_anchor_is_not_outside() async throws {
        let rig = try rig()
        try await poll("the file loads") { !rig.view.isLoading && rig.view.url?.lastPathComponent == "trail-detail.html" }
        _ = try await rig.view.evaluateJavaScript("location.hash = '#notes'; true")
        try await poll("the hash is in the URL") { rig.view.url?.fragment == "notes" }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(rig.address.outside, "the file's own anchor stays the file")
        _ = try await rig.view.evaluateJavaScript("history.pushState({}, '', '#top'); true")
        try await poll("pushState on the file") { rig.view.url?.fragment == "top" }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(rig.address.outside)

        // Out and back by anchor: outside, then the file again.
        rig.view.loadHTMLString("<!doctype html><p>Away</p>", baseURL: URL(string: "https://example.com/away")!)
        try await poll("outside") { !rig.view.isLoading && rig.view.url?.host == "example.com" && self.shown(rig) == "example.com/away" }
        rig.view.goBack()
        try await poll("back at the file's anchor, not outside") {
            rig.view.url?.lastPathComponent == "trail-detail.html" && rig.address.outside == nil
        }
    }

    /// A dismantled pane lets go of the address: a later URL change in the
    /// old view writes nothing into the viewer's long-lived address.
    func test_a_dismantled_pane_no_longer_writes_the_address() async throws {
        let rig = try rig()
        try await poll("the file loads") { !rig.view.isLoading && rig.view.url?.lastPathComponent == "trail-detail.html" }
        WebPane.dismantleNSView(rig.view, coordinator: rig.coordinator)
        XCTAssertNil(rig.coordinator.address)
        rig.view.loadHTMLString("<!doctype html><p>Away</p>", baseURL: URL(string: "https://example.com/away")!)
        try await poll("the old view went on") { !rig.view.isLoading && rig.view.url?.host == "example.com" }
        XCTAssertNil(rig.address.outside, "nothing written after dismantling")
    }
}
