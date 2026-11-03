import AppKit
import Foundation
import Network
import WebKit
import XCTest

@testable import Portico

/// v0.17 §3.2 and §3.4: the agent's show answers once the page has loaded
/// (`viewer.act "show"`, `viewer.show.v1`); X closes the file in front and
/// shows the next; the list holds one row per file; the toolbar's viewer
/// button only hides and shows.
@MainActor
final class ViewerShowAndCloseTests: XCTestCase {

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

    /// A model showing chat 1 (multiple presentation), what it sends dropped.
    private func model() -> AppModel {
        let model = AppModel(settings: isolatedSettings())
        model.outbound = { _ in }
        model.selected = 1
        return model
    }

    /// The gateway's hello: `presentation`, and the hosts the agent may act on.
    private func hello(_ model: AppModel, presentation: String = "multiple", actHosts: [String] = []) {
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.17.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["viewer.v1"], presentation: presentation,
            viewerDefaults: ViewerDefaults(actHosts: actHosts))))
        model.selected = 1
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-show-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func created(_ chat: Int, _ artifact: Artifact) -> ServerMessage {
        .artifactCreated(ArtifactCreated(chat: chat, artifact: artifact))
    }

    private func file(_ id: String, _ location: String, media: Media = .markdown, open: Bool = true) -> Artifact {
        Artifact(
            id: id, kind: .file, location: location, media: media,
            title: URL(fileURLWithPath: location).lastPathComponent, source: .tool, open: open)
    }

    private func show(_ artifact: Artifact, chat: Int = 1) -> ViewerAct {
        ViewerAct(
            id: "act-\(UUID().uuidString.prefix(6))", chat: chat, action: .show,
            args: ["artifact": .string(artifact.id), "location": .string(artifact.location)])
    }

    private struct Rig {
        let model: AppModel
        let agent: ViewerAgent
        let view: WKWebView
        let coordinator: WebPane.Coordinator
    }

    /// A hosted web pane wired to the agent the way `WebPane` wires it,
    /// loading nothing until the test says what the viewer draws.
    private func rig(_ model: AppModel) -> Rig {
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
        keepAlive = [view, coordinator, agent, model, window]
        return Rig(model: model, agent: agent, view: view, coordinator: coordinator)
    }

    private func page(_ body: String) -> String {
        "<!doctype html><html><head><meta charset=utf-8><title>Pricing</title></head><body>\(body)</body></html>"
    }

    private func readyState(_ view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("document.readyState") as? String
    }

    // MARK: - the show answers on load

    func test_show_answers_once_the_page_has_loaded() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<h1>Pricing</h1><p>Acme plans.</p>").write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        let artifact = file("art-1", path.path, media: .html)
        model.apply(created(1, artifact))
        XCTAssertEqual(model.current[1]?.id, "art-1")

        // The pane comes a moment after the show arrives, as SwiftUI draws it.
        let coordinator = rig.coordinator, view = rig.view
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            coordinator.apply(.html(path), to: view)
        }
        let result = await rig.agent.perform(show(artifact))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertFalse(view.isLoading, "answered only once the page has loaded")
        let state = try await readyState(view)
        XCTAssertEqual(state, "complete")
    }

    func test_show_waits_for_a_page_that_loads_slowly() async throws {
        let server = SlowServer(delay: 1)
        try await server.start()
        addTeardownBlock { server.stop() }
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<h1>Pricing</h1><img id=\"chart\" src=\"http://127.0.0.1:\(server.port)/chart.svg\">")
            .write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        let artifact = file("art-1", path.path, media: .html)
        model.apply(created(1, artifact))
        let started = ContinuousClock.now
        rig.coordinator.apply(.html(path), to: rig.view)
        let result = await rig.agent.perform(show(artifact))
        let took = ContinuousClock.now - started
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertGreaterThanOrEqual(took, .milliseconds(950), "the answer came before the slow image did")
        XCTAssertEqual(server.requests, 1)
        let width = try await rig.view.evaluateJavaScript("document.getElementById('chart').naturalWidth") as? Int
        XCTAssertEqual(width, 4, "the image had loaded when the show answered")
    }

    /// Still loading at the act's deadline: the app's timeout answer, which
    /// the gateway reads as "Shown; still loading.".
    func test_show_of_a_page_still_loading_at_the_deadline_times_out() async throws {
        let server = SlowServer(delay: 3)
        try await server.start()
        addTeardownBlock { server.stop() }
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<img src=\"http://127.0.0.1:\(server.port)/chart.svg\">").write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        rig.agent.actWait = .milliseconds(600)
        let artifact = file("art-1", path.path, media: .html)
        model.apply(created(1, artifact))
        rig.coordinator.apply(.html(path), to: rig.view)
        let result = await rig.agent.perform(show(artifact))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.text, "The viewer didn't answer in 10 s.")
    }

    /// Auto-open runs as `artifact.created` arrives: a file not in front
    /// when the show comes never will be, so there is nothing to wait for.
    func test_show_of_a_file_the_gateway_did_not_open_answers_at_once() async throws {
        let model = model()
        let rig = rig(model)
        let artifact = file("art-1", "/tmp/acme/pricing.html", media: .html, open: false)
        model.apply(created(1, artifact))
        XCTAssertNil(model.current[1])
        let started = ContinuousClock.now
        let result = await rig.agent.perform(show(artifact))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
    }

    /// Single presentation showing session 1: a show in chat 2 (a thread,
    /// say) is not where the person looks, so it answers at once.
    func test_show_for_another_chat_in_single_presentation() async throws {
        let model = model()
        hello(model, presentation: "single")
        XCTAssertTrue(model.isSinglePresentation)
        let rig = rig(model)
        model.apply(created(1, file("a-1", "/tmp/acme/notes.md")))
        let artifact = file("art-2", "/tmp/acme/pricing.html", media: .html)
        model.apply(created(2, artifact))
        let started = ContinuousClock.now
        let result = await rig.agent.perform(show(artifact, chat: 2))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(200))
        XCTAssertNil(rig.agent.actingChat)
    }

    /// A page that fails to load says so; shown again once its server is
    /// up, the pane tries again rather than answering from its error page.
    func test_a_page_that_failed_says_why_and_a_reshow_tries_again() async throws {
        let port = try await freeLoopbackPort()
        let address = "http://127.0.0.1:\(port)/pricing"
        let url = try XCTUnwrap(URL(string: address))
        let model = model()
        let rig = rig(model)
        let first = Artifact(id: "art-1", kind: .url, location: address, media: .url, title: "Pricing", source: .tool, open: true)
        model.apply(created(1, first))
        rig.coordinator.apply(.url(url), to: rig.view)
        let failed = await rig.agent.perform(show(first))
        XCTAssertFalse(failed.ok, failed.text)
        XCTAssertTrue(failed.text.hasPrefix("Not loaded: "), failed.text)
        XCTAssertGreaterThan(failed.text.count, "Not loaded: ".count, "names why")

        let server = FakeHealthServer(body: "<h1>Pricing</h1>", port: UInt16(port))
        try await server.start()
        addTeardownBlock { server.stop() }
        let again = Artifact(id: "art-2", kind: .url, location: address, media: .url, title: "Pricing", source: .tool, open: true)
        model.apply(created(1, again))
        // SwiftUI draws the pane again with the same load: not a request to retry.
        rig.coordinator.apply(.url(url), to: rig.view)
        let shown = await rig.agent.perform(show(again))
        XCTAssertTrue(shown.ok, shown.text)
        XCTAssertEqual(shown.text, "Shown in the viewer.")
        XCTAssertGreaterThanOrEqual(server.requests, 1, "the page was asked for again")
    }

    /// The person followed a link off the file: the agent showing that file
    /// again brings it back, and the answer waits for it to load.
    func test_a_reshow_brings_the_file_back_from_a_site_a_link_went_to() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<h1 id=\"title\">Pricing</h1>").write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        let first = file("art-1", path.path, media: .html)
        model.apply(created(1, first))
        rig.coordinator.apply(.html(path), to: rig.view)
        let shown = await rig.agent.perform(show(first))
        XCTAssertTrue(shown.ok, shown.text)

        // A link took the pane to another site.
        rig.view.loadHTMLString(page("<h1 id=\"title\">Elsewhere</h1>"), baseURL: URL(string: "https://elsewhere.example/")!)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.view.url?.host(), "elsewhere.example")

        let again = file("art-2", path.path, media: .html)
        model.apply(created(1, again))
        rig.coordinator.apply(.html(path), to: rig.view)
        let back = await rig.agent.perform(show(again))
        XCTAssertTrue(back.ok, back.text)
        XCTAssertEqual(rig.view.url?.scheme, RenderedPageHandler.scheme, "the file is back in the pane")
        XCTAssertFalse(rig.view.isLoading)
        let title = try await rig.view.evaluateJavaScript("document.getElementById('title').textContent") as? String
        XCTAssertEqual(title, "Pricing")
    }

    /// A link between local pages took the pane from a.md to b.md: the
    /// agent showing a.md again brings a.md back, answering once it loads.
    func test_a_reshow_brings_the_file_back_from_a_linked_local_page() async throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("b.md")
        try "# Alpha\n\nSee [Beta](b.md).\n".write(to: a, atomically: true, encoding: .utf8)
        try "# Beta\n".write(to: b, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        let first = file("art-1", a.path)
        model.apply(created(1, first))
        rig.coordinator.apply(.markdown(a), to: rig.view)
        let shown = await rig.agent.perform(show(first))
        XCTAssertTrue(shown.ok, shown.text)
        let home = try XCTUnwrap(rig.view.url)

        // The person follows the link: same scheme and host, another path.
        _ = try await rig.view.evaluateJavaScript("location.href = 'b.md'; true")
        for _ in 0..<80 where rig.view.url?.path != "/b.md" { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(rig.view.url?.path, "/b.md")
        XCTAssertEqual(rig.view.url?.host(), home.host())

        let again = file("art-2", a.path)
        model.apply(created(1, again))
        rig.coordinator.apply(.markdown(a), to: rig.view)
        let back = await rig.agent.perform(show(again))
        XCTAssertTrue(back.ok, back.text)
        XCTAssertFalse(rig.view.isLoading, "answered once a.md had loaded")
        let url = try XCTUnwrap(rig.view.url)
        XCTAssertEqual(rig.coordinator.handler.source(for: url), a.standardizedFileURL.resolvingSymlinksInPath(), "a.md is back")
        let heading = try await rig.view.evaluateJavaScript("(document.querySelector('h1') || {}).textContent || ''") as? String
        XCTAssertEqual(heading, "Alpha")
    }

    /// Showing the file already on its own page (a fragment added by an
    /// in-page link) is not away: nothing is loaded again.
    func test_a_reshow_of_the_file_on_its_own_page_does_not_reload() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<h1 id=\"plans\">Plans</h1><script>window.loads = (window.loads || 0) + 1</script>").write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        let rig = rig(model)
        let first = file("art-1", path.path, media: .html)
        model.apply(created(1, first))
        rig.coordinator.apply(.html(path), to: rig.view)
        _ = await rig.agent.perform(show(first))
        _ = try await rig.view.evaluateJavaScript("window.marker = 'kept'; location.hash = 'plans'; true")
        let again = file("art-2", path.path, media: .html)
        model.apply(created(1, again))
        let result = await rig.agent.perform(show(again))
        XCTAssertTrue(result.ok, result.text)
        let marker = try await rig.view.evaluateJavaScript("window.marker || ''") as? String
        XCTAssertEqual(marker, "kept", "the page was not loaded again")
    }

    /// A page that loads after a failure (Back to the file, a retry) leaves
    /// no failure behind.
    func test_a_finished_page_clears_the_last_failure() async throws {
        let port = try await freeLoopbackPort()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/pricing"))
        let model = model()
        let rig = rig(model)
        rig.coordinator.apply(.url(url), to: rig.view)
        for _ in 0..<200 where rig.coordinator.failure == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(rig.coordinator.failure)
        rig.view.loadHTMLString(page("<h1>Pricing</h1>"), baseURL: url)
        for _ in 0..<80 where rig.view.url?.host() != "127.0.0.1" || rig.view.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(rig.coordinator.failure)
    }

    func test_show_with_auto_open_off_answers_at_once() async throws {
        let model = model()
        model.settings.autoOpen = false
        let rig = rig(model)
        let artifact = file("art-1", "/tmp/acme/pricing.html", media: .html)
        model.apply(created(1, artifact))
        let started = ContinuousClock.now
        let result = await rig.agent.perform(show(artifact))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
        XCTAssertNil(model.current[1], "nothing came to the front")
    }

    func test_show_answers_with_the_agent_view_off() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("pricing.html")
        try page("<h1>Pricing</h1>").write(to: path, atomically: true, encoding: .utf8)
        let model = model()
        model.settings.viewerAgentCanSee = false
        XCTAssertFalse(model.agentCanSee)
        let rig = rig(model)
        let artifact = file("art-1", path.path, media: .html)
        model.apply(created(1, artifact))
        rig.coordinator.apply(.html(path), to: rig.view)
        let result = await rig.agent.perform(show(artifact))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertNil(rig.agent.actingChat, "a show draws no acting glow")
    }

    func test_show_for_another_chat_in_multiple_presentation() async throws {
        let model = model()
        let rig = rig(model)
        let artifact = file("art-2", "/tmp/acme/pricing.html", media: .html)
        model.apply(created(2, artifact))
        let started = ContinuousClock.now
        let result = await rig.agent.perform(show(artifact, chat: 2))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
        XCTAssertNil(rig.agent.actingChat)
    }

    func test_show_of_a_file_that_is_not_a_web_page_answers_once_in_front() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("chart.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: path)
        let model = model()
        let rig = rig(model)
        let artifact = file("art-1", path.path, media: .image)
        model.apply(created(1, artifact))
        let result = await rig.agent.perform(show(artifact))
        XCTAssertTrue(result.ok, result.text)
        XCTAssertEqual(result.text, "Shown in the viewer.")
    }

    // MARK: - act_hosts on a web address the agent showed (spec §3.1)

    /// The act gate keys off the page's own host now: an address shown by
    /// the agent outside `act_hosts` can be looked at, not clicked or typed
    /// on; one inside can.
    func test_a_shown_web_address_is_usable_only_inside_act_hosts() async throws {
        func showRig(_ address: String) async throws -> (Rig, ViewerResult) {
            let model = model()
            hello(model, actHosts: ["acme.example"])
            let rig = rig(model)
            let url = try XCTUnwrap(URL(string: address))
            let artifact = Artifact(id: "art-1", kind: .url, location: address, media: .url, title: address, source: .tool, open: true)
            model.apply(created(1, artifact))
            XCTAssertEqual(model.current[1]?.location, address)
            // No network in tests: the page is loaded as if from the address.
            rig.agent.attach(rig.view, showing: .url(url))
            rig.view.loadHTMLString(
                page("<script>window.clicks = []</script><button onclick=\"clicks.push(1)\">Start trial</button><input aria-label=\"Email\">"),
                baseURL: url)
            return (rig, await rig.agent.perform(show(artifact)))
        }
        func act(_ action: ViewerAct.Action, _ args: [String: JSONValue]) -> ViewerAct {
            ViewerAct(id: "act-\(UUID().uuidString.prefix(6))", chat: 1, action: action, args: args)
        }

        let (outside, shownOutside) = try await showRig("https://pricing.example.com/plans")
        XCTAssertTrue(shownOutside.ok, shownOutside.text)
        let outsideText = "This page (pricing.example.com) can be looked at and scrolled, not used. The deployment's allow list sets which sites the agent can click and type on."
        let click = await outside.agent.perform(act(.click, ["target": .string("Start trial")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, outsideText)
        let typed = await outside.agent.perform(act(.type, ["target": .string("Email"), "text": .string("sam@acme.example")]))
        XCTAssertFalse(typed.ok)
        XCTAssertEqual(typed.text, outsideText)
        let clicks = try await outside.view.evaluateJavaScript("clicks.length") as? Int
        XCTAssertEqual(clicks, 0)

        let (inside, shownInside) = try await showRig("https://app.acme.example/plans")
        XCTAssertTrue(shownInside.ok, shownInside.text)
        let allowed = await inside.agent.perform(act(.click, ["target": .string("Start trial")]))
        XCTAssertTrue(allowed.ok, allowed.text)
        let typedInside = await inside.agent.perform(act(.type, ["target": .string("Email"), "text": .string("sam@acme.example")]))
        XCTAssertTrue(typedInside.ok, typedInside.text)
    }

    // MARK: - the list and X (§3.4, §3.6)

    func test_history_is_one_row_per_location_newest_first() {
        let model = model()
        model.apply(created(1, file("a-1", "/tmp/acme/a.md")))
        model.apply(created(1, file("b-1", "/tmp/acme/b.md")))
        model.apply(created(1, file("a-2", "/tmp/acme/a.md")))
        XCTAssertEqual(model.history(for: 1).map(\.location), ["/tmp/acme/a.md", "/tmp/acme/b.md"])
        XCTAssertEqual(model.history(for: 1).first?.id, "a-2", "the row is the file's newest showing")
    }

    func test_x_clears_the_viewer_and_closes_it() {
        let model = model()
        for name in ["a", "b", "c"] { model.apply(created(1, file("\(name)-1", "/tmp/acme/\(name).md"))) }
        XCTAssertEqual(model.current[1]?.id, "c-1")

        model.closeFile(in: 1)
        XCTAssertNil(model.current[1], "no older file comes forward")
        XCTAssertFalse(model.isViewerShown(for: 1))
        XCTAssertEqual(model.history(for: 1).count, 3, "every file stays in the list")

        model.setViewer(visible: true, for: 1)
        XCTAssertTrue(model.isViewerShown(for: 1))
        XCTAssertNil(model.current[1], "opened from the toolbar, the viewer is empty")
    }

    func test_x_sends_nothing_to_the_gateway() {
        let model = model()
        var sent: [ClientMessage] = []
        model.outbound = { sent.append($0) }
        model.apply(created(1, file("a-1", "/tmp/acme/a.md")))
        model.apply(created(1, file("b-1", "/tmp/acme/b.md")))
        sent = []
        model.closeFile(in: 1)
        XCTAssertTrue(sent.isEmpty, "X brings nothing forward, got \(sent)")
    }

    func test_after_x_any_file_opens_again() throws {
        let model = model()
        for name in ["a", "b"] { model.apply(created(1, file("\(name)-1", "/tmp/acme/\(name).md"))) }

        // The agent shows one again.
        model.closeFile(in: 1)
        model.apply(created(1, file("b-2", "/tmp/acme/b.md")))
        XCTAssertEqual(model.current[1]?.id, "b-2")
        XCTAssertTrue(model.isViewerShown(for: 1))

        // A pick from the list.
        model.closeFile(in: 1)
        let row = try XCTUnwrap(model.history(for: 1).first { $0.location == "/tmp/acme/a.md" })
        model.show(row, in: 1)
        XCTAssertEqual(model.current[1]?.id, "a-1")

        // A file the person opens from the Files pane.
        model.closeFile(in: 1)
        model.openArtifact(file: "/tmp/acme/b.md", in: 1)
        XCTAssertEqual(model.current[1]?.location, "/tmp/acme/b.md")
    }

    func test_the_toolbar_button_only_hides() {
        let model = model()
        model.apply(created(1, file("a-1", "/tmp/acme/a.md")))
        model.apply(created(1, file("b-1", "/tmp/acme/b.md")))
        model.setViewer(visible: false, for: 1)
        XCTAssertFalse(model.isViewerShown(for: 1))
        XCTAssertEqual(model.current[1]?.id, "b-1")
        model.setViewer(visible: true, for: 1)
        XCTAssertTrue(model.isViewerShown(for: 1))
        XCTAssertEqual(model.current[1]?.id, "b-1", "whatever was showing is still there")
    }
}

/// A plain-HTTP loopback server that answers every request, after
/// `delay`, with a 4 × 4 SVG: a page's image that loads slowly.
private final class SlowServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "slow-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _port: UInt16 = 0
    private var _requests = 0
    /// Seconds before each answer.
    let delay: Double

    init(delay: Double) {
        self.delay = delay
    }

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(_port)
    }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func start() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, _ in
                guard let self else { return }
                self.lock.lock()
                self._requests += 1
                self.lock.unlock()
                let body = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4"/></svg>"#.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                self.queue.asyncAfter(deadline: .now() + self.delay) {
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port, let self {
                        self.lock.lock()
                        self._port = port.rawValue
                        self.lock.unlock()
                    }
                    if resumed.take() { cont.resume() }
                case .failed(let error):
                    if resumed.take() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections = []
            listener?.cancel()
            listener = nil
        }
    }
}
