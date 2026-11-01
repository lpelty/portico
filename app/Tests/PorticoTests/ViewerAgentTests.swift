import AppKit
import Combine
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
        var coordinator: WebPane.Coordinator? = nil
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
        return Rig(model: model, agent: agent, view: view, file: file, coordinator: coordinator)
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

    // MARK: - a space open

    func test_look_with_a_space_open_sees_the_space() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("brief.md")
        try "# Morning brief\n\nThree things today.".write(to: file, atomically: true, encoding: .utf8)
        let (model, _) = model()
        // The chat has its own file open; the space is the window's.
        model.show(Artifact(id: "a-1", kind: .file, location: "/tmp/other.md", media: .markdown, title: "other.md", source: .tool, open: true), in: 1)
        model.apply(.spacesList(SpacesList(spaces: [
            SpaceInfo(id: "brief", title: "Brief", icon: "doc", order: nil, location: file.path, media: "markdown", updated: "2026-10-31T12:00:00Z")])))
        model.openSpaceAt(1)
        let agent = ViewerAgent(model: model)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let size = NSSize(width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        keepAlive = [view, coordinator, agent, model, window]
        // The pane loads what the viewer would draw for the open space.
        let load = try XCTUnwrap(WebPane.Load(ArtifactPresentation(artifact: try XCTUnwrap(model.openSpaceArtifact))))
        coordinator.apply(load, to: view)
        let result = await agent.perform(act(.look))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertTrue(result.text.contains("Morning brief"), result.text)
        XCTAssertTrue(result.text.contains(file.path), "names the space's file, not the chat's: \(result.text)")
        XCTAssertFalse(result.text.contains("/tmp/other.md"))
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

    /// Found live 10-31: the page's `focus()` made the web view the
    /// window's first responder, so what the person typed in the composer
    /// while the agent worked went into the page.
    func test_type_and_click_leave_the_keyboard_where_the_person_had_it() async throws {
        let rig = try rig(#"<input aria-label="Name"><button onclick="this.textContent='Done'">Sign up</button>"#)
        let window = try XCTUnwrap(rig.view.window)
        let container = NSView(frame: window.contentView?.frame ?? .zero)
        let composer = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        rig.view.removeFromSuperview()
        container.addSubview(rig.view)
        container.addSubview(composer)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(composer))

        let look = await rig.agent.perform(act(.look))
        let typed = await rig.agent.perform(act(.type, ["target": .string(ref(for: "Name", in: look.text)), "text": .string("Sam")]))
        XCTAssertTrue(typed.ok, typed.text)
        let clicked = await rig.agent.perform(act(.click, ["target": .string("Sign up")]))
        XCTAssertTrue(clicked.ok, clicked.text)
        try await Task.sleep(for: .milliseconds(300))

        let editor = try XCTUnwrap(composer.currentEditor(), "the composer lost the keyboard")
        XCTAssertTrue(window.firstResponder === editor, "first responder is \(String(describing: window.firstResponder))")
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

    func test_look_image_falls_back_to_jpeg_when_the_png_is_large() throws {
        // Noise does not compress: a 1,600 px square of it is well past 3.5 MB as PNG.
        let noisy = try XCTUnwrap(Self.noise(width: 1600, height: 1600))
        let big = try XCTUnwrap(ViewerSnapshot.encode(noisy))
        XCTAssertEqual(big.mediaType, "image/jpeg")
        let bytes = try XCTUnwrap(Data(base64Encoded: big.data))
        XCTAssertLessThan(bytes.count, 3_500_000)
        XCTAssertNotNil(NSBitmapImageRep(data: bytes))
        let small = try XCTUnwrap(ViewerSnapshot.encode(try XCTUnwrap(Self.image(width: 800, height: 600))))
        XCTAssertEqual(small.mediaType, "image/png")
    }

    private static func noise(width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 33)
            bytes[i + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            bytes[i + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            bytes[i + 3] = 255
        }
        let context = bytes.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        return context?.makeImage()
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
        XCTAssertEqual(rig.agent.actingChat, 1, "the page glows while the agent acts")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(rig.agent.actingChat, "clears after the last action")
    }

    /// v0.13 decision 2: the composer's Stop (or Esc) takes the glow away at
    /// once, not after the linger.
    func test_stop_clears_the_glow_at_once() async throws {
        let rig = try rig("<button>Go</button>")
        let agent = rig.model.viewerAgent
        agent.labelLinger = .seconds(30)
        let running = Task { await agent.perform(act(.look)) }
        for _ in 0..<100 where agent.actingChat == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(agent.actingChat, 1, "the page glows while the agent acts")
        rig.model.stopTurn(chat: 1)
        XCTAssertNil(agent.actingChat, "Stop takes the glow away at once")
        running.cancel()
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
            ("https://figma.com@evil.com/", hosts, false),
            ("blob:https://figma.com/x", hosts, false),
            ("data:text/html,x", hosts, false),
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

    /// The page goes to another site while the target is outlined: the
    /// click is checked again at the moment of acting, on the new host.
    func test_navigation_during_highlight_refused_at_act_time() async throws {
        let rig = try urlRig(
            "<button>Save trail</button>", at: URL(string: "https://www.figma.com/file/x")!, actHosts: ["figma.com"])
        rig.agent.highlightDuration = .milliseconds(600)
        _ = await rig.agent.perform(act(.look))
        let view = rig.view
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            view.loadHTMLString(Self.page("<script>window.clicks = []</script><button onclick=\"clicks.push(1)\">Save trail</button>"),
                                baseURL: URL(string: "https://example.com/elsewhere")!)
        }
        let click = await rig.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertFalse(click.ok, click.text)
        XCTAssertEqual(click.text, Self.outsideText("example.com"))
        let clicks = try await evaluate("(window.clicks || []).length", in: view)
        XCTAssertEqual(clicks as? Int, 0, "nothing on the new site was clicked")
    }

    /// A page whose Content-Security-Policy forbids eval still gets the
    /// script back after replacing it.
    func test_reinstall_works_under_a_csp_without_unsafe_eval() async throws {
        let rig = try rig("""
            <meta http-equiv="Content-Security-Policy" content="script-src 'unsafe-inline'">
            <button>Save trail</button>
            """)
        _ = await rig.agent.perform(act(.look))
        _ = try await evaluate("window.__porticoAgent = {outline: () => 'fake'}; true", in: rig.view)
        let look = await rig.agent.perform(act(.look))
        XCTAssertTrue(look.text.contains("button: Save trail"), look.text)
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

    /// v0.13 decision 4: a page that sets no background is white, as in a
    /// browser; one that sets its own keeps it.
    func test_a_page_with_no_background_shows_white() async throws {
        let plain = try rig("<p>Join the beta</p>")
        let plainLook = await plain.agent.perform(act(.look))
        XCTAssertEqual(try Self.middleColour(plainLook), "white")
        let dark = try rig("<style>html,body{background:#111;margin:0;height:100%}</style><p>Join the beta</p>")
        let darkLook = await dark.agent.perform(act(.look))
        XCTAssertEqual(try Self.middleColour(darkLook), "dark")
    }

    private static func middleColour(_ result: ViewerResult) throws -> String {
        let data = try XCTUnwrap(result.image.flatMap { Data(base64Encoded: $0.data) }, result.text)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let colour = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        if colour.redComponent > 0.8, colour.blueComponent < 0.3 { return "red" }
        if colour.blueComponent > 0.8, colour.redComponent < 0.3 { return "blue" }
        if colour.redComponent > 0.95, colour.greenComponent > 0.95, colour.blueComponent > 0.95 { return "white" }
        if colour.redComponent < 0.2, colour.greenComponent < 0.2, colour.blueComponent < 0.2 { return "dark" }
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

    /// The same PDF view shown another file (no new view): the agent
    /// reads the new one.
    func test_pdf_view_reused_for_another_file_is_read_afresh() async throws {
        let one = try pdf(words: 30)
        let three = try tempDir().appendingPathComponent("three.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: one))
        for index in 1...2 { doc.insert(try XCTUnwrap(doc.page(at: 0)?.copy() as? PDFPage), at: index) }
        XCTAssertTrue(doc.write(to: three))
        let (model, _) = model()
        let first = Artifact(id: "p-3", kind: .file, location: one.path, media: .pdf, title: "route.pdf", source: .tool, open: true)
        model.show(first, in: 1)
        let agent = ViewerAgent(model: model)
        agent.nativeWait = .milliseconds(500)
        let holder = PDFHolder(file: one)
        let host = NSHostingView(rootView: PDFHolderView(holder: holder).environment(\.viewerAgent, agent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        window.contentView = host
        keepAlive = [host, agent, model, window]
        let before = await agent.perform(act(.look))
        XCTAssertTrue(before.text.contains("1 page;"), before.text)

        model.show(Artifact(id: "p-4", kind: .file, location: three.path, media: .pdf, title: "three.pdf", source: .tool, open: true), in: 1)
        holder.file = three
        let after = await agent.perform(act(.look))
        XCTAssertTrue(after.text.contains("3 pages;"), after.text)
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

    // MARK: - marks (v0.14 §3.2–3.3, §4)

    /// `targets` as the `mark` act's args: each `(target, note)`.
    private func markArgs(_ targets: [(String, String?)], replace: Bool = false, toolUseId: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = [
            "marks": .array(targets.map { target, note in
                var item: [String: JSONValue] = ["target": .string(target)]
                if let note { item["note"] = .string(note) }
                return .object(item)
            }),
            "replace": .bool(replace),
        ]
        if let toolUseId { args["tool_use_id"] = .string(toolUseId) }
        return args
    }

    private func boxCount(in view: WKWebView) async throws -> Int {
        let count = try await evaluate("""
            (function () { var host = document.querySelector('portico-marks');
              return host ? host.shadowRoot.querySelectorAll('.box').length : 0; })()
            """, in: view)
        return (count as? Int) ?? -1
    }

    /// Polls `condition` until it holds or `timeout` passes; the last answer.
    @discardableResult
    private func waitFor(_ timeout: Duration = .seconds(4), _ condition: () async throws -> Bool) async rethrows -> Bool {
        let due = ContinuousClock.now + timeout
        while ContinuousClock.now < due {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return try await condition()
    }

    private static let trailPage = """
        <script>window.addEventListener('pageshow', function (e) { (window.shows = window.shows || []).push(e.persisted) })</script>
        <h1>Trail detail</h1>
        <button>Save trail</button>
        <button>Share trail</button>
        <a href="b.html">Next page</a>
        """

    func testMarkActDrawsAndAnswersNumbers() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.mark, markArgs([("e2", "Start here"), ("e3", nil)], toolUseId: "tu-1")))
        XCTAssertTrue(result.ok, result.text)
        let marks = rig.model.markStore.marks[1] ?? []
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.map(\.number), [1, 2])
        guard marks.count == 2 else { return }
        XCTAssertFalse(marks[0].label.isEmpty)
        XCTAssertEqual(result.text, "Marked 1 · \(marks[0].label), 2 · \(marks[1].label).")
        XCTAssertEqual(marks[0].note, "Start here")
        XCTAssertEqual(rig.model.markStore.call(chat: 1, toolUseId: "tu-1")?.marks.count, 2)
        let boxes = try await boxCount(in: rig.view)
        XCTAssertEqual(boxes, 2)
    }

    func testMarkCountOutOfRange() async throws {
        let rig = try rig(Self.trailPage)
        let none = await rig.agent.perform(act(.mark, markArgs([])))
        XCTAssertFalse(none.ok)
        XCTAssertEqual(none.text, "Mark 1 to 9 things at a time.")
        let ten = await rig.agent.perform(act(.mark, markArgs(Array(repeating: ("Save trail", nil), count: 10))))
        XCTAssertFalse(ten.ok)
        XCTAssertEqual(ten.text, "Mark 1 to 9 things at a time.")
        XCTAssertNil(rig.model.markStore.marks[1])
    }

    func testMarkActPartlyNotFound() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("nonexistent words", nil)])))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertTrue(result.text.hasPrefix("Marked 1 · "), result.text)
        XCTAssertTrue(result.text.hasSuffix(" Not found: \"nonexistent words\" — look again."), result.text)
        XCTAssertEqual(rig.model.markStore.marks[1]?.count, 1)
    }

    func testMarkActNoneFound() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.mark, markArgs([("nonexistent words", nil)])))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "Not found — look again")
        XCTAssertNil(rig.model.markStore.marks[1])
    }

    func testMarkOnImagePane() async throws {
        let (model, _) = model()
        let file = try tempDir().appendingPathComponent("route.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: file)
        model.show(Artifact(id: "a-2", kind: .file, location: file.path, media: .image, title: "route.png", source: .tool, open: true), in: 1)
        let agent = ViewerAgent(model: model)
        let result = await agent.perform(act(.mark, markArgs([("e1", nil)])))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "Marks work on web pages; this is an image.")
        // Clearing works on any pane.
        let cleared = await agent.perform(act(.clearMarks))
        XCTAssertTrue(cleared.ok, cleared.text)
        XCTAssertEqual(cleared.text, "Cleared 0 marks.")
    }

    func testMarkOnOutsideSiteIsAllowed() async throws {
        let rig = try urlRig("<button>Save trail</button>", at: URL(string: "https://example.com/trails")!, actHosts: [])
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.mark, markArgs([("e1", "This one")])))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(rig.model.markStore.marks[1]?.first?.page, MarkPage(key: "https://example.com/trails", name: "trails"))
    }

    func testClearMarksAct() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("e3", nil)])))
        let before = try await boxCount(in: rig.view)
        XCTAssertEqual(before, 2)
        let result = await rig.agent.perform(act(.clearMarks))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Cleared 2 marks.")
        let after = try await boxCount(in: rig.view)
        XCTAssertEqual(after, 0, "the overlay is gone")
        _ = await rig.agent.perform(act(.mark, markArgs([("Save trail", nil)])))
        let one = await rig.agent.perform(act(.clearMarks))
        XCTAssertEqual(one.text, "Cleared 1 mark.")
    }

    func testLookListsMarks() async throws {
        let rig = try rig(Self.trailPage)
        let plain = await rig.agent.perform(act(.look))
        XCTAssertFalse(plain.text.contains("Marks:"), "no block without marks")
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", "Start here")])))
        let look = await rig.agent.perform(act(.look))
        XCTAssertTrue(look.text.contains("\n\nMarks:\n- 1 · "), look.text)
        XCTAssertTrue(look.text.contains("(this page)"), look.text)
    }

    /// Marks on A; follow the link to B; Back. WebKit fires `didFinish`
    /// on Back whether the page came from the back-forward cache or was
    /// loaded again (probed 2026-11-01), so both are redrawn there.
    private func leaveAndReturn(cache: Bool) async throws {
        let rig = try rig(Self.trailPage)
        try "<!doctype html><title>B</title><p>Second page</p>".write(
            to: rig.file.deletingLastPathComponent().appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        if !cache { rig.view.configuration.preferences.setValue(false, forKey: "usesPageCache") }
        _ = await rig.agent.perform(act(.look))
        let marked = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("e3", nil)])))
        XCTAssertTrue(marked.ok, marked.text)
        _ = try await evaluate("document.querySelector('a').click(); true", in: rig.view)
        let onB = await waitFor { rig.view.url?.lastPathComponent == "b.html" && !rig.view.isLoading }
        XCTAssertTrue(onB)
        let boxesB = try await boxCount(in: rig.view)
        XCTAssertEqual(boxesB, 0, "no boxes on B")
        rig.view.goBack()
        let back = await waitFor { rig.view.url?.lastPathComponent == "trail-detail.html" && !rig.view.isLoading }
        XCTAssertTrue(back)
        let redrawn = try await waitFor { try await self.boxCount(in: rig.view) == 2 }
        XCTAssertTrue(redrawn, "A has its 2 boxes again")
        let persisted = try await evaluate("JSON.stringify(window.shows)", in: rig.view) as? String
        XCTAssertEqual(persisted, cache ? "[false,true]" : "[false]", "the cache was \(cache ? "used" : "bypassed")")
    }

    func testLeaveAndReturnRedraws() async throws {
        try await leaveAndReturn(cache: true)
        try await leaveAndReturn(cache: false)
    }

    func testClearedMarksStayGoneAfterBack() async throws {
        let rig = try rig(Self.trailPage)
        try "<!doctype html><title>B</title><p>Second page</p>".write(
            to: rig.file.deletingLastPathComponent().appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("e3", nil)])))
        _ = try await evaluate("document.querySelector('a').click(); true", in: rig.view)
        let onB = await waitFor { rig.view.url?.lastPathComponent == "b.html" && !rig.view.isLoading }
        XCTAssertTrue(onB)
        let cleared = await rig.agent.perform(act(.clearMarks))
        XCTAssertEqual(cleared.text, "Cleared 2 marks.")
        rig.view.goBack()
        let back = await waitFor { rig.view.url?.lastPathComponent == "trail-detail.html" && !rig.view.isLoading }
        XCTAssertTrue(back)
        // The cached page comes back with its old overlay until the redraw.
        let gone = try await waitFor { try await self.boxCount(in: rig.view) == 0 }
        try await Task.sleep(for: .milliseconds(200))
        let still = try await boxCount(in: rig.view)
        XCTAssertTrue(gone)
        XCTAssertEqual(still, 0, "A has no boxes")
    }

    func testRenderedFileKeepsItsKeyAcrossReload() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", nil)])))
        let first = await rig.agent.page(of: rig.view)
        let before = rig.view.url
        XCTAssertEqual(first?.name, "trail-detail.html")
        try XCTUnwrap(rig.coordinator).apply(.html(rig.file), revision: "edited", to: rig.view)
        let reloaded = await waitFor { rig.view.url != before && !rig.view.isLoading }
        XCTAssertTrue(reloaded, "a new rendered URL")
        XCTAssertNotEqual(rig.view.url?.host, before?.host)
        let redrawn = try await waitFor { try await self.boxCount(in: rig.view) == 1 }
        XCTAssertTrue(redrawn, "the mark is drawn again")
        let second = await rig.agent.page(of: rig.view)
        XCTAssertEqual(second, first)
    }

    func testEditedFileLosesOneMark() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("Save trail", nil), ("Share trail", nil)])))
        let before = rig.view.url
        try "<!doctype html><html><head><meta charset=utf-8><title>Trail detail</title></head><body><h1>Trail detail</h1><button>Save trail</button></body></html>"
            .write(to: rig.file, atomically: true, encoding: .utf8)
        try XCTUnwrap(rig.coordinator).apply(.html(rig.file), revision: "edited", to: rig.view)
        let reloaded = await waitFor { rig.view.url != before && !rig.view.isLoading }
        XCTAssertTrue(reloaded)
        let flagged = await waitFor { rig.model.markStore.marks[1]?.contains { !$0.found } == true }
        XCTAssertTrue(flagged)
        let boxes = try await boxCount(in: rig.view)
        XCTAssertEqual(boxes, 1)
        XCTAssertEqual(rig.model.markStore.marks[1]?.map(\.found), [true, false])
    }

    /// Clear all and Show again from the list redraw through the store.
    func testClearAllAndShowAgainRedraw() async throws {
        let rig = try rig(Self.trailPage)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("e3", nil)], toolUseId: "tu-7")))
        rig.agent.clearMarks(chat: 1)
        let gone = try await waitFor { try await self.boxCount(in: rig.view) == 0 }
        XCTAssertTrue(gone, "Clear all takes the boxes away")
        rig.agent.showAgain(toolUseId: "tu-7", chat: 1)
        let back = try await waitFor { try await self.boxCount(in: rig.view) == 2 }
        XCTAssertTrue(back, "Show again draws them again")
        XCTAssertEqual(rig.model.markStore.marks[1]?.map(\.number), [1, 2])
    }

    /// A mark on a page the viewer has left: going to it loads that page
    /// in the same view (so Back works) and draws its boxes.
    func testGoToMarkOnAnotherPage() async throws {
        let rig = try rig(Self.trailPage)
        try "<!doctype html><title>B</title><p>Second page</p>".write(
            to: rig.file.deletingLastPathComponent().appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        _ = await rig.agent.perform(act(.look))
        _ = await rig.agent.perform(act(.mark, markArgs([("e2", nil), ("e3", nil)])))
        let mark = try XCTUnwrap(rig.model.markStore.marks[1]?.last)
        _ = try await evaluate("document.querySelector('a').click(); true", in: rig.view)
        let onB = await waitFor { rig.view.url?.lastPathComponent == "b.html" && !rig.view.isLoading }
        XCTAssertTrue(onB)
        rig.agent.goToMark(mark, chat: 1)
        let returned = try await waitFor {
            guard rig.view.url?.lastPathComponent == "trail-detail.html" else { return false }
            return try await self.boxCount(in: rig.view) == 2
        }
        XCTAssertTrue(returned, "back on A with its boxes")
        XCTAssertTrue(rig.view.canGoBack, "Back returns to B")
    }

    /// The header's list heads the page the viewer shows "THIS PAGE": the
    /// agent publishes that page as each load is drawn.
    func testCurrentPageFollowsTheLoadedPage() async throws {
        let rig = try rig(Self.trailPage)
        try "<!doctype html><title>B</title><p>Second page</p>".write(
            to: rig.file.deletingLastPathComponent().appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        let onA = await waitFor { rig.agent.currentPage?.name == "trail-detail.html" }
        XCTAssertTrue(onA, "A once loaded")
        XCTAssertEqual(rig.agent.currentPage?.key, rig.file.standardizedFileURL.resolvingSymlinksInPath().path)
        _ = try await evaluate("document.querySelector('a').click(); true", in: rig.view)
        let onB = await waitFor { rig.agent.currentPage?.name == "b.html" }
        XCTAssertTrue(onB, "B after the link")
        rig.agent.detach(rig.view)
        let gone = await waitFor { rig.agent.currentPage == nil }
        XCTAssertTrue(gone, "no page once the pane goes")
    }

    /// Review Focus 2 for a rendered Markdown page: a re-render (a new
    /// rendered URL) keeps the page's key and draws the mark again.
    func testRenderedMarkdownKeepsItsKeyAcrossReload() async throws {
        let rig = try rig("# Trail notes\n\n## Water\n\nTwo springs.\n", name: "notes.md", media: .markdown)
        let marked = await rig.agent.perform(act(.mark, markArgs([("Water", nil)])))
        XCTAssertTrue(marked.ok, marked.text)
        let first = await rig.agent.page(of: rig.view)
        XCTAssertEqual(first?.name, "notes.md")
        let before = rig.view.url
        try XCTUnwrap(rig.coordinator).apply(.markdown(rig.file), revision: "edited", to: rig.view)
        let reloaded = await waitFor { rig.view.url != before && !rig.view.isLoading }
        XCTAssertTrue(reloaded, "a new rendered URL")
        XCTAssertNotEqual(rig.view.url?.host, before?.host)
        let redrawn = try await waitFor { try await self.boxCount(in: rig.view) == 1 }
        XCTAssertTrue(redrawn, "the mark is drawn again")
        let second = await rig.agent.page(of: rig.view)
        XCTAssertEqual(second?.key, first?.key)
    }

    /// A mark made on a space's page (named for the space) is the same
    /// page once the space is closed and the file is reached again: its
    /// box is drawn, the viewer scrolls to it, the look calls it "this
    /// page", and the re-rendered page hides the space's front matter.
    func testSpaceMarkFoundAfterTheSpaceCloses() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("brief.md")
        let spacer = String(repeating: "Filler line.\n\n", count: 120)
        try "---\ntitle: Brief\nicon: compass\nowner: Sam\n---\n# Morning brief\n\n[Plan](plan.md)\n\n\(spacer)## Route notes\n\nEnd.\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try "<!doctype html><title>Plan</title><p>Plan</p>".write(
            to: dir.appendingPathComponent("plan.html"), atomically: true, encoding: .utf8)
        let (model, _) = model()
        model.apply(.spacesList(SpacesList(spaces: [
            SpaceInfo(id: "brief", title: "Brief", icon: "doc", order: nil, location: file.path, media: "markdown", updated: "2026-10-31T12:00:00Z")])))
        model.openSpaceAt(1)
        let agent = ViewerAgent(model: model)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = view
        keepAlive = [view, coordinator, agent, model, window]
        coordinator.apply(try XCTUnwrap(WebPane.Load(ArtifactPresentation(artifact: try XCTUnwrap(model.openSpaceArtifact)))), to: view)
        let marked = await agent.perform(act(.mark, markArgs([("Route notes", nil)])))
        XCTAssertTrue(marked.ok, marked.text)
        let mark = try XCTUnwrap(model.markStore.marks[1]?.first)
        XCTAssertEqual(mark.page.name, "Brief")

        // Leave the page, close the space, and go back to the mark.
        view.loadHTMLString(Self.page("<p>Elsewhere</p>"), baseURL: URL(string: "https://example.com/elsewhere")!)
        _ = await waitFor { view.url?.host == "example.com" && !view.isLoading }
        model.setOpenSpace(nil)
        agent.goToMark(mark, chat: 1)
        let drawn = try await waitFor {
            guard view.url?.scheme == RenderedPageHandler.scheme else { return false }
            return try await self.boxCount(in: view) == 1
        }
        XCTAssertTrue(drawn, "the box is drawn on the file reached again")
        let page = await agent.page(of: view)
        XCTAssertEqual(page?.name, "brief.md", "no space is open now")
        XCTAssertEqual(page?.key, mark.page.key)
        let scrolled = try await waitFor { (try await self.evaluate("window.scrollY", in: view) as? Double ?? 0) > 100 }
        XCTAssertTrue(scrolled, "it scrolled to the mark")
        let look = model.markStore.lookText(chat: 1, current: page)
        XCTAssertTrue(look?.contains("(this page)") == true, look ?? "")
        XCTAssertEqual(model.markStore.marks[1]?.first?.found, true)
        let text = try await evaluate("document.body.innerText", in: view) as? String ?? ""
        XCTAssertTrue(text.contains("Sam"), text)
        XCTAssertFalse(text.contains("compass"), "the space's front matter stays hidden")
    }

    func testSpacePageIsNamedForTheSpace() async throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("brief.md")
        try "# Morning brief\n\n[Plan](plan.md)".write(to: file, atomically: true, encoding: .utf8)
        let (model, _) = model()
        model.apply(.spacesList(SpacesList(spaces: [
            SpaceInfo(id: "brief", title: "Brief", icon: "doc", order: nil, location: file.path, media: "markdown", updated: "2026-10-31T12:00:00Z")])))
        model.openSpaceAt(1)
        let agent = ViewerAgent(model: model)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = view
        keepAlive = [view, coordinator, agent, model, window]
        coordinator.apply(try XCTUnwrap(WebPane.Load(ArtifactPresentation(artifact: try XCTUnwrap(model.openSpaceArtifact)))), to: view)
        let result = await agent.perform(act(.mark, markArgs([("Morning brief", nil)])))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(model.markStore.marks[1]?.first?.page, MarkPage(key: file.standardizedFileURL.resolvingSymlinksInPath().path, name: "Brief"))
    }

    // MARK: - final fix wave (v0.14)

    /// A new pane for `load`, as SwiftUI makes one when the viewer comes
    /// back: its own coordinator and view, wired to `agent`.
    private func pane(for load: WebPane.Load, agent: ViewerAgent, size: NSSize = NSSize(width: 800, height: 600)) -> WKWebView {
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        keepAlive.append(contentsOf: [view, coordinator, window])
        coordinator.apply(load, to: view)
        return view
    }

    private static let tallPage = """
        <h1>Trail detail</h1>
        <div style="height: 2400px">Long description</div>
        <button>Save trail</button>
        <button>Share trail</button>
        """

    /// Fix 1: the viewer collapsed (its web pane taken down) and the mark
    /// on the chat's shown artifact. Show again opens the viewer, and once
    /// the pane is back the marks are drawn and the first is scrolled to.
    func testShowAgainWithTheViewerCollapsedOpensItAndDraws() async throws {
        let rig = try rig(Self.tallPage)
        _ = await rig.agent.perform(act(.look))
        let marked = await rig.agent.perform(act(.mark, markArgs([("Save trail", nil), ("Share trail", nil)], toolUseId: "tu-c")))
        XCTAssertTrue(marked.ok, marked.text)
        rig.agent.clearMarks(chat: 1)
        // Collapse: SwiftUI takes the pane down.
        rig.model.setViewer(visible: false, for: 1)
        rig.agent.detach(rig.view)
        rig.model.openDocumentView()

        rig.agent.showAgain(toolUseId: "tu-c", chat: 1)
        let opened = await waitFor { rig.model.isViewerShown(for: 1) && !rig.model.documentMode }
        XCTAssertTrue(opened, "Show again opens the viewer and leaves the document view")
        guard opened else { return }
        // The viewer is back: SwiftUI makes a new pane on the shown artifact.
        let load = try XCTUnwrap(WebPane.Load(ArtifactPresentation(artifact: try XCTUnwrap(rig.model.shownArtifact(for: 1)))))
        let view = pane(for: load, agent: rig.agent)
        let drawn = try await waitFor { try await self.boxCount(in: view) == 2 }
        XCTAssertTrue(drawn, "the marks are drawn on the pane that came back")
        let scrolled = try await waitFor { (try await self.evaluate("window.scrollY", in: view) as? Double ?? 0) > 1000 }
        XCTAssertTrue(scrolled, "the viewer scrolled to the first mark")
    }

    /// Follows the model's shown artifact for chat 1 into `view`, as the
    /// viewer does: a web artifact loads in the pane, anything else takes
    /// the pane down (and a web artifact after that makes a new one).
    private final class Follower {
        var view: WKWebView?
        var watch: AnyCancellable?
    }

    private func follow(_ model: AppModel, agent: ViewerAgent, from view: WKWebView, coordinator: WebPane.Coordinator) -> Follower {
        let follower = Follower()
        follower.view = view
        var coordinator: WebPane.Coordinator? = coordinator
        follower.watch = model.$current.dropFirst().sink { [weak self] current in
            MainActor.assumeIsolated {
                guard let self, let artifact = current[1] else { return }
                if let load = WebPane.Load(ArtifactPresentation(artifact: artifact)) {
                    if let view = follower.view, let coordinator {
                        coordinator.apply(load, to: view)
                    } else {
                        follower.view = self.pane(for: load, agent: agent)
                    }
                } else if let view = follower.view {
                    agent.detach(view)
                    follower.view = nil
                    coordinator = nil
                }
            }
        }
        keepAlive.append(follower)
        return follower
    }

    /// Fix 1 (coverage): a mark on another listed artifact is reached
    /// through `model.show`, from a web page and from an image pane.
    func testGoToMarkShowsAnotherListedArtifact() async throws {
        let rig = try rig(Self.trailPage)
        let dir = rig.file.deletingLastPathComponent()
        let other = dir.appendingPathComponent("route.html")
        try Self.page("<h1>Route</h1><button>Download route</button>").write(to: other, atomically: true, encoding: .utf8)
        let image = dir.appendingPathComponent("map.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: image)
        let first = Artifact(id: "a-1", kind: .file, location: rig.file.path, media: .html, title: "trail-detail.html", source: .tool, open: false)
        let route = Artifact(id: "a-2", kind: .file, location: other.path, media: .html, title: "route.html", source: .tool, open: false)
        let map = Artifact(id: "a-3", kind: .file, location: image.path, media: .image, title: "map.png", source: .tool, open: false)
        for artifact in [first, route, map] { rig.model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: artifact))) }
        let follower = follow(rig.model, agent: rig.agent, from: rig.view, coordinator: try XCTUnwrap(rig.coordinator))

        rig.model.show(route, in: 1)
        let onRoute = await waitFor { rig.view.url != nil && !rig.view.isLoading && rig.agent.currentPage?.name == "route.html" }
        XCTAssertTrue(onRoute)
        _ = await rig.agent.perform(act(.look))
        let marked = await rig.agent.perform(act(.mark, markArgs([("Download route", "Here")])))
        XCTAssertTrue(marked.ok, marked.text)
        let mark = try XCTUnwrap(rig.model.markStore.marks[1]?.first)

        // From another web page.
        rig.model.show(first, in: 1)
        _ = await waitFor { rig.agent.currentPage?.name == "trail-detail.html" }
        rig.agent.goToMark(mark, chat: 1)
        let back = try await waitFor {
            guard rig.model.shownArtifact(for: 1)?.id == "a-2", let view = follower.view else { return false }
            return try await self.boxCount(in: view) == 1
        }
        XCTAssertTrue(back, "route.html is shown again with its box")

        // From an image pane: no web pane at all until route.html is shown.
        rig.model.show(map, in: 1)
        XCTAssertNil(follower.view)
        rig.agent.goToMark(mark, chat: 1)
        let fromImage = try await waitFor {
            guard rig.model.shownArtifact(for: 1)?.id == "a-2", let view = follower.view else { return false }
            return try await self.boxCount(in: view) == 1
        }
        XCTAssertTrue(fromImage, "from the image, route.html is shown with its box")
    }

    /// Fix 3: a page that builds the marked element 500 ms after it loads.
    /// After leaving and coming back (no page cache, so it is built again)
    /// the mark is found and drawn, and the store says so.
    func testMarkOnAScriptBuiltPageIsFoundAfterReturn() async throws {
        let late = """
            <h1>Trail detail</h1>
            <a href="b.html">Next page</a>
            <script>setTimeout(function () {
              var b = document.createElement('button'); b.textContent = 'Late button'; document.body.appendChild(b);
            }, 500)</script>
            """
        let rig = try rig(late)
        try "<!doctype html><title>B</title><p>Second page</p>".write(
            to: rig.file.deletingLastPathComponent().appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        rig.view.configuration.preferences.setValue(false, forKey: "usesPageCache")
        let built = try await waitFor {
            (try await self.evaluate("!!document.querySelector('button')", in: rig.view) as? Bool) == true
        }
        XCTAssertTrue(built)
        _ = await rig.agent.perform(act(.look))
        let marked = await rig.agent.perform(act(.mark, markArgs([("Late button", nil)])))
        XCTAssertTrue(marked.ok, marked.text)
        _ = try await evaluate("document.querySelector('a').click(); true", in: rig.view)
        let onB = await waitFor { rig.view.url?.lastPathComponent == "b.html" && !rig.view.isLoading }
        XCTAssertTrue(onB)
        rig.view.goBack()
        let back = await waitFor { rig.view.url?.lastPathComponent == "trail-detail.html" && !rig.view.isLoading }
        XCTAssertTrue(back)
        let drawn = try await waitFor(.seconds(5)) { try await self.boxCount(in: rig.view) == 1 }
        XCTAssertTrue(drawn, "the late element gets its box")
        let found = await waitFor(.seconds(5)) { rig.model.markStore.marks[1]?.first?.found == true }
        XCTAssertTrue(found, "the store hears it was found")
        // Settled: no redraw loop keeps the store publishing.
        var publishes = 0
        let watch = rig.model.markStore.$marks.dropFirst().sink { _ in publishes += 1 }
        try await Task.sleep(for: .seconds(2.5))
        watch.cancel()
        XCTAssertEqual(publishes, 0, "the store stops changing once the mark is found")
        let still = try await boxCount(in: rig.view)
        XCTAssertEqual(still, 1)
    }

    /// Fix 5: clearing is store-only, so it works with nothing open.
    func testClearMarksWithNothingOpen() async throws {
        let (model, _) = model()
        let agent = ViewerAgent(model: model)
        model.markStore.add(
            chat: 1, page: MarkPage(key: "/tmp/a.html", name: "a.html"),
            items: [(label: "Save", note: "", locator: MarkLocator(path: "", tag: "button", text: "Save"))],
            call: "c1", toolUseId: nil, replace: false)
        XCTAssertNil(model.shownArtifact(for: 1))
        let cleared = await agent.perform(act(.clearMarks))
        XCTAssertTrue(cleared.ok, cleared.text)
        XCTAssertEqual(cleared.text, "Cleared 1 mark.")
        XCTAssertNil(model.markStore.marks[1])
        // The setting and the other-chat checks still come first.
        let other = await agent.perform(act(.clearMarks, chat: 2))
        XCTAssertEqual(other.text, "The person is looking at another chat.")
        model.settings.viewerAgentCanSee = false
        let off = await agent.perform(act(.clearMarks))
        XCTAssertEqual(off.text, "The person has turned off the agent's view of the viewer in Settings.")
    }

    // MARK: - the person used the page (v0.14 §6b.4)

    private static let personUsed = "The person used the page since your last look; look again."

    /// A page that records what reached it and whether the browser called it trusted.
    private static let inputPage = """
        <script>
        window.seen = [];
        ['click', 'keydown', 'wheel'].forEach(function (t) {
          window.addEventListener(t, function (e) { seen.push(t + ':' + e.isTrusted) }, true);
        });
        </script>
        <style>body{margin:0} .tall{height:3000px}</style>
        <h1>Trail detail</h1>
        <button>Save trail</button>
        <div class="tall"></div>
        """

    /// Real AppKit events through the window, as the person's mouse,
    /// keyboard and trackpad send them: WebKit marks these `isTrusted`,
    /// which `dispatchEvent` from a script never is. The window is shown
    /// for the test (borderless, briefly) so it can be key.
    private enum PersonInput { case click, key, wheel }

    private func person(_ input: PersonInput, on rig: Rig) async throws {
        let window = try XCTUnwrap(rig.view.window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(rig.view)
        // A point on the empty part of the page, in window coordinates.
        let point = rig.view.convert(NSPoint(x: 400, y: rig.view.bounds.height - 300), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        switch input {
        case .click:
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        case .key:
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: type, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                    context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
                window.sendEvent(event)
            }
        case .wheel:
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
            let screen = window.convertPoint(toScreen: point)
            let height = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screen.x, y: height - screen.y)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            rig.view.scrollWheel(with: event)
        }
        let name = switch input { case .click: "click"; case .key: "keydown"; case .wheel: "wheel" }
        let arrived = try await waitFor {
            ((try await self.evaluate("seen.join(',')", in: rig.view) as? String) ?? "").contains("\(name):true")
        }
        XCTAssertTrue(arrived, "the page saw a trusted \(name)")
    }

    func test_a_person_click_since_the_look_is_named_on_not_found() async throws {
        let rig = try rig(Self.inputPage)
        _ = await rig.agent.perform(act(.look))
        try await person(.click, on: rig)

        let click = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, Self.personUsed)
        let type = await rig.agent.perform(act(.type, ["target": .string("Nowhere"), "text": .string("Sam")]))
        XCTAssertEqual(type.text, Self.personUsed)
        let scroll = await rig.agent.perform(act(.scroll, ["target": .string("Nowhere")]))
        XCTAssertEqual(scroll.text, Self.personUsed)
        let mark = await rig.agent.perform(act(.mark, markArgs([("Nowhere", nil)])))
        XCTAssertEqual(mark.text, Self.personUsed)
        let stale = await rig.agent.perform(act(.click, ["target": .string("e999")]))
        XCTAssertEqual(stale.text, Self.personUsed, "a ref that isn't there either")

        // A look clears it.
        _ = await rig.agent.perform(act(.look))
        let after = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertEqual(after.text, "Not found — look again")
    }

    func test_a_person_key_since_the_look_is_named_on_not_found() async throws {
        let rig = try rig(Self.inputPage)
        _ = await rig.agent.perform(act(.look))
        try await person(.key, on: rig)
        let click = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertEqual(click.text, Self.personUsed)
    }

    func test_a_person_scroll_since_the_look_is_named_on_not_found() async throws {
        let rig = try rig(Self.inputPage)
        _ = await rig.agent.perform(act(.look))
        try await person(.wheel, on: rig)
        let click = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertEqual(click.text, Self.personUsed)
    }

    func test_input_before_the_look_and_script_events_dont_count() async throws {
        let rig = try rig(Self.inputPage)
        _ = await rig.agent.perform(act(.look))
        try await person(.click, on: rig)
        _ = await rig.agent.perform(act(.look))
        // The page's own (or the agent's) synthetic events are untrusted.
        _ = try await evaluate("""
            document.body.dispatchEvent(new MouseEvent('click', {bubbles: true}));
            document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', bubbles: true}));
            document.body.dispatchEvent(new WheelEvent('wheel', {deltaY: 40, bubbles: true}));
            window.scrollTo(0, 500); true
            """, in: rig.view)
        let clicked = await rig.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertTrue(clicked.ok, "the agent's own click is not the person's")
        let click = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertEqual(click.text, "Not found — look again")
    }

    func test_the_script_marker_matches_the_app() throws {
        let source = try XCTUnwrap(ViewerAgentScript.source)
        let match = try XCTUnwrap(source.firstMatch(of: /var MARKER = "([^"]+)";/))
        XCTAssertEqual(String(match.1), ViewerAgentScript.marker)
        XCTAssertNotEqual(ViewerAgentScript.marker, "viewer-agent-3", "v0.14 changed what the script records")
    }

    // MARK: - a heading in a clickable card (v0.14 §6b.5)

    private static let headingSentence = "That's a heading, not something to click; use its ref."

    func test_clicking_a_cards_heading_clicks_the_card() async throws {
        let rig = try rig("""
            <script>window.clicks = []</script>
            <div class="card" onclick="clicks.push('grocery')"><h3>Grocery run</h3><p>Tuesday, Sam</p></div>
            <div class="card" id="laundry" style="cursor:pointer"><h3>Laundry</h3></div>
            <script>document.getElementById('laundry').addEventListener('click', function () { clicks.push('laundry') })</script>
            <div id="deep"><section><h4>Deep heading</h4></section></div>
            <script>document.getElementById('deep').onclick = function () { clicks.push('deep') }</script>
            """)
        _ = await rig.agent.perform(act(.look))
        let grocery = await rig.agent.perform(act(.click, ["target": .string("Grocery run")]))
        XCTAssertTrue(grocery.ok, grocery.text)
        XCTAssertTrue(grocery.text.contains("Grocery run"), grocery.text)
        let laundry = await rig.agent.perform(act(.click, ["target": .string("laundry")]))
        XCTAssertTrue(laundry.ok, "an addEventListener card found by cursor: pointer: \(laundry.text)")
        let deep = await rig.agent.perform(act(.click, ["target": .string("Deep heading")]))
        XCTAssertTrue(deep.ok, "an onclick property two levels up: \(deep.text)")
        let clicks = try await evaluate("clicks.join(',')", in: rig.view)
        XCTAssertEqual(clicks as? String, "grocery,laundry,deep", "each card's handler, once")
    }

    /// Fix I-3: the click lands on the heading itself and bubbles, so a
    /// list that handles clicks for its cards (`closest('.card')`) opens
    /// the right one.
    func test_a_delegated_card_list_opens_the_cards_heading() async throws {
        let rig = try rig("""
            <style>.card{cursor:pointer;padding:8px}</style>
            <script>window.opened = []</script>
            <div id="list">
              <div class="card" data-id="grocery"><h3>Grocery run</h3><p>Tuesday, Sam</p></div>
              <div class="card" data-id="laundry"><h3>Laundry</h3><p>Friday, Priya</p></div>
            </div>
            <script>
            // Delegated, from where the click landed: a card's title opens
            // it; elsewhere on the card does nothing here.
            document.getElementById('list').onclick = function (e) {
              var title = e.target.closest('h3');
              var card = e.target.closest('.card');
              opened.push(title && card ? card.getAttribute('data-id') : 'none');
            };
            </script>
            """)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.click, ["target": .string("Grocery run")]))
        XCTAssertTrue(result.ok, result.text)
        let opened = try await evaluate("opened.join(',')", in: rig.view)
        XCTAssertEqual(opened as? String, "grocery")
    }

    /// Fix I-3: a backdrop that closes the dialog on click is not the
    /// heading's card: it covers the viewport.
    func test_a_dialog_heading_on_a_click_to_close_backdrop_is_not_clicked() async throws {
        let rig = try rig("""
            <script>window.closed = 0</script>
            <div id="backdrop" onclick="closed += 1" style="position:fixed;inset:0;background:rgba(0,0,0,.3)">
              <div style="margin:100px auto;width:300px;background:#fff"><h2>Delete Acme board?</h2><p>This can't be undone.</p></div>
            </div>
            """)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.click, ["target": .string("Delete Acme board?")]))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, Self.headingSentence)
        let closed = try await evaluate("closed", in: rig.view)
        XCTAssertEqual(closed as? Int, 0, "the backdrop's handler did not fire")
    }

    /// Fix I-3: a wrapper holding several headings is not one heading's card.
    func test_a_clickable_wrapper_around_several_headings_is_not_clicked() async throws {
        let rig = try rig("""
            <script>window.hits = 0</script>
            <div onclick="hits += 1" style="width:300px"><h3>Jordan</h3><h3>Priya</h3></div>
            """)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.click, ["target": .string("Jordan")]))
        XCTAssertEqual(result.text, Self.headingSentence)
        let hits = try await evaluate("hits", in: rig.view)
        XCTAssertEqual(hits as? Int, 0)
    }

    func test_a_bare_heading_is_not_something_to_click() async throws {
        let rig = try rig("<h2>Trail notes</h2><p>Plain text.</p><button>Save trail</button>")
        _ = await rig.agent.perform(act(.look))
        let heading = await rig.agent.perform(act(.click, ["target": .string("Trail notes")]))
        XCTAssertFalse(heading.ok)
        XCTAssertEqual(heading.text, Self.headingSentence)
        // Everything else as before: a button by its words, nothing found by other words.
        let save = await rig.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertTrue(save.ok, save.text)
        let none = await rig.agent.perform(act(.click, ["target": .string("Nowhere")]))
        XCTAssertEqual(none.text, "Not found — look again")
    }

    func test_a_button_with_the_same_words_beats_the_heading() async throws {
        let rig = try rig("""
            <script>window.clicks = []</script>
            <div onclick="clicks.push('card')"><h3>Grocery run</h3></div>
            <button onclick="clicks.push('button')">Grocery run</button>
            """)
        _ = await rig.agent.perform(act(.look))
        let result = await rig.agent.perform(act(.click, ["target": .string("Grocery run")]))
        XCTAssertTrue(result.ok, result.text)
        let clicks = try await evaluate("clicks.join(',')", in: rig.view)
        XCTAssertEqual(clicks as? String, "button")
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

/// Drives one `PDFPane` through two files without a new view.
@MainActor
final class PDFHolder: ObservableObject {
    @Published var file: URL
    init(file: URL) { self.file = file }
}

struct PDFHolderView: View {
    @ObservedObject var holder: PDFHolder
    var body: some View { PDFPane(file: holder.file) }
}
