import AppKit
import Foundation
import WebKit
import XCTest

@testable import Portico

/// v0.17 §3.5–3.7: the "This session" list (made and opened icons, a
/// filter past 12, the row of the file in front highlighted by location),
/// the Properties block's fold remembered, and the header's buttons at one
/// icon size, with Obsidian's own app icon.
@MainActor
final class SessionListTests: XCTestCase {

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive = []
        super.tearDown()
    }

    private func suite() throws -> (UserDefaults, String) {
        let name = "portico-v17-session-list-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return (defaults, name)
    }

    private func model(_ defaults: UserDefaults? = nil) throws -> (AppModel, Settings) {
        let settings = Settings(defaults: try defaults ?? suite().0)
        let model = AppModel(settings: settings)
        model.outbound = { _ in }
        model.selected = 1
        return (model, settings)
    }

    private func hello(_ model: AppModel, presentation: String = "multiple", properties: String? = nil) {
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.17.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["viewer.v1"], presentation: presentation,
            viewerDefaults: ViewerDefaults(properties: properties))))
        model.selected = 1
    }

    private func artifact(
        _ id: String, _ location: String, title: String = "", kind: ArtifactKind = .file,
        media: Media = .markdown, source: ArtifactSource = .tool
    ) -> Artifact {
        Artifact(id: id, kind: kind, location: location, media: media, title: title, source: source, open: true)
    }

    // MARK: - the heading

    func test_the_list_is_this_session_or_this_chat() throws {
        let (model, _) = try model()
        hello(model, presentation: "single")
        XCTAssertEqual(model.madeHereLabel, "This session")
        hello(model, presentation: "multiple")
        XCTAssertEqual(model.madeHereLabel, "This chat")
    }

    // MARK: - made or opened

    func test_a_gateway_artifact_was_made_and_a_local_one_opened() {
        for source in [ArtifactSource.tool, .text, .producer] {
            let made = artifact("a-\(source.rawValue)", "/w/report.md", source: source)
            XCTAssertEqual(SessionFileOrigin.of(made), .made, "\(source)")
        }
        XCTAssertEqual(SessionFileOrigin.made.systemImage, "sparkles")
        let opened = artifact("local:/w/notes.md", "/w/notes.md", source: .text)
        XCTAssertEqual(SessionFileOrigin.of(opened), .opened)
        XCTAssertEqual(SessionFileOrigin.opened.systemImage, "eye")
    }

    /// Fix round 1: the row leads with the file's type; made or opened is
    /// a small mark after the title, in text2.
    func test_a_row_leads_with_the_file_type_and_marks_its_origin_after_the_title() throws {
        let text = ListFontSweepTests.withoutComments(try String(
            contentsOf: ListFontSweepTests.sources.appendingPathComponent("Views/Viewer/SessionFileList.swift"), encoding: .utf8))
        let start = try XCTUnwrap(text.range(of: "private func row(_ artifact: Artifact) -> some View {"))
        let row = String(text[start.upperBound...])
        let firstImage = try XCTUnwrap(row.range(of: "Image(systemName: "))
        XCTAssertTrue(row[firstImage.upperBound...].hasPrefix("shown.systemImage)"), "the leading icon is the file type")
        let title = try XCTUnwrap(row.range(of: "Text(shown.title)"))
        let mark = try XCTUnwrap(row.range(of: "Image(systemName: origin.systemImage)"), "the origin mark")
        XCTAssertLessThan(title.lowerBound, mark.lowerBound, "the mark follows the title")
        let markLines = row[mark.upperBound...].prefix(400)
        XCTAssertTrue(markLines.contains("Theme.text2"), String(markLines))
        XCTAssertTrue(markLines.contains("origin.accessibilityLabel"), String(markLines))
        XCTAssertTrue(markLines.contains(".tip(origin.accessibilityLabel)"), String(markLines))
    }

    // MARK: - the filter

    func test_the_filter_shows_past_twelve_files() {
        let twelve = (1...12).map { artifact("a-\($0)", "/w/f\($0).md") }
        XCTAssertFalse(SessionFilesPresentation(files: twelve, query: "").showsFilter)
        let thirteen = twelve + [artifact("a-13", "/w/f13.md")]
        XCTAssertTrue(SessionFilesPresentation(files: thirteen, query: "").showsFilter)
    }

    func test_the_filter_matches_title_or_location_ignoring_case_and_spaces() {
        let page = artifact("a-1", "/w/site/pricing.html", title: "pricing.html", media: .html)
        let site = artifact("a-2", "https://acme.example/pricing", title: "Acme", kind: .url, media: .url)
        let other = artifact("a-3", "/w/notes.md", title: "notes.md")
        let files = [page, site, other]

        let matched = SessionFilesPresentation(files: files, query: " PRICING ")
        XCTAssertEqual(matched.shown.map(\.id), ["a-1", "a-2"])
        XCTAssertNil(matched.emptyMessage)

        XCTAssertEqual(SessionFilesPresentation(files: files, query: "  ").shown.map(\.id), ["a-1", "a-2", "a-3"])
        XCTAssertNil(SessionFilesPresentation(files: files, query: "").emptyMessage)

        let none = SessionFilesPresentation(files: files, query: " zzz ")
        XCTAssertEqual(none.shown, [])
        XCTAssertEqual(none.emptyMessage, "Nothing in this session matches “zzz”")
    }

    // MARK: - the row in front

    /// After the one-row-per-location dedupe the row is the newest showing,
    /// while the file in front may be an older artifact of the same file:
    /// its row is still the highlighted one.
    func test_the_row_of_the_file_in_front_is_highlighted_by_location() throws {
        let (model, _) = try model()
        hello(model)
        let first = artifact("a-1", "/tmp/acme/a.md")
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: first)))
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: artifact("b-1", "/tmp/acme/b.md"))))
        model.show(first, in: 1)
        // A newer artifact for a.md arrives without coming forward.
        let newer = Artifact(id: "a-2", kind: .file, location: "/tmp/acme/a.md", media: .markdown,
                             title: "", source: .tool, open: false)
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: newer)))
        XCTAssertEqual(model.current[1]?.id, "a-1")

        let rows = model.history(for: 1)
        XCTAssertEqual(rows.map(\.id), ["a-2", "b-1"])
        XCTAssertEqual(rows.filter { SessionFilesPresentation.isInFront($0, current: model.current[1]) }.map(\.id), ["a-2"])
        XCTAssertFalse(SessionFilesPresentation.isInFront(rows[0], current: nil))
    }

    /// X clears the viewer, but every file stays in the list.
    func test_a_file_closed_with_x_stays_in_the_list() throws {
        let (model, _) = try model()
        hello(model)
        let a = artifact("a-1", "/tmp/acme/a.md")
        let b = artifact("b-1", "/tmp/acme/b.md")
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: a)))
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: b)))
        model.show(b, in: 1)
        model.closeFile(in: 1)
        XCTAssertNil(model.current[1])
        let list = SessionFilesPresentation(files: model.history(for: 1), query: "")
        XCTAssertEqual(list.shown.map(\.id), ["b-1", "a-1"])
    }

    /// Ruling 7: a row sits at its newest showing. A file opened again from
    /// the Files pane moves to the top, as a re-shown file does.
    func test_a_file_opened_again_moves_to_the_top() throws {
        let (model, _) = try model()
        hello(model)
        model.openArtifact(file: "/tmp/acme/a.md", in: 1)
        model.apply(.artifactCreated(ArtifactCreated(chat: 1, artifact: artifact("b-1", "/tmp/acme/b.md"))))
        XCTAssertEqual(model.history(for: 1).map(\.location), ["/tmp/acme/b.md", "/tmp/acme/a.md"])
        model.openArtifact(file: "/tmp/acme/a.md", in: 1)
        XCTAssertEqual(model.history(for: 1).map(\.location), ["/tmp/acme/a.md", "/tmp/acme/b.md"])
    }

    // MARK: - Properties

    func test_the_block_opens_only_when_asked_and_reports_its_toggle() throws {
        let matter = try XCTUnwrap(FrontMatter.split("---\nstatus: draft\n---\nBody").frontMatter)
        let folded = matter.html(open: false)
        XCTAssertTrue(folded.hasPrefix("<details class=\"fm\" "), folded)
        let foldedTag = String(folded[..<folded.range(of: ">")!.lowerBound])
        XCTAssertFalse(foldedTag.contains(" open"), foldedTag)
        // v0.24: no inline handler (the page's policy blocks them); the page's own script listens.
        XCTAssertFalse(foldedTag.contains("ontoggle="), foldedTag)
        XCTAssertTrue(foldedTag.contains("data-open=\"false\""), foldedTag)

        let open = matter.html(open: true)
        let openTag = String(open[..<open.range(of: ">")!.lowerBound])
        XCTAssertTrue(openTag.contains(" open"), openTag)
        XCTAssertFalse(openTag.contains("ontoggle="), openTag)
    }

    func test_the_page_carries_the_fold_it_is_given() throws {
        let source = "---\nstatus: draft\n---\n# Note"
        let folded = try MarkdownPage.html(source: source, title: "n.md", propertiesOpen: false)
        XCTAssertFalse(folded.contains("<details class=\"fm\" open"), "folded")
        let open = try MarkdownPage.html(source: source, title: "n.md", propertiesOpen: true)
        XCTAssertTrue(open.contains("<details class=\"fm\" open"), "open")
    }

    func test_the_fold_is_the_persons_choice_else_the_deployments_default() throws {
        let (defaults, _) = try suite()
        let (model, settings) = try model(defaults)
        XCTAssertNil(settings.propertiesOpen, "unset until the person first toggles a block")
        XCTAssertFalse(model.propertiesOpen, "no hello: folded")
        hello(model, properties: "open")
        XCTAssertTrue(model.propertiesOpen, "the deployment's default")
        hello(model, properties: "folded")
        XCTAssertFalse(model.propertiesOpen)

        hello(model, properties: "open")
        settings.propertiesOpen = false
        XCTAssertFalse(model.propertiesOpen, "the person's choice beats the default")

        let again = Settings(defaults: defaults)
        XCTAssertEqual(again.propertiesOpen, false, "remembered across launches")
        let relaunched = AppModel(settings: again)
        relaunched.outbound = { _ in }
        hello(relaunched, properties: "open")
        XCTAssertFalse(relaunched.propertiesOpen)
    }

    /// Hosted: a click on the block's summary in a real web view writes the
    /// choice; the page's own first draw does not.
    func test_a_toggle_on_the_page_writes_the_setting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("note.md")
        try "---\ntitle: Round 2\nstatus: draft\n---\n# Round 2\n\nBody.\n".write(to: markdown, atomically: true, encoding: .utf8)
        let (settings, _) = try suite()
        let store = Settings(defaults: settings)

        let coordinator = WebPane.Coordinator()
        coordinator.propertiesOpen = true
        coordinator.onPropertiesToggle = { store.propertiesOpen = $0 }
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        keepAlive = [view, coordinator]
        coordinator.apply(.markdown(markdown), to: view)
        try await poll("the page renders") { !view.isLoading && view.url?.scheme == RenderedPageHandler.scheme }
        for _ in 0..<200 {
            if try await view.evaluateJavaScript("document.querySelectorAll('h1').length") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let drawnOpen = try await view.evaluateJavaScript("document.querySelector('details.fm').open") as? Bool
        XCTAssertEqual(drawnOpen, true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.propertiesOpen, "drawing the page is not a choice")

        _ = try await view.evaluateJavaScript("document.querySelector('details.fm summary').click(); true")
        try await poll("the fold is written") { store.propertiesOpen == false }

        _ = try await view.evaluateJavaScript("document.querySelector('details.fm summary').click(); true")
        try await poll("and unfolded again") { store.propertiesOpen == true }
    }

    /// Fix round 1: only Portico's own rendered Markdown page, in the main
    /// frame, may move the fold.
    func test_only_the_main_frame_of_a_rendered_markdown_page_moves_the_fold() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("note.md")
        try "---\nstatus: draft\n---\n# Note\n".write(to: markdown, atomically: true, encoding: .utf8)
        let html = dir.appendingPathComponent("page.html")
        try "<h1>Page</h1>".write(to: html, atomically: true, encoding: .utf8)

        let coordinator = WebPane.Coordinator()
        var told: [Bool] = []
        coordinator.onPropertiesToggle = { told.append($0) }
        let page = try XCTUnwrap(coordinator.renderedURL(for: markdown))
        let served = coordinator.handler.register(file: html)
        coordinator.loadedForTesting = .markdown(markdown)

        coordinator.propertiesToggled(["open": true], isMainFrame: false, frameURL: page)
        coordinator.propertiesToggled(["open": true], isMainFrame: true, frameURL: URL(string: "https://acme.example/")!)
        coordinator.propertiesToggled(["open": true], isMainFrame: true, frameURL: served)
        XCTAssertEqual(told, [], "a frame, an outside site, a served HTML file")
        coordinator.loadedForTesting = .html(html)
        coordinator.propertiesToggled(["open": true], isMainFrame: true, frameURL: page)
        XCTAssertEqual(told, [], "the pane is not showing Markdown")
        coordinator.loadedForTesting = .markdown(markdown)
        coordinator.propertiesToggled(["open": true], isMainFrame: true, frameURL: page)
        XCTAssertEqual(told, [true])
    }

    /// Hosted: an HTML file's own script posting to the handler changes nothing.
    func test_a_post_from_an_html_page_changes_nothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-gate-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("page.html")
        try """
            <!doctype html><h1>Page</h1><script>
            window.webkit.messageHandlers.porticoProperties.postMessage({open: true});
            document.title = 'posted';
            </script>
            """.write(to: html, atomically: true, encoding: .utf8)
        let (defaults, _) = try suite()
        let store = Settings(defaults: defaults)
        let coordinator = WebPane.Coordinator()
        coordinator.onPropertiesToggle = { store.propertiesOpen = $0 }
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        keepAlive = [view, coordinator]
        coordinator.apply(.html(html), to: view)
        try await poll("the page posted") { !view.isLoading && view.title == "posted" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.propertiesOpen)
    }

    /// Hosted: a frame inside a Markdown page changes nothing. v0.24 (sweep
    /// #1): the page drops the frame before it is inserted, so it never
    /// loads; the handler's own frame check is covered above.
    func test_a_frame_in_a_markdown_page_is_dropped_and_changes_nothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-gate-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("note.md")
        try "---\nstatus: draft\n---\n# Note\n\n<iframe src=\"frame.html\"></iframe>\n".write(to: markdown, atomically: true, encoding: .utf8)
        try """
            <!doctype html><p>Frame</p><script>
            window.webkit.messageHandlers.porticoProperties.postMessage({open: false});
            document.title = 'posted';
            </script>
            """.write(to: dir.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
        let (defaults, _) = try suite()
        let store = Settings(defaults: defaults)
        let coordinator = WebPane.Coordinator()
        coordinator.propertiesOpen = true
        coordinator.onPropertiesToggle = { store.propertiesOpen = $0 }
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        keepAlive = [view, coordinator]
        coordinator.apply(.markdown(markdown), to: view)
        try await poll("the page renders") { !view.isLoading && view.url?.scheme == RenderedPageHandler.scheme }
        for _ in 0..<250 {
            if try await view.evaluateJavaScript("!!document.querySelector('#body h1')") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let frames = try await view.evaluateJavaScript("document.querySelectorAll('iframe').length") as? Int
        XCTAssertEqual(frames, 0, "the frame is dropped")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.propertiesOpen)
    }

    // MARK: - the header's icons

    func test_the_header_buttons_draw_their_glyphs_at_one_size() throws {
        XCTAssertEqual(ViewerHeader.iconSize, 12)
        XCTAssertEqual(ViewerHeader.iconWeight, .medium)
        let text = ListFontSweepTests.withoutComments(try String(
            contentsOf: ListFontSweepTests.sources.appendingPathComponent("Views/Viewer/ViewerView.swift"), encoding: .utf8))
        let start = try XCTUnwrap(text.range(of: "struct ViewerHeaderButton: View {"))
        let end = try XCTUnwrap(text.range(of: "struct ViewerColumn: View {"))
        let buttons = String(text[start.lowerBound..<end.lowerBound])
        for name in ["struct ViewerHeaderButton", "struct ViewerFocusButton", "struct ViewerCloseButton"] {
            XCTAssertTrue(buttons.contains(name), "\(name) is among the header's buttons")
        }
        let fonts = buttons.components(separatedBy: "iconFont(").dropFirst().map { String($0.prefix(while: { $0 != ")" })) }
        XCTAssertFalse(fonts.isEmpty)
        XCTAssertEqual(Set(fonts), ["ViewerHeader.iconSize, weight: ViewerHeader.iconWeight"], "\(fonts)")
        // Both headers' X are the shared button; no glyph of their own.
        let outside = text.replacingOccurrences(of: buttons, with: "")
        XCTAssertFalse(outside.contains("Image(systemName: \"xmark\")"), "an X drawn outside ViewerCloseButton")
    }

    func test_obsidians_icon_comes_from_the_installed_app() {
        XCTAssertNil(Obsidian.appIcon(resolving: { _ in nil }))
        var asked: URL?
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let icon = Obsidian.appIcon(resolving: { asked = $0; return finder })
        XCTAssertNotNil(icon)
        XCTAssertEqual(asked?.scheme, "obsidian")
    }

    // MARK: - helpers

    private func poll(_ what: String, seconds: Double = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
