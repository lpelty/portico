import AppKit
import Foundation
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

    private func isolatedSettings() -> Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Settings(defaults: defaults)
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
        // An uncaught error on a file:// page: WebKit hides its details
        // ("Script error.") because a file URL's origin is opaque; it is
        // still reported, so the agent knows something threw.
        XCTAssertTrue(errors.contains("Script error."), errors)
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
