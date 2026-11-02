import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Portico

/// v0.14 test fix (issue 2): a look, then the person opens a space and goes
/// back to Work, then a mark by the look's ref. Found live: the mark
/// answered "Not found — look again"; a second look and the same mark
/// worked. The viewer is the person's: a space and back must not reload the
/// Work page. Hosted: the real `ViewerColumn` in a borderless window.
@MainActor
final class ViewerSpaceRoundTripTests: XCTestCase {
    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-space-trip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Rig {
        let model: AppModel
        let host: NSView
        let window: NSWindow
    }

    /// Chat 1 shows `run.html` in its viewer; a space, "Brief", is listed.
    private func rig(extra: String = "") throws -> Rig {
        let dir = try tempDir()
        let page = dir.appendingPathComponent("run.html")
        try """
            <!doctype html><html><head><meta charset=utf-8><title>Runs</title></head>
            <body><h1>Acme runs</h1><button>Start Run</button><button>Stop Run</button>\(extra)</body></html>
            """.write(to: page, atomically: true, encoding: .utf8)
        let brief = dir.appendingPathComponent("brief.md")
        try "# Morning brief\n\nThree things for Priya today.".write(to: brief, atomically: true, encoding: .utf8)

        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Portico.Settings(defaults: defaults))
        model.outbound = { _ in }
        model.selected = 1
        model.viewerAgent.highlightDuration = .milliseconds(20)
        model.show(
            Artifact(id: "a-1", kind: .file, location: page.path, media: .html, title: "run.html", source: .tool, open: true),
            in: 1)
        model.apply(.spacesList(SpacesList(spaces: [
            SpaceInfo(id: "brief", title: "Brief", icon: "doc", order: nil, location: brief.path, media: "markdown",
                      updated: "2026-11-01T12:00:00Z")])))

