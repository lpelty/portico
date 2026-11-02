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
    private func rig() throws -> Rig {
        let dir = try tempDir()
        let page = dir.appendingPathComponent("run.html")
        try """
            <!doctype html><html><head><meta charset=utf-8><title>Runs</title></head>
            <body><h1>Acme runs</h1><button>Start Run</button><button>Stop Run</button></body></html>
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
}
