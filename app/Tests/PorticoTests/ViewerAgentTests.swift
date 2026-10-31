import AppKit
import Foundation
import PDFKit
import SwiftUI
import WebKit
import XCTest

@testable import Portico

/// v0.12 viewer acting on web pages (spec §3.1, §3.2, §3.4): a real
/// `WKWebView` on fixture HTML, as `WebPaneRenderTests` drives one, with
/// the `ViewerAgent` carrying out `viewer.act` the way the app does.
@MainActor
final class ViewerAgentTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    // MARK: - fixtures

    private func isolatedSettings() -> Portico.Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Portico.Settings(defaults: defaults)
    }

    /// A model showing chat 1 (multiple presentation: no hello), with what
    /// it sends captured.
    private func model() -> (AppModel, AppModelTests.Sent) {
        let model = AppModel(settings: isolatedSettings())
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        model.selected = 1
        return (model, sent)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Rig {
        let model: AppModel
        let agent: ViewerAgent
        let view: WKWebView
        let file: URL
    }

    /// `body` written as a page (or a markdown file), shown in chat 1's
    /// viewer, with a web pane wired to the agent the way `WebPane` wires it.
    private func rig(
        _ body: String, name: String = "trail-detail.html", media: Media = .html,
        size: NSSize = NSSize(width: 800, height: 600)
    ) throws -> Rig {
        let dir = try tempDir()
        let file = dir.appendingPathComponent(name)
        let page = media == .html ? "<!doctype html><html><head><meta charset=utf-8><title>Trail detail</title></head><body>\(body)</body></html>" : body
        try page.write(to: file, atomically: true, encoding: .utf8)
        let (model, _) = model()
        model.show(
            Artifact(id: "a-1", kind: .file, location: file.path, media: media, title: name, source: .tool, open: true),
            in: 1)
        let agent = ViewerAgent(model: model)
        agent.highlightDuration = .milliseconds(20)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        // A window (never shown) so the view renders and can be snapshotted.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        keepAlive = [view, coordinator, agent, model, window]
        coordinator.apply(media == .markdown ? .markdown(file) : .html(file), to: view)
        return Rig(model: model, agent: agent, view: view, file: file)
    }

    private func act(_ action: ViewerAct.Action, _ args: [String: JSONValue] = [:], chat: Int = 1) -> ViewerAct {
        ViewerAct(id: "act-\(UUID().uuidString.prefix(6))", chat: chat, action: action, args: args)
    }

    /// The outline's ref for the line containing `text`.
    private func ref(for text: String, in outline: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        for row in outline.split(separator: "\n") where row.contains(text) {
            if let match = row.firstMatch(of: /\[(e\d+)\]/) { return String(match.1) }
        }
        XCTFail("no ref for \(text) in:\n\(outline)", file: file, line: line)
        return "e0"
    }

    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
        try await view.evaluateJavaScript(script)
    }

    // MARK: - outline

    func test_outline_lists_headings_links_buttons_fields_with_refs() async throws {
        let rig = try rig("""
            <h1>Trail detail</h1>
            <p>Plain words are not listed.</p>
            <a href="#map">Map</a>
            <button>Save trail</button>
            <label for="n">Name</label><input id="n" value="Sam">
            <input type="password" aria-label="Password" value="secret">
            <table><tr><th>Day</th><th>Miles</th></tr><tr><td>1</td><td>4</td></tr></table>
            <img alt="Ridge view" width="4" height="4" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
            <button style="display:none">Hidden</button>
            """)
        let result = await rig.agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        let text = result.text
        XCTAssertTrue(text.contains("Trail detail"), text)
        XCTAssertTrue(text.contains(rig.file.path), "what's open names the path: \(text)")
        let rows = text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[e") }
        XCTAssertEqual(rows, [
            "[e1] heading 1: Trail detail",
            "[e2] link: Map → #map",
            "[e3] button: Save trail",
            "[e4] text field: Name = \"Sam\"",
            "[e5] password field: Password",
            "[e6] table: 2 rows; columns Day, Miles",
            "[e7] image: Ridge view",
        ])
        XCTAssertFalse(text.contains("secret"), "a password's value never reaches the agent")
        XCTAssertFalse(text.contains("Plain words"))
        XCTAssertFalse(text.contains("Hidden"), "what the person can't see is not listed")
        let written = try await evaluate("document.querySelector('button').getAttribute('data-portico-ref')", in: rig.view)
        XCTAssertEqual(written as? String, "e3", "refs are written to the elements")
        XCTAssertEqual(result.image?.mediaType, "image/png")
        XCTAssertFalse(result.image?.data.isEmpty ?? true, "a look carries the snapshot")
    }

    func test_outline_caps_at_300_lines() async throws {
        let buttons = (1...350).map { "<button>Item \($0)</button>" }.joined(separator: "\n")
        let rig = try rig(buttons)
        let result = await rig.agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        let rows = result.text.split(separator: "\n").filter { $0.hasPrefix("[e") }
        XCTAssertEqual(rows.count, 300)
        XCTAssertEqual(rows.last.map(String.init), "[e300] button: Item 300")
        XCTAssertTrue(result.text.contains("… 50 more"), result.text)
    }

    func test_markdown_page_outline_includes_properties_block() async throws {
        let rig = try rig(
            "---\ntitle: Round 2\nstatus: draft\ntags: [a, b]\n---\n# Round 2\n\nSee [the plan](plan.md).\n",
            name: "note.md", media: .markdown)
        let result = await rig.agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        let rows = result.text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[e") }
        XCTAssertEqual(rows.first, "[e1] properties: title: Round 2 · status: draft · tags: a, b", result.text)
        XCTAssertTrue(rows.contains("[e2] heading 1: Round 2"), result.text)
        XCTAssertTrue(rows.contains("[e3] link: the plan → plan.md"), result.text)
    }

    // MARK: - click and type

    func test_click_by_ref_and_by_text() async throws {
        let rig = try rig("""
            <script>window.clicks = []</script>
            <button onclick="clicks.push('save')">Save trail</button>
            <a href="#" onclick="clicks.push('cancel'); return false">Cancel</a>
            """)
        let look = await rig.agent.perform(act(.look))
        let save = ref(for: "Save trail", in: look.text)

        let byRef = await rig.agent.perform(act(.click, ["target": .string(save)]))
        XCTAssertTrue(byRef.ok, byRef.text)
        XCTAssertTrue(byRef.text.contains("Save trail"), byRef.text)
        let byText = await rig.agent.perform(act(.click, ["target": .string("cancel")]))
        XCTAssertTrue(byText.ok, byText.text)

        let clicks = try await evaluate("clicks.join(',')", in: rig.view)
        XCTAssertEqual(clicks as? String, "save,cancel")
        XCTAssertNil(byRef.image, "only a look carries an image")
    }

    func test_type_sets_value_fires_input_change_and_submit() async throws {
        let rig = try rig("""
            <script>window.events = []</script>
            <form onsubmit="events.push('submit'); return false">
              <input id="q" aria-label="Search" oninput="events.push('input:' + this.value)" onchange="events.push('change')">
            </form>
            <textarea aria-label="Notes" oninput="events.push('notes')"></textarea>
            """)
        let look = await rig.agent.perform(act(.look))
        let search = ref(for: "Search", in: look.text)

        let typed = await rig.agent.perform(act(.type, ["target": .string(search), "text": .string("Priya"), "submit": .bool(true)]))
        XCTAssertTrue(typed.ok, typed.text)
        let value = try await evaluate("document.getElementById('q').value", in: rig.view)
        XCTAssertEqual(value as? String, "Priya")
        let events = try await evaluate("events.join(',')", in: rig.view)
        XCTAssertEqual(events as? String, "input:Priya,change,submit")

        let notes = await rig.agent.perform(act(.type, ["target": .string("Notes"), "text": .string("Jordan's route")]))
        XCTAssertTrue(notes.ok, notes.text)
        let area = try await evaluate("document.querySelector('textarea').value", in: rig.view)
        XCTAssertEqual(area as? String, "Jordan's route")
    }

    func test_stale_ref_answers_not_found_look_again() async throws {
        let rig = try rig("<button>Save trail</button><button>Delete</button>")
        let look = await rig.agent.perform(act(.look))
        let save = ref(for: "Save trail", in: look.text)
        _ = try await evaluate("document.querySelector('button').remove(); true", in: rig.view)

        let gone = await rig.agent.perform(act(.click, ["target": .string(save)]))
        XCTAssertFalse(gone.ok)
        XCTAssertEqual(gone.text, "Not found — look again")
        let unknown = await rig.agent.perform(act(.click, ["target": .string("e999")]))
        XCTAssertEqual(unknown.text, "Not found — look again")
        let noText = await rig.agent.perform(act(.type, ["target": .string("Nowhere"), "text": .string("x")]))
        XCTAssertEqual(noText.text, "Not found — look again")

        // Another page (the person navigated): a ref from the last look
        // never lands on the new page's element, even one carrying it.
        let delete = ref(for: "Delete", in: look.text)
        _ = try await evaluate(
            "window.__porticoAgent.page = 'another'; true", in: rig.view)
        let moved = await rig.agent.perform(act(.click, ["target": .string(delete)]))
        XCTAssertEqual(moved.text, "Not found — look again")
    }

    // MARK: - page errors

    func test_errors_captured_and_cleared() async throws {
        let long = String(repeating: "x", count: 500)
        let rig = try rig("""
            <script>
            console.error('boom', 42);
            for (let i = 0; i < 25; i++) console.error('many ' + i);
            console.error('\(long)');
            Promise.reject(new Error('nope'));
            </script>
            <script>throw new Error('late failure')</script>
            <h1>Errors</h1>
            """)
        // Let the unhandled rejection be reported.
        try await Task.sleep(for: .milliseconds(200))
        let first = await rig.agent.perform(act(.look))
        XCTAssertTrue(first.ok, first.text)
        let errors = first.text.components(separatedBy: "Page errors since the last look:").last ?? ""
        let lines = errors.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(lines.count, 20, "the last 20: \(errors)")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 202 }, "each cut to 200 characters")
        // An uncaught error on the agent's own page keeps its message
        // (WebKit says only "Script error." for an opaque file:// origin).
        XCTAssertNotNil(errors.firstMatch(of: /Error: late failure \(line \d+\)/), errors)
        XCTAssertFalse(errors.contains("Script error."), errors)
        XCTAssertTrue(errors.contains("nope"), errors)
        XCTAssertFalse(errors.contains("boom"), "older than the last 20")

        let second = await rig.agent.perform(act(.look))
        XCTAssertTrue(second.text.contains("Page errors since the last look: none."), second.text)
    }

    // MARK: - the image

    func test_snapshot_longer_side_at_most_1600() async throws {
        let rig = try rig("<h1 style='font-size:200px'>Wide</h1>", size: NSSize(width: 2000, height: 900))
        let result = await rig.agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        let data = try XCTUnwrap(result.image.flatMap { Data(base64Encoded: $0.data) })
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), 1600)
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 2000.0 / 900.0, accuracy: 0.02)

        // The scaling itself: a large image comes down, a small one stays.
        let big = try XCTUnwrap(Self.image(width: 3200, height: 800))
        let bigPNG = try XCTUnwrap(ViewerSnapshot.png(big))
        let bigRep = try XCTUnwrap(NSBitmapImageRep(data: bigPNG))
        XCTAssertEqual([bigRep.pixelsWide, bigRep.pixelsHigh], [1600, 400])
        let small = try XCTUnwrap(Self.image(width: 800, height: 600))
        let smallRep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(ViewerSnapshot.png(small))))
        XCTAssertEqual([smallRep.pixelsWide, smallRep.pixelsHigh], [800, 600])
    }

    private static func image(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    // MARK: - when the agent can't act

    func test_nothing_open_answers_nothing_open() async throws {
        let (model, _) = model()
        let agent = ViewerAgent(model: model)
        let result = await agent.perform(act(.look))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "Nothing is open in the viewer.")
    }

    func test_setting_off_answers_setting_off_text() async throws {
        let (model, _) = model()
        model.settings.viewerAgentCanSee = false
        let agent = ViewerAgent(model: model)
        let result = await agent.perform(act(.look))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "The person has turned off the agent's view of the viewer in Settings.")
    }

    func test_another_chat_in_multiple_presentation() async throws {
        let (model, _) = model()
        let agent = ViewerAgent(model: model)
        let result = await agent.perform(act(.look, chat: 2))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "The person is looking at another chat.")
    }

    func test_native_pane_can_be_looked_at_not_used() async throws {
        let (model, _) = model()
        let dir = try tempDir()
        let file = dir.appendingPathComponent("route.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: file)
        model.show(Artifact(id: "a-2", kind: .file, location: file.path, media: .image, title: "route.png", source: .tool, open: true), in: 1)
        let agent = ViewerAgent(model: model)
        let click = await agent.perform(act(.click, ["target": .string("e1")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, "This is an image; it can be looked at, not used.")
        let typed = await agent.perform(act(.type, ["target": .string("e1"), "text": .string("x")]))
        XCTAssertEqual(typed.text, "This is an image; it can be looked at, not used.")
    }

    func test_hidden_viewer_slides_open_for_an_act() async throws {
        let rig = try rig("<h1>Shown</h1>")
        rig.model.setViewer(visible: false, for: 1)
        let result = await rig.agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertTrue(rig.model.isViewerShown(for: 1), "the agent never drives a viewer the person can't see")
    }

    func test_acting_label_shows_then_clears_after_the_last_action() async throws {
        let rig = try rig("<button>Go</button>")
        rig.agent.labelLinger = .milliseconds(150)
        _ = await rig.agent.perform(act(.look))
        XCTAssertEqual(rig.agent.actingChat, 1, "the header says the agent is using the viewer")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(rig.agent.actingChat, "clears after the last action")
    }

    // MARK: - fix round 1

    /// The document view has the window: the act leaves it, the viewer
    /// slides open, and the look succeeds (spec §3.1).
    func test_act_in_document_mode_leaves_the_document_view_and_looks() async throws {
        let rig = try rig("<h1>Shown</h1>")
        rig.model.openDocumentView()
        XCTAssertTrue(rig.model.documentMode)
        let result = await rig.agent.perform(act(.look))
        XCTAssertFalse(rig.model.documentMode, "the person sees the viewer the agent uses")
        XCTAssertTrue(result.ok, result.text)
        XCTAssertTrue(rig.model.isViewerShown(for: 1))
    }

    /// A page whose script never answers can't hang the act or leave the
    /// label up: one deadline for the whole act.
    func test_a_stuck_page_answers_within_the_deadline_and_the_label_clears() async throws {
        let rig = try rig("<button>Go</button>")
        rig.agent.actWait = .milliseconds(1500)
        rig.agent.labelLinger = .milliseconds(50)
        _ = await rig.agent.perform(act(.look))
        // A page busy in a loop for 4 s (longer than the act's 1.5 s).
        _ = try await evaluate(
            "window.__porticoAgent.click = () => { const end = Date.now() + 4000; while (Date.now() < end) {} return {ok: true, label: 'x'} }; true",
            in: rig.view)
        let start = ContinuousClock.now
        let stuck = await rig.agent.perform(act(.click, ["target": .string("Go")]))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "answered at the deadline, not hung")
        XCTAssertFalse(stuck.ok)
        XCTAssertEqual(stuck.text, "The viewer didn't answer in 10 s.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(rig.agent.actingChat)
    }

    func test_a_pane_that_never_appears_answers_within_the_deadline() async throws {
        let (model, _) = model()
        let dir = try tempDir()
        let file = dir.appendingPathComponent("never.html")
        try "<h1>x</h1>".write(to: file, atomically: true, encoding: .utf8)
        model.show(Artifact(id: "a-3", kind: .file, location: file.path, media: .html, title: "never.html", source: .tool, open: true), in: 1)
        let agent = ViewerAgent(model: model)
        agent.actWait = .milliseconds(300)
        let start = ContinuousClock.now
        let result = await agent.perform(act(.look))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(result.text, "The viewer didn't answer in 10 s.")
    }

    /// A page that replaces `window.__porticoAgent` gets the script back.
    func test_a_page_that_overwrites_the_agent_object_gets_the_script_again() async throws {
        let rig = try rig("<button>Save trail</button>")
        _ = await rig.agent.perform(act(.look))
        _ = try await evaluate("window.__porticoAgent = {outline: () => 'fake'}; true", in: rig.view)
        let look = await rig.agent.perform(act(.look))
        XCTAssertTrue(look.text.contains("button: Save trail"), look.text)
        let clicked = await rig.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertTrue(clicked.ok, clicked.text)
    }

    /// The looked-page token is the chat's: a look in one chat never
    /// vouches for refs in another.
    func test_looked_page_is_kept_per_chat() async throws {
        let rig = try rig("<button>Save trail</button>")
        _ = await rig.agent.perform(act(.look))
        XCTAssertNotNil(rig.agent.lookedPages[1])
        XCTAssertNil(rig.agent.lookedPages[2])
        let page = try await evaluate("window.__porticoAgent.page", in: rig.view) as? String
        XCTAssertEqual(rig.agent.lookedPages[1], page)
    }

    // MARK: - outside sites (spec §3.6)

    /// The deployment's `act_hosts`, as the gateway's hello carries them.
    private func allow(_ hosts: [String], on model: AppModel) {
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.12.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["viewer.v1"], presentation: "multiple",
            viewerDefaults: ViewerDefaults(actHosts: hosts))))
        model.selected = 1
    }

    /// A URL artifact in chat 1's viewer, its page `body` loaded offline
    /// as if from `url` (no network in tests).
    private func urlRig(_ body: String, at url: URL, actHosts: [String]) throws -> Rig {
        let (model, _) = model()
        allow(actHosts, on: model)
        model.show(Artifact(id: "u-1", kind: .url, location: url.absoluteString, media: .url, title: url.host ?? "", source: .tool, open: true), in: 1)
        let agent = ViewerAgent(model: model)
        agent.highlightDuration = .milliseconds(20)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = view
        keepAlive = [view, coordinator, agent, model, window]
        agent.attach(view, showing: .url(url))
        view.loadHTMLString(Self.page(body), baseURL: url)
        return Rig(model: model, agent: agent, view: view, file: URL(fileURLWithPath: "/"))
    }

    private static func page(_ body: String) -> String {
        "<!doctype html><html><head><meta charset=utf-8><title>Outside</title></head><body>\(body)</body></html>"
    }

    private static let outsideText = { (host: String) in
        "This page (\(host)) can be looked at and scrolled, not used. The deployment's allow list sets which sites the agent can click and type on."
    }

    func test_can_act_rules() throws {
        let hosts = ["figma.com", "lovable.dev"]
        let table: [(String, [String], Bool)] = [
            ("file:///tmp/trail-detail.html", [], true),
            ("portico-view://abc/trail-detail.html", [], true),
            ("http://localhost:3000/", [], true),
            ("http://127.0.0.1:8080/app", [], true),
            ("http://[::1]:5173/", [], true),
            ("https://www.figma.com/file/x", hosts, true),
            ("https://figma.com/", hosts, true),
            ("https://FIGMA.COM/", hosts, true),
            ("https://www.figma.com/", ["FIGMA.com"], true),
            ("https://notfigma.com/", hosts, false),
            ("https://figma.com.example.com/", hosts, false),
            ("https://lovable.dev/projects", hosts, true),
            ("https://example.com/", hosts, false),
            ("https://example.com/", [], false),
            ("about:blank", hosts, false),
        ]
        for (string, list, expected) in table {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(ViewerAgent.canAct(url: url, actHosts: list), expected, "\(string) with \(list)")
        }
    }

    func test_outside_host_click_refused_with_spec_text() async throws {
        let rig = try urlRig(
            "<script>window.clicks = []</script><button onclick=\"clicks.push('save')\">Save trail</button><input aria-label=\"Search\">",
            at: URL(string: "https://example.com/trails")!, actHosts: ["figma.com"])
        let look = await rig.agent.perform(act(.look))
        XCTAssertTrue(look.ok, "an outside page can be looked at: \(look.text)")
        XCTAssertTrue(look.text.contains("button: Save trail"), look.text)
        let scroll = await rig.agent.perform(act(.scroll, ["direction": .string("down")]))
        XCTAssertTrue(scroll.ok, "and scrolled: \(scroll.text)")

        let click = await rig.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, Self.outsideText("example.com"))
        let typed = await rig.agent.perform(act(.type, ["target": .string("Search"), "text": .string("Priya")]))
        XCTAssertFalse(typed.ok)
        XCTAssertEqual(typed.text, Self.outsideText("example.com"))
        let clicks = try await evaluate("clicks.length", in: rig.view)
        XCTAssertEqual(clicks as? Int, 0, "nothing was clicked")

        // A host on the list (or under it) is usable.
        let allowed = try urlRig(
            "<script>window.clicks = []</script><button onclick=\"clicks.push('save')\">Save trail</button>",
            at: URL(string: "https://www.figma.com/file/x")!, actHosts: ["figma.com"])
        let ok = await allowed.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertTrue(ok.ok, ok.text)
    }

    /// Checked on the page's current host at every click: a redirect or a
    /// link away from an allowed page is refused for the new host.
    func test_redirect_to_other_host_rechecked() async throws {
        let outside = try urlRig(
            "<button>Save trail</button>", at: URL(string: "https://www.figma.com/file/x")!, actHosts: ["figma.com"])
        let first = await outside.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertTrue(first.ok, first.text)

        // The page went elsewhere (same artifact; the view's URL moved).
        outside.view.loadHTMLString(Self.page("<button>Save trail</button>"), baseURL: URL(string: "https://example.com/landing")!)
        let moved = await outside.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertFalse(moved.ok)
        XCTAssertEqual(moved.text, Self.outsideText("example.com"))

        // The agent's own page that links out: refused there too.
        let local = try rig("<button>Go</button>")
        allow([], on: local.model)
        let here = await local.agent.perform(act(.click, ["target": .string("Go")]))
        XCTAssertTrue(here.ok, "the agent's own page is usable: \(here.text)")
        local.view.loadHTMLString(Self.page("<button>Go</button>"), baseURL: URL(string: "https://lovable.dev/p")!)
        let away = await local.agent.perform(act(.click, ["target": .string("Go")]))
        XCTAssertEqual(away.text, Self.outsideText("lovable.dev"))
    }

    /// The person's input wins: they scroll mid-turn, and the next look
    /// shows the page where they left it.
    func test_person_scroll_then_look_sees_new_position() async throws {
        let rig = try rig("""
            <style>body{margin:0} div{height:1500px}</style>
            <div style="background:#ff0000"></div><div style="background:#0000ff"></div>
            """)
        let top = await rig.agent.perform(act(.look))
        XCTAssertEqual(try Self.middleColour(top), "red")
        _ = try await evaluate("window.scrollTo(0, document.body.scrollHeight); true", in: rig.view)
        try await Task.sleep(for: .milliseconds(100))
        let after = await rig.agent.perform(act(.look))
        XCTAssertEqual(try Self.middleColour(after), "blue", "the look sees where the person scrolled")
    }

    private static func middleColour(_ result: ViewerResult) throws -> String {
        let data = try XCTUnwrap(result.image.flatMap { Data(base64Encoded: $0.data) }, result.text)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let colour = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        if colour.redComponent > 0.8, colour.blueComponent < 0.3 { return "red" }
        if colour.blueComponent > 0.8, colour.redComponent < 0.3 { return "blue" }
        return "\(colour)"
    }

    // MARK: - native panes (spec §3.2)

    /// `artifact` drawn by the viewer's own panes in a window, the agent
    /// in their environment as `ViewerView` sets it.
    private func nativeRig(_ artifact: Artifact, size: NSSize = NSSize(width: 700, height: 500)) -> (AppModel, ViewerAgent) {
        let (model, _) = model()
        model.show(artifact, in: 1)
        let agent = ViewerAgent(model: model)
        let host = NSHostingView(rootView: ArtifactContent(artifact: artifact).environment(\.viewerAgent, agent))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        keepAlive = [host, agent, model, window]
        return (model, agent)
    }

    /// A one-page PDF whose text is `w00001 w00002 …` up to `words`.
    private func pdf(words: Int) throws -> URL {
        let file = try tempDir().appendingPathComponent("route.pdf")
        let text = (1...words).map { String(format: "w%05d", $0) }.joined(separator: " ")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 5)])
            .draw(in: box.insetBy(dx: 20, dy: 20))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: file)
        return file
    }

    func test_pdf_look_text_capped_4000() async throws {
        let file = try pdf(words: 1200)
        XCTAssertGreaterThan(PDFDocument(url: file)?.page(at: 0)?.string?.count ?? 0, 6000, "fixture holds more than the cap")
        let (_, agent) = nativeRig(Artifact(id: "p-1", kind: .file, location: file.path, media: .pdf, title: "route.pdf", source: .tool, open: true))
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("1 page"), look.text)
        let visible = try XCTUnwrap(look.text.components(separatedBy: "Text on the visible pages:\n").last)
        let body = visible.components(separatedBy: "\n… cut at 4,000 characters").first ?? visible
        XCTAssertLessThanOrEqual(body.count, 4000)
        XCTAssertGreaterThan(body.count, 3900, "as much as the cap allows")
        XCTAssertTrue(body.hasPrefix("w00001 w00002"), String(body.prefix(40)))
        XCTAssertFalse(look.text.contains("w01200"), "past the cap is not sent")
        XCTAssertTrue(look.text.contains("… cut at 4,000 characters"), "says it was cut")
        XCTAssertNotNil(look.image, "a look carries the snapshot")

        let click = await agent.perform(act(.click, ["target": .string("w00001")]))
        XCTAssertEqual(click.text, "This is a PDF; it can be looked at, not used.")
    }

    func test_pdf_scrolls() async throws {
        let first = try pdf(words: 50)
        // Three pages: page 1 stays, two more copies after it.
        let doc = try XCTUnwrap(PDFDocument(url: first))
        for index in 1...2 { doc.insert(try XCTUnwrap(doc.page(at: 0)?.copy() as? PDFPage), at: index) }
        XCTAssertTrue(doc.write(to: first))
        let (_, agent) = nativeRig(Artifact(id: "p-2", kind: .file, location: first.path, media: .pdf, title: "route.pdf", source: .tool, open: true))
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.text.contains("3 pages"), look.text)
        XCTAssertTrue(look.text.contains("showing page 1"), look.text)
        let bottom = await agent.perform(act(.scroll, ["direction": .string("bottom")]))
        XCTAssertTrue(bottom.ok, bottom.text)
        XCTAssertTrue(bottom.text.contains("page 3 of 3"), bottom.text)
        let top = await agent.perform(act(.scroll, ["direction": .string("top")]))
        XCTAssertTrue(top.text.contains("page 1 of 3"), top.text)
    }

    func test_text_look_lists_visible_lines_and_scrolls() async throws {
        let file = try tempDir().appendingPathComponent("notes.txt")
        try (1...400).map { "line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let (_, agent) = nativeRig(Artifact(id: "t-1", kind: .file, location: file.path, media: .text, title: "notes.txt", source: .tool, open: true))
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("This is a text file."), look.text)
        XCTAssertTrue(look.text.contains("\nline 1\n"), look.text)
        XCTAssertFalse(look.text.contains("line 300"), "only the visible lines: \(look.text)")
        XCTAssertTrue(look.text.contains("of 400"), look.text)

        let down = await agent.perform(act(.scroll, ["direction": .string("down")]))
        XCTAssertTrue(down.ok, down.text)
        let next = await agent.perform(act(.look))
        XCTAssertFalse(next.text.contains("\nline 1\n"), "scrolled past the first lines: \(next.text)")
        let bottom = await agent.perform(act(.scroll, ["direction": .string("bottom")]))
        XCTAssertTrue(bottom.ok, bottom.text)
        let end = await agent.perform(act(.look))
        XCTAssertTrue(end.text.contains("line 400"), end.text)
        let typed = await agent.perform(act(.type, ["target": .string("line 1"), "text": .string("x")]))
        XCTAssertEqual(typed.text, "This is a text file; it can be looked at, not used.")
    }

    func test_table_look_lists_visible_rows() async throws {
        let file = try tempDir().appendingPathComponent("miles.csv")
        try (["day,miles"] + (1...300).map { "\($0),\($0 * 2)" }).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let (_, agent) = nativeRig(Artifact(id: "c-1", kind: .file, location: file.path, media: .text, title: "miles.csv", source: .tool, open: true))
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("This is a table."), look.text)
        XCTAssertTrue(look.text.contains("day\tmiles"), look.text)
        XCTAssertTrue(look.text.contains("\n1\t2\n"), look.text)
        XCTAssertFalse(look.text.contains("\n250\t500"), look.text)
        XCTAssertTrue(look.text.contains("of 300"), look.text)
        let bottom = await agent.perform(act(.scroll, ["direction": .string("bottom")]))
        XCTAssertTrue(bottom.ok, bottom.text)
        let end = await agent.perform(act(.look))
        XCTAssertTrue(end.text.contains("300\t600"), end.text)
    }

    /// A text file that can't be read draws a message, never a text view:
    /// the look answers soon, not at the act's deadline.
    func test_unreadable_text_look_answers_soon() async throws {
        let file = try tempDir().appendingPathComponent("blob.txt")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x00, 0xFF]).write(to: file)
        let (_, agent) = nativeRig(Artifact(id: "t-2", kind: .file, location: file.path, media: .text, title: "blob.txt", source: .tool, open: true))
        agent.nativeWait = .milliseconds(300)
        let start = ContinuousClock.now
        let look = await agent.perform(act(.look))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("This is a text file."), look.text)
    }

    func test_image_click_not_used() async throws {
        let file = try tempDir().appendingPathComponent("ridge.png")
        let png = try XCTUnwrap(ViewerSnapshot.png(try XCTUnwrap(Self.image(width: 40, height: 30))))
        try png.write(to: file)
        let (_, agent) = nativeRig(Artifact(id: "i-1", kind: .file, location: file.path, media: .image, title: "ridge.png", source: .tool, open: true))
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertTrue(look.text.contains("40 × 30 pixels"), look.text)
        XCTAssertNotNil(look.image)
        let click = await agent.perform(act(.click, ["target": .string("e1")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, "This is an image; it can be looked at, not used.")
        let typed = await agent.perform(act(.type, ["target": .string("e1"), "text": .string("x")]))
        XCTAssertEqual(typed.text, "This is an image; it can be looked at, not used.")
    }

    // MARK: - wiring

    func test_viewer_act_from_the_gateway_is_answered_with_viewer_result() async throws {
        let (model, sent) = model()
        model.apply(.viewerAct(ViewerAct(id: "act-9", chat: 1, action: .look)))
        let deadline = ContinuousClock.now + .seconds(5)
        var answer: ViewerResult?
        while answer == nil, ContinuousClock.now < deadline {
            answer = sent.frames.lazy.compactMap { if case .viewerResult(let r) = $0 { r } else { nil } }.first
            if answer == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(answer?.id, "act-9")
        XCTAssertEqual(answer?.ok, false)
        XCTAssertEqual(answer?.text, "Nothing is open in the viewer.")
    }
}