        let host = NSHostingView(rootView: ViewerColumn(chat: 1).environmentObject(model).frame(width: 640, height: 600))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        keepAlive = [window, host, model]
        spin()
        return Rig(model: model, host: host, window: window)
    }

    private func spin(_ seconds: Double = 0.5) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }

    /// The web view showing `name`.
    private static func webView(showing name: String, in view: NSView) -> WKWebView? {
        webViews(in: view).first { $0.url?.lastPathComponent == name }
    }

    private func act(_ action: ViewerAct.Action, _ args: [String: JSONValue] = [:]) -> ViewerAct {
        ViewerAct(id: "act-\(UUID().uuidString.prefix(6))", chat: 1, action: action, args: args)
    }

    private func ref(for text: String, in outline: String) -> String {
        for row in outline.split(separator: "\n") where row.contains(text) {
            if let match = row.firstMatch(of: /\[(e\d+)\]/) { return String(match.1) }
        }
        XCTFail("no ref for \(text) in:\n\(outline)")
        return "e0"
    }

    private func perform(_ act: ViewerAct, on model: AppModel) -> ViewerResult {
        var result: ViewerResult?
        Task { result = await model.viewerAgent.perform(act) }
        let until = Date().addingTimeInterval(10)
        while result == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return result ?? ViewerResult(id: act.id, ok: false, text: "(no answer)")
    }

    private static func marks(_ targets: [String]) -> [String: JSONValue] {
        ["marks": .array(targets.map { .object(["target": .string($0)]) })]
    }

    func testASpaceAndBackKeepsTheWorkPageAndItsRefs() throws {
        let rig = try rig()
        let before = try XCTUnwrap(Self.webView(showing: "run.html", in: rig.host), "the Work page is drawn")
        let look = perform(act(.look), on: rig.model)
        XCTAssertTrue(look.ok, look.text)
        let start = ref(for: "Start Run", in: look.text)

        rig.model.openSpaceAt(1)  // the space switcher, then ⌘0
        spin()
        XCTAssertNotNil(Self.webView(showing: "brief.md", in: rig.host) ?? Self.webViews(in: rig.host).first { $0 !== before },
                        "the space is drawn")
        rig.model.openSpaceAt(0)
        spin()

        let after = try XCTUnwrap(Self.webView(showing: "run.html", in: rig.host))
        XCTAssertTrue(after === before, "the same web view: the Work page was not made again")
        let mark = perform(act(.mark, Self.marks([start])), on: rig.model)
        XCTAssertTrue(mark.ok, mark.text)
        XCTAssertTrue(mark.text.hasPrefix("Marked 1 · "), mark.text)
    }

    private static func isInside(_ responder: NSResponder?, _ view: NSView) -> Bool {
        (responder as? NSView)?.isDescendant(of: view) ?? false
    }

    /// Fix round 1 (Important 1): with the person's focus in the Work page,
    /// opening a space (⌘1–9) must take the keyboard out of the now hidden
    /// page, or typing goes into a page they cannot see.
    func testOpeningASpaceTakesTheKeyboardOutOfTheHiddenWorkPage() throws {
        let rig = try rig()
        let work = try XCTUnwrap(Self.webView(showing: "run.html", in: rig.host))
        XCTAssertTrue(rig.window.makeFirstResponder(work))
        XCTAssertTrue(Self.isInside(rig.window.firstResponder, work), "the person is in the Work page")

        rig.model.openSpaceAt(1)
        spin()
        XCTAssertFalse(Self.isInside(rig.window.firstResponder, work), "the hidden Work page has no keyboard")
    }

    /// Fix round 1 (Minor 1): the hidden Work page's media is suspended
    /// while a space is open, and resumes on the way back.
    /// A second of silence as a WAV file, inline: media for the page to hold.
    private static var silence: String {
        var data = Data()
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate: UInt32 = 8000, samples = rate
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(rate); le(rate); le(UInt16(1)); le(UInt16(8))
        data.append(contentsOf: Array("data".utf8)); le(samples)
        data.append(Data(repeating: 128, count: Int(samples)))
        return "data:audio/wav;base64," + data.base64EncodedString()
    }

    func testTheHiddenWorkPagesMediaIsSuspendedUntilWorkIsBack() throws {
        let rig = try rig(extra: "<audio id=\"clip\" loop src=\"\(Self.silence)\"></audio>")
        let work = try XCTUnwrap(Self.webView(showing: "run.html", in: rig.host))
        func state() -> WKMediaPlaybackState? {
            var answer: WKMediaPlaybackState?
            work.requestMediaPlaybackState { answer = $0 }
            let until = Date().addingTimeInterval(3)
            while answer == nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return answer
        }
        XCTAssertNotEqual(state(), .suspended, "Work shown: not suspended")
        rig.model.openSpaceAt(1)
        spin()
        XCTAssertEqual(state(), .suspended, "under the space")
        rig.model.openSpaceAt(0)
        spin()
        XCTAssertNotEqual(state(), .suspended, "Work again")
    }

    func testTheSpaceIsWhatTheAgentSeesWhileItIsOpen() throws {
        let rig = try rig()
        rig.model.openSpaceAt(1)
        spin()
        let look = perform(act(.look), on: rig.model)
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("Morning brief"), "the space, not the hidden Work page: \(look.text)")
        rig.model.openSpaceAt(0)
        spin()
        let back = perform(act(.look), on: rig.model)
        XCTAssertTrue(back.text.contains("Start Run"), "Work's page again: \(back.text)")
    }
    /// v0.15 §5.2: a link followed from inside a space to another site
    /// shows that site in the space's header, from the space's own address
    /// (not Work's); the space's page again is its name again.
    func testASpacePageThatLeavesForAnotherSiteSetsTheSpacesAddress() throws {
        let rig = try rig()
        let work = try XCTUnwrap(Self.webView(showing: "run.html", in: rig.host))
        rig.model.openSpaceAt(1)
        spin()
        let space = try XCTUnwrap(Self.webViews(in: rig.host).first { $0 !== work }, "the space is drawn")
        let until = Date().addingTimeInterval(10)
        while space.isLoading || space.url?.scheme != RenderedPageHandler.scheme, Date() < until { spin(0.05) }
        let spacePage = try XCTUnwrap(space.url)
        let spaceAddress = try XCTUnwrap((space.navigationDelegate as? WebPane.Coordinator)?.address,
                                         "the space's pane has an address to report to")
        let workAddress = (work.navigationDelegate as? WebPane.Coordinator)?.address
        XCTAssertFalse(spaceAddress === workAddress, "the space has its own address, not Work's")
        XCTAssertNil(spaceAddress.outside)

        space.loadHTMLString("<!doctype html><h1>Elsewhere</h1>", baseURL: URL(string: "https://example.com/trails/42")!)
        let away = Date().addingTimeInterval(10)
        while space.isLoading || space.url?.host != "example.com", Date() < away { spin(0.05) }
        XCTAssertEqual(spaceAddress.outside.map(ViewerPageAddress.display), "example.com/trails/42")
        XCTAssertNil(workAddress?.outside, "Work's header is untouched")

        // Back to the space's page (WebKit's own Back list is its business:
        // what is checked here is that the address follows the page home).
        space.load(URLRequest(url: spacePage))
        let back = Date().addingTimeInterval(10)
        while spaceAddress.outside != nil, Date() < back { spin(0.05) }
        XCTAssertNil(spaceAddress.outside, "the space's own page again: its name")
    }
}
