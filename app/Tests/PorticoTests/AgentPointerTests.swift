import AppKit
import Foundation
import WebKit
import XCTest

@testable import Portico

/// v0.18 §4.1, plan ruling 38, Pen AR5–AR6: before the agent's click, and
/// before it types into a field, a pointer drawn over the viewer's page
/// glides to the target and pulses; then the action lands. The person's
/// own mouse never moves.
@MainActor
final class AgentPointerTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        for case let window as NSWindow in keepAlive { window.close() }
        keepAlive = []
        super.tearDown()
    }

    // MARK: - fixtures

    /// A bare web view in a window (never shown), for the pointer alone.
    private func hostedView(size: NSSize = NSSize(width: 800, height: 600)) -> WKWebView {
        let view = WKWebView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        keepAlive += [view, window]
        return view
    }

    private func pointers(in view: NSView) -> [AgentPointer] {
        view.subviews.compactMap { $0 as? AgentPointer }
    }

    private func isolatedSettings() -> Portico.Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Portico.Settings(defaults: defaults)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-pointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Rig {
        let agent: ViewerAgent
        let view: WKWebView
    }

    /// The `ViewerAgentTests` rig: `body` as a page in chat 1's viewer,
    /// with a web pane wired to the agent the way `WebPane` wires it.
    private func rig(_ body: String) throws -> Rig {
        let file = try tempDir().appendingPathComponent("trail-detail.html")
        try "<!doctype html><html><head><meta charset=utf-8><title>Trail detail</title></head><body>\(body)</body></html>"
            .write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(settings: isolatedSettings())
        model.outbound = { _ in }
        model.selected = 1
        model.show(
            Artifact(id: "a-1", kind: .file, location: file.path, media: .html, title: "trail-detail.html", source: .tool, open: true),
            in: 1)
        let agent = ViewerAgent(model: model)
        agent.highlightDuration = .milliseconds(20)
        let coordinator = WebPane.Coordinator()
        coordinator.agent = agent
        let view = coordinator.makeWebView()
        let size = NSSize(width: 800, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        keepAlive += [view, coordinator, agent, model, window]
        coordinator.apply(.html(file), to: view)
        return Rig(agent: agent, view: view)
    }

    /// A URL page in chat 1's viewer, loaded offline as if from `url`, with
    /// the deployment's `act_hosts`.
    private func urlRig(_ body: String, at url: URL, actHosts: [String]) throws -> Rig {
        let model = AppModel(settings: isolatedSettings())
        model.outbound = { _ in }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.18.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["viewer.v1"], presentation: "multiple",
            viewerDefaults: ViewerDefaults(actHosts: actHosts))))
        model.selected = 1
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
        keepAlive += [view, coordinator, agent, model, window]
        agent.attach(view, showing: .url(url))
        view.loadHTMLString(
            "<!doctype html><html><head><meta charset=utf-8><title>Outside</title></head><body>\(body)</body></html>", baseURL: url)
        return Rig(agent: agent, view: view)
    }

    private func act(_ action: ViewerAct.Action, _ args: [String: JSONValue] = [:]) -> ViewerAct {
        ViewerAct(id: "act-\(UUID().uuidString.prefix(6))", chat: 1, action: action, args: args)
    }

    // MARK: - where the tip lands

    func testTipPositions() {
        let pointer = AgentPointer()
        let box = CGRect(x: 100, y: 200, width: 80, height: 30)
        XCTAssertEqual(pointer.tip(for: box, kind: .click), CGPoint(x: 140, y: 215), "a click lands at the box's centre")
        XCTAssertEqual(pointer.tip(for: box, kind: .type), CGPoint(x: 108, y: 215), "a type lands 8 pt in from the field's left edge, centred")
        XCTAssertNil(pointer.tipPosition, "nowhere until it first moves")
    }

    func testTimingsFromAR6() {
        XCTAssertEqual(AgentPointer.glide, 0.33)
        XCTAssertEqual(AgentPointer.fadeAfter, 1.5)
        XCTAssertEqual(AgentPointer.pulse, 0.35)
    }

    // MARK: - the glide

    func testMoveWaitsForTheGlide() async throws {
        let view = hostedView()
        let pointer = AgentPointer(reduceMotion: { false })
        let box = CGRect(x: 300, y: 200, width: 80, height: 30)
        let start = Date()
        await pointer.move(to: box, in: view, kind: .click)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "the move returns once the glide is over")
        XCTAssertEqual(pointer.tipPosition, pointer.tip(for: box, kind: .click))
        XCTAssertEqual(pointers(in: view).count, 1, "drawn on the web view")
        XCTAssertEqual(pointer.alphaValue, 1)

        // Reduce Motion: it appears at the target, no glide.
        let still = hostedView()
        let calm = AgentPointer(reduceMotion: { true })
        let quick = Date()
        await calm.move(to: box, in: still, kind: .type)
        XCTAssertLessThan(Date().timeIntervalSince(quick), 0.2, "no glide under Reduce Motion")
        XCTAssertEqual(calm.tipPosition, calm.tip(for: box, kind: .type))
    }

    func testPointerIgnoresTheMouseAndStaysOnTop() async throws {
        let view = hostedView()
        let pointer = AgentPointer(reduceMotion: { true })
        await pointer.move(to: CGRect(x: 100, y: 100, width: 40, height: 20), in: view, kind: .click)
        view.addSubview(NSView(frame: .zero))
        await pointer.move(to: CGRect(x: 200, y: 100, width: 40, height: 20), in: view, kind: .click)
        XCTAssertTrue(view.subviews.last === pointer, "above anything added to the page since")
        XCTAssertEqual(pointers(in: view).count, 1, "one pointer per web view")
        let tip = try XCTUnwrap(pointer.tipPosition)
        XCTAssertNil(pointer.hitTest(view.convert(tip, to: pointer.superview)), "clicks go through to the page")
    }

    func testPersonMouseUntouched() async throws {
        let view = hostedView()
        let pointer = AgentPointer(reduceMotion: { false })
        let before = NSEvent.mouseLocation
        await pointer.move(to: CGRect(x: 400, y: 300, width: 80, height: 30), in: view, kind: .click)
        await pointer.move(to: CGRect(x: 50, y: 50, width: 80, height: 30), in: view, kind: .type)
        XCTAssertEqual(NSEvent.mouseLocation, before, "the person's own mouse never moves")
    }

    /// A parent that isn't flipped: y grows upward, bottom centre is y 0.
    private final class UnflippedWebView: WKWebView {
        override var isFlipped: Bool { false }
    }

    func testUnflippedParent() async throws {
        let size = NSSize(width: 800, height: 600)
        let view = UnflippedWebView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        keepAlive += [view, window]
        XCTAssertFalse(view.isFlipped)
        let pointer = AgentPointer(reduceMotion: { false })
        let box = CGRect(x: 380, y: 500, width: 40, height: 20)
        let moving = Task { await pointer.move(to: box, in: view, kind: .click) }
        try await Task.sleep(for: .milliseconds(30))
        let early = try XCTUnwrap(pointer.tipPosition)
        XCTAssertLessThan(early.y, 120, "the first glide starts at the bottom centre (y 0 when unflipped): \(early)")
        XCTAssertEqual(early.x, 400, accuracy: 60)
        await moving.value
        let tip = try XCTUnwrap(pointer.tipPosition)
        XCTAssertEqual(tip, CGPoint(x: 400, y: 510))
        XCTAssertEqual(pointer.frame.midX, tip.x, accuracy: 0.5, "the tip is the view's centre")
        XCTAssertEqual(pointer.frame.midY, tip.y, accuracy: 0.5)
    }

    func testFlippedParentStartsAtTheBottomToo() async throws {
        let view = hostedView()
        XCTAssertTrue(view.isFlipped)
        let pointer = AgentPointer(reduceMotion: { false })
        let moving = Task { await pointer.move(to: CGRect(x: 380, y: 80, width: 40, height: 20), in: view, kind: .click) }
        try await Task.sleep(for: .milliseconds(30))
        let early = try XCTUnwrap(pointer.tipPosition)
        XCTAssertGreaterThan(early.y, 480, "bottom centre is the largest y when flipped: \(early)")
        await moving.value
    }

    func testPointerGoesWithItsWebView() async throws {
        weak var weakPointer: AgentPointer?
        do {
            let size = NSSize(width: 400, height: 300)
            let view = WKWebView(frame: NSRect(origin: .zero, size: size))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            let pointer = AgentPointer(reduceMotion: { true })
            weakPointer = pointer
            await pointer.move(to: CGRect(x: 100, y: 100, width: 40, height: 20), in: view, kind: .click)
            XCTAssertTrue(pointer.superview === view)
            window.contentView = nil
            window.close()
        }
        // The pending fade holds it weakly; only the web view kept it.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(weakPointer, "released with its web view")
    }

    // MARK: - fading

    func testFadesAfterIdle() async throws {
        let view = hostedView()
        let pointer = AgentPointer(reduceMotion: { false })
        let box = CGRect(x: 200, y: 200, width: 80, height: 30)
        await pointer.move(to: box, in: view, kind: .click)
        XCTAssertEqual(pointer.alphaValue, 1)
        try await Task.sleep(for: .milliseconds(Int(AgentPointer.fadeAfter * 1000) + 700))
        XCTAssertEqual(pointer.alphaValue, 0, "gone after a second and a half with no step")
        await pointer.move(to: box.offsetBy(dx: 100, dy: 0), in: view, kind: .click)
        XCTAssertEqual(pointer.alphaValue, 1, "the next step brings it back")
    }

    // MARK: - with the agent

    func testClickLandsAfterThePointer() async throws {
        let rig = try rig("""
            <script>window.clickedAt = 0; window.typedAt = 0</script>
            <button style="margin: 200px 0 0 300px" onclick="clickedAt = Date.now()">Start trail</button>
            <input aria-label="Trailhead" oninput="typedAt = typedAt || Date.now()">
            """)
        let look = await rig.agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)

        let click = await rig.agent.perform(act(.click, ["target": .string("Start trail")]))
        XCTAssertTrue(click.ok, click.text)
        let pointer = try XCTUnwrap(pointers(in: rig.view).first, "the click drew the pointer")
        XCTAssertEqual(pointers(in: rig.view).count, 1)
        let clickArrival = try XCTUnwrap(pointer.lastArrival)
        let clickedValue = try await rig.view.evaluateJavaScript("clickedAt") as? NSNumber
        let clickedAt = try XCTUnwrap(clickedValue).doubleValue
        XCTAssertGreaterThan(clickedAt, 0, "clicked")
        XCTAssertGreaterThanOrEqual(clickedAt, (clickArrival.timeIntervalSince1970 * 1000).rounded(.down), "the click lands after the pointer arrives")

        let typed = await rig.agent.perform(act(.type, ["target": .string("Trailhead"), "text": .string("Eagle Rock")]))
        XCTAssertTrue(typed.ok, typed.text)
        XCTAssertEqual(pointers(in: rig.view).count, 1, "the same pointer moves on")
        let typeArrival = try XCTUnwrap(pointer.lastArrival)
        XCTAssertGreaterThan(typeArrival, clickArrival)
        let typedValue = try await rig.view.evaluateJavaScript("typedAt") as? NSNumber
        let typedAt = try XCTUnwrap(typedValue).doubleValue
        XCTAssertGreaterThanOrEqual(typedAt, (typeArrival.timeIntervalSince1970 * 1000).rounded(.down), "the text goes in after the pointer arrives")
        // A type rests at the field's left edge, not its centre.
        let fieldValue = try await rig.view.evaluateJavaScript(
            "(() => { const r = document.querySelector('input').getBoundingClientRect(); return [r.left, r.width] })()") as? [NSNumber]
        let field = try XCTUnwrap(fieldValue)
        let tip = try XCTUnwrap(pointer.tipPosition)
        let zoom = rig.view.pageZoom * rig.view.magnification
        XCTAssertEqual(tip.x, CGFloat(field[0].doubleValue) * zoom + 8, accuracy: 1)
    }

    /// The box's centre in the (flipped) web view, as `outline` converts it.
    private func centre(of selector: String, in view: WKWebView) async throws -> CGPoint {
        let value = try await view.evaluateJavaScript(
            "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.left, r.top, r.width, r.height] })()") as? [NSNumber]
        let r = try XCTUnwrap(value).map { CGFloat($0.doubleValue) }
        let zoom = view.pageZoom * view.magnification
        XCTAssertTrue(view.isFlipped)
        return CGPoint(x: (r[0] + r[2] / 2) * zoom, y: (r[1] + r[3] / 2) * zoom)
    }

    func testTipLandsAtTheBoxCentreLineOnThePage() async throws {
        let rig = try rig("""
            <button style="margin: 150px 0 0 250px; height: 40px">Start trail</button>
            <input aria-label="Trailhead" style="margin: 120px 0 0 60px; height: 30px">
            """)
        _ = await rig.agent.perform(act(.look))
        let click = await rig.agent.perform(act(.click, ["target": .string("Start trail")]))
        XCTAssertTrue(click.ok, click.text)
        let pointer = try XCTUnwrap(pointers(in: rig.view).first)
        let button = try await centre(of: "button", in: rig.view)
        let clickTip = try XCTUnwrap(pointer.tipPosition)
        XCTAssertEqual(clickTip.x, button.x, accuracy: 1, "a click: the box's centre")
        XCTAssertEqual(clickTip.y, button.y, accuracy: 1, "a click: the box's middle")

        let typed = await rig.agent.perform(act(.type, ["target": .string("Trailhead"), "text": .string("Eagle Rock")]))
        XCTAssertTrue(typed.ok, typed.text)
        let field = try await centre(of: "input", in: rig.view)
        let typeTip = try XCTUnwrap(pointer.tipPosition)
        XCTAssertEqual(typeTip.y, field.y, accuracy: 1, "a type: the field's middle")
        XCTAssertLessThan(typeTip.x, field.x, "a type: at the left edge, not the centre")
    }

    /// Plan ruling R-c30: the glide runs alongside the outline ring, so a
    /// click costs the outline's wait and no more; it still lands after the
    /// pointer arrives, and the ring is shown its full time.
    func testGlideRunsAlongsideTheOutline() async throws {
        let rig = try rig("""
            <script>window.clickedAt = 0</script>
            <button style="margin: 300px 0 0 500px" onclick="clickedAt = Date.now()">Start trail</button>
            """)
        rig.agent.highlightDuration = .milliseconds(600)
        _ = await rig.agent.perform(act(.look))
        let start = Date()
        let click = await rig.agent.perform(act(.click, ["target": .string("Start trail")]))
        XCTAssertTrue(click.ok, click.text)
        let value = try await rig.view.evaluateJavaScript("clickedAt") as? NSNumber
        let clickedAt = try XCTUnwrap(value).doubleValue / 1000
        let took = clickedAt - start.timeIntervalSince1970
        XCTAssertGreaterThanOrEqual(took, 0.6 - 0.01, "the ring is shown its full 0.6 s first")
        XCTAssertLessThan(took, 0.6 + AgentPointer.glide - 0.15, "the glide overlaps the ring: no extra third of a second")
        let arrival = try XCTUnwrap(pointers(in: rig.view).first?.lastArrival)
        XCTAssertGreaterThanOrEqual(clickedAt * 1000, (arrival.timeIntervalSince1970 * 1000).rounded(.down), "and lands after the pointer")
    }

    func testRefusedClickDrawsNoPointer() async throws {
        let outside = try urlRig(
            "<button>Save trail</button><input aria-label=\"Search\">",
            at: URL(string: "https://example.com/trails")!, actHosts: ["figma.com"])
        _ = await outside.agent.perform(act(.look))
        let click = await outside.agent.perform(act(.click, ["target": .string("Save trail")]))
        XCTAssertFalse(click.ok, click.text)
        let typed = await outside.agent.perform(act(.type, ["target": .string("Search"), "text": .string("Priya")]))
        XCTAssertFalse(typed.ok, typed.text)
        XCTAssertTrue(pointers(in: outside.view).isEmpty, "outside act_hosts: no pointer")

        let missing = try rig("<button>Save trail</button>")
        _ = await missing.agent.perform(act(.look))
        let none = await missing.agent.perform(act(.click, ["target": .string("Delete everything")]))
        XCTAssertFalse(none.ok, none.text)
        let noField = await missing.agent.perform(act(.type, ["target": .string("Nowhere"), "text": .string("x")]))
        XCTAssertFalse(noField.ok, noField.text)
        XCTAssertTrue(pointers(in: missing.view).isEmpty, "no target: no pointer")
    }
}
