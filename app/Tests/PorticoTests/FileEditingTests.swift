import XCTest
@testable import Portico

/// v0.20 §2.1 and §2.5: what can be edited, and saving it byte for byte.
@MainActor
final class FileEditingTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        try write(name, Data(text.utf8))
    }

    private func shown(_ location: String, media: Media, kind: ArtifactKind = .file, id: String = "a-1") -> ArtifactPresentation {
        ArtifactPresentation(artifact: Artifact(
            id: id, kind: kind, location: location, media: media, title: "", source: .tool, open: false))
    }

    // MARK: - editability

    func testEditabilityForEveryKind() throws {
        let md = try write("notes.md", "# Notes\n")
        let txt = try write("plain.txt", "hello\n")
        let swift = try write("app.swift", "let a = 1\n")
        let html = try write("page.html", "<p>hi</p>\n")
        let csv = try write("q3.csv", "a,b\n1,2\n")
        let tsv = try write("q3.tsv", "a\tb\n")
        let png = try write("pic.png", Data([0x89, 0x50]))
        let pdf = try write("doc.pdf", Data([0x25, 0x50]))
        let docx = try write("brief.docx", Data([0x50, 0x4B]))
        let makefile = try write("Makefile", "all:\n")

        XCTAssertEqual(FileEditing.editability(for: shown(md.path, media: .markdown)),
                       .editable(mode: .markdown, language: "markdown"))
        XCTAssertEqual(FileEditing.editability(for: shown(txt.path, media: .text)), .editable(mode: .code, language: "txt"))
        XCTAssertEqual(FileEditing.editability(for: shown(swift.path, media: .text)), .editable(mode: .code, language: "swift"))
        XCTAssertEqual(FileEditing.editability(for: shown(makefile.path, media: .text)), .editable(mode: .code, language: nil))
        XCTAssertEqual(FileEditing.editability(for: shown(html.path, media: .html)), .editable(mode: .code, language: "html"))
        XCTAssertEqual(FileEditing.editability(for: shown(csv.path, media: .text)), .readOnly(reason: FileEditing.tableReason))
        XCTAssertEqual(FileEditing.editability(for: shown(tsv.path, media: .text)), .readOnly(reason: FileEditing.tableReason))
        XCTAssertEqual(FileEditing.editability(for: shown(png.path, media: .image)), .readOnly(reason: FileEditing.kindReason))
        XCTAssertEqual(FileEditing.editability(for: shown(pdf.path, media: .pdf)), .readOnly(reason: FileEditing.kindReason))
        XCTAssertEqual(FileEditing.editability(for: shown(docx.path, media: .other)), .readOnly(reason: FileEditing.kindReason))
        XCTAssertEqual(FileEditing.editability(for: shown("https://example.com", media: .url, kind: .url)),
                       .readOnly(reason: FileEditing.webReason))
        XCTAssertEqual(FileEditing.editability(for: shown(md.path, media: .markdown, id: AppModel.spaceArtifactPrefix + "plan")),
                       .readOnly(reason: FileEditing.spaceReason))
        XCTAssertEqual(FileEditing.editability(for: shown(folder.appendingPathComponent("gone.md").path, media: .markdown)),
                       .readOnly(reason: FileEditing.missingReason))
    }

    func testOverTwoMegabytesIsReadOnly() throws {
        let big = try write("big.txt", Data(repeating: 0x61, count: Int(FileEditing.sizeLimit) + 1))
        XCTAssertEqual(FileEditing.editability(for: shown(big.path, media: .text)), .readOnly(reason: "Too large to edit here"))
        let edge = try write("edge.txt", Data(repeating: 0x61, count: Int(FileEditing.sizeLimit)))
        XCTAssertTrue(FileEditing.editability(for: shown(edge.path, media: .text)).canEdit)
    }

    // MARK: - line endings (Review Focus 1)

    func testCRLFWithNoFinalNewlineIsSavedByteIdenticalWhenUnchanged() throws {
        let bytes = Data("first line\r\nsecond line\r\nno newline at the end".utf8)
        let url = try write("crlf.txt", bytes)
        let loaded = try FileEditing.read(url)
        XCTAssertEqual(loaded.lineEnding, .crlf)
        XCTAssertFalse(loaded.trailingNewline)
        try FileEditing.write(loaded.text, to: url, preserving: loaded.stamp)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testCRLFWithOneChangedWordChangesOnlyThoseBytes() throws {
        let before = "alpha beta\r\ngamma delta\r\nepsilon"
        let url = try write("crlf.md", before)
        let loaded = try FileEditing.read(url)
        // The editor hands back the file's own endings (CRLF in, CRLF out).
        let edited = loaded.text.replacingOccurrences(of: "gamma", with: "GAMMA")
        try FileEditing.write(edited, to: url, preserving: loaded.stamp)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, Data("alpha beta\r\nGAMMA delta\r\nepsilon".utf8))
        let differing = zip(Data(before.utf8), after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(differing, Array(12..<17), "only the word's bytes changed")
    }

    func testMixedEndingsAndBOMAreKept() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("a\r\nb\nc\n".utf8))
        let url = try write("mixed.txt", bytes)
        let loaded = try FileEditing.read(url)
        XCTAssertTrue(loaded.byteOrderMark)
        try FileEditing.write(loaded.text, to: url, preserving: loaded.stamp, byteOrderMark: loaded.byteOrderMark)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // MARK: - the write

    func testPermissionsAreKept() throws {
        let url = try write("script.sh", "echo hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: url.path)
        let loaded = try FileEditing.read(url)
        try FileEditing.write("echo bye\n", to: url, preserving: loaded.stamp)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o750)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "echo bye\n")
    }

    func testAtomicNoPartialFileWhenTheWriteThrows() throws {
        struct Boom: Error {}
        let url = try write("keep.md", "the original\n")
        let loaded = try FileEditing.read(url)
        XCTAssertThrowsError(try FileEditing.write("half of something new", to: url, preserving: loaded.stamp,
                                                   beforeRename: { throw Boom() }))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "the original\n")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, ["keep.md"], "no temporary file is left behind")
    }

    func testALinkIsWrittenThroughToItsFile() throws {
        let real = try write("real.md", "one\n")
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let loaded = try FileEditing.read(link)
        try FileEditing.write("two\n", to: link, preserving: loaded.stamp)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "two\n")
    }

    func testAFileChangedOnDiskSinceTheStampIsNotWritten() throws {
        let url = try write("race.md", "mine\n")
        let loaded = try FileEditing.read(url)
        try Data("the agent's longer text\n".utf8).write(to: url)
        XCTAssertThrowsError(try FileEditing.write("mine, edited\n", to: url, preserving: loaded.stamp)) {
            XCTAssertEqual($0 as? FileEditing.Failure, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "the agent's longer text\n")
    }

    func testNonUTF8IsNotEditable() throws {
        let url = try write("latin1.txt", Data([0x63, 0x61, 0x66, 0xE9]))
        XCTAssertThrowsError(try FileEditing.read(url)) { XCTAssertEqual($0 as? FileEditing.Failure, .notText) }
    }

    // MARK: - EditSession

    private func session(_ url: URL, registry: EditSessions? = nil, writer: EditSession.Writer? = nil) throws -> EditSession {
        let loaded = try FileEditing.read(url)
        if let writer {
            return EditSession(url: url, loaded: loaded, mode: .code, language: nil, writer: writer, registry: registry)
        }
        return EditSession(url: url, loaded: loaded, mode: .code, language: nil, registry: registry)
    }

    func testTextChangedSavesAndTheStateComesBackToSaved() async throws {
        let url = try write("auto.txt", "one\n")
        let edit = try session(url)
        edit.textChanged("one two\n")
        await edit.saveNow()
        XCTAssertEqual(edit.state, .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one two\n")
        XCTAssertEqual(edit.baseline, FileStamp.of(url))
        // A second save after the first goes through on the new stamp.
        edit.textChanged("one two three\n")
        await edit.saveNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one two three\n")
    }

    func testEndSavesPendingText() async throws {
        let url = try write("pending.md", "draft\n")
        let edit = try session(url)
        // The editor has typing it hasn't sent (inside its 800 ms): end() asks for it.
        edit.markDirty()
        XCTAssertTrue(edit.hasUnsavedText)
        edit.currentText = { "draft, finished\n" }
        let saved = await edit.end()
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "draft, finished\n")
        XCTAssertFalse(edit.hasUnsavedText)
    }

    func testEndWithNothingChangedWritesNothing() async throws {
        let url = try write("same.md", "unchanged\r\n")
        let stamp = try XCTUnwrap(FileStamp.of(url))
        let edit = try session(url)
        edit.currentText = { "unchanged\r\n" }
        let saved = await edit.end()
        XCTAssertTrue(saved)
        XCTAssertEqual(FileStamp.of(url), stamp, "the file was not touched")
    }

    func testAFailedSaveKeepsTheTextAndSaysWhy() async throws {
        let url = try write("locked.txt", "before\n")
        let edit = try session(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        edit.textChanged("after\n")
        await edit.saveNow()
        XCTAssertEqual(edit.state, .failed("no permission to write it"))
        XCTAssertEqual(edit.text, "after\n")
        XCTAssertTrue(edit.hasUnsavedText)
        XCTAssertEqual(ViewerEditStatus.words(for: edit.state), "Not saved — no permission to write it")
        let ended = await edit.end()
        XCTAssertFalse(ended)
        // Retry once the folder can be written again.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await edit.saveNow()
        XCTAssertEqual(edit.state, .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after\n")
    }

    func testHeaderWords() {
        XCTAssertEqual(ViewerEditStatus.words(for: .saved), "Editing · Saved")
        XCTAssertEqual(ViewerEditStatus.words(for: .saving), "Editing · Saving…")
        XCTAssertEqual(ViewerEditStatus.words(for: .failed("the disk is full")), "Not saved — the disk is full")
    }

    // MARK: - quitting (Review Focus 4)

    func testQuittingCallsEndOnEverySession() async throws {
        let registry = EditSessions()
        let a = try write("a.md", "a\n"), b = try write("b.md", "b\n")
        let first = try session(a, registry: registry)
        let second = try session(b, registry: registry)
        first.currentText = { "a, edited\n" }
        second.markDirty()
        second.currentText = { "b, edited\n" }
        XCTAssertEqual(registry.all.count, 2)

        let delegate = AppDelegate()
        delegate.editSessions = registry
        var handled = false
        delegate.quitHandler = { handled = true }
        let proceed = await delegate.prepareToTerminate()
        XCTAssertTrue(proceed)
        XCTAssertTrue(handled, "the gateway's quit handling runs after the saves")
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a, edited\n")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b, edited\n")
        XCTAssertTrue(registry.all.isEmpty, "ended sessions leave the registry")
    }

    func testAFailedSaveCancelsTheFirstQuitAndNotTheSecond() async throws {
        struct Full: Error {}
        let registry = EditSessions()
        let url = try write("c.md", "c\n")
        let edit = try session(url, registry: registry, writer: { _, _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })
        edit.currentText = { "c, edited\n" }
        let delegate = AppDelegate()
        delegate.editSessions = registry
        var handled = 0
        delegate.quitHandler = { handled += 1 }

        let first = await delegate.prepareToTerminate()
        XCTAssertFalse(first, "the quit is cancelled, with no alert")
        XCTAssertEqual(handled, 0)
        XCTAssertEqual(edit.state, .failed("the disk is full" + EditSessions.quitAgain))
        XCTAssertEqual(edit.text, "c, edited\n", "the text is kept")

        let second = await delegate.prepareToTerminate()
        XCTAssertTrue(second, "a second quit goes ahead")
        XCTAssertEqual(handled, 1)
    }

    func testQuitGate() {
        XCTAssertEqual(QuitGate.decide(saved: true, alreadyHeld: false), .quit)
        XCTAssertEqual(QuitGate.decide(saved: false, alreadyHeld: false), .cancel)
        XCTAssertEqual(QuitGate.decide(saved: false, alreadyHeld: true), .quit)
    }

    // MARK: - the viewer's switch and links

    func testEditIsOffAtEveryOpenAndAnotherFileSavesTheOld() async throws {
        let url = try write("switch.md", "x\n")
        let artifact = Artifact(id: "a-1", kind: .file, location: url.path, media: .markdown, title: "", source: .tool, open: false)
        let edit = ViewerEdit()
        XCTAssertFalse(edit.isEditing)
        edit.turnOn(artifact, registry: EditSessions())
        let session = try XCTUnwrap(edit.session)
        session.currentText = { "x, edited\n" }
        edit.shown("/somewhere/else.md")
        XCTAssertFalse(edit.isEditing)
        // The old file's text is saved in the background.
        for _ in 0..<100 where (try? String(contentsOf: url, encoding: .utf8)) != "x, edited\n" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x, edited\n")
    }

    func testTurningEditOffSavesFirstAndStaysOnWhenItFails() async throws {
        let url = try write("off.md", "y\n")
        let artifact = Artifact(id: "a-1", kind: .file, location: url.path, media: .markdown, title: "", source: .tool, open: false)
        let edit = ViewerEdit()
        edit.turnOn(artifact, registry: EditSessions())
        let session = try XCTUnwrap(edit.session)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        session.currentText = { "y, edited\n" }
        await edit.turnOff()
        XCTAssertTrue(edit.isEditing, "a failed save keeps Edit on")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await edit.turnOff()
        XCTAssertFalse(edit.isEditing)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "y, edited\n")
    }

    func testEditorLinksRouteSafely() {
        let base = folder!
        XCTAssertEqual(EditorLink.route(URL(string: "https://example.com/a"), folder: base), .external(URL(string: "https://example.com/a")!))
        XCTAssertEqual(EditorLink.route(URL(string: "mailto:sam@example.com"), folder: base), .external(URL(string: "mailto:sam@example.com")!))
        XCTAssertEqual(EditorLink.route(URL(string: "javascript:alert(1)"), folder: base), .refused)
        XCTAssertEqual(EditorLink.route(URL(string: "x-custom://open"), folder: base), .refused)
        XCTAssertEqual(EditorLink.route(URL(fileURLWithPath: "/etc/hosts"), folder: base), .refused)
        XCTAssertEqual(EditorLink.route(base.appendingPathComponent(".git/config"), folder: base), .refused)
        XCTAssertEqual(EditorLink.route(base.appendingPathComponent("../outside.md"), folder: base), .refused)
        let inside = base.appendingPathComponent("plan.md")
        XCTAssertEqual(EditorLink.route(inside, folder: base),
                       .file(inside.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    func testHeaderFitCountsTheEditControls() {
        var widths = HeaderFit.Widths(title: 100, note: 0, chipFull: 0, chipShort: 0, chipCount: 0,
                                      buttonsLabelled: 120, buttonsIcons: 30, fixed: 100)
        XCTAssertEqual(HeaderFit.step(available: 320, widths), .full)
        widths.edit = 140
        XCTAssertEqual(HeaderFit.step(available: 320, widths), .titleShrinks)
        XCTAssertEqual(HeaderFit.step(available: 370, widths), .buttonIcons)
    }

    // MARK: - the editor page in a web view

    /// The page loads under its CSP with the file's folder as its base: the
    /// editor says ready, shows the text, and a relative image draws.
    func testTheEditorLoadsAndRelativeImagesResolve() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAEklEQVR4nGP4z8DwH4QZYAwAX+AF+wM+B7sAAAAASUVORK5CYII=")!
        _ = try write("dot.png", png)
        let url = try write("page.md", "# Title\r\n\r\nText\r\n\r\n![dot](dot.png)\r\n\r\nEnd\r\n")
        let edit = EditSession(url: url, loaded: try FileEditing.read(url), mode: .markdown, language: "markdown", registry: nil)
        let coordinator = EditorPane.Coordinator()
        coordinator.session = edit
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        // In a window (off screen), so the page lays out and animates.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        coordinator.start(in: view)
        for _ in 0..<500 where !coordinator.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(coordinator.ready, "the editor said ready")
        var width = 0
        for _ in 0..<300 {
            let value = try? await view.callAsyncJavaScript(
                "const i = document.querySelector('.cm-md-image img'); return i ? i.naturalWidth : -1;",
                arguments: [:], in: nil, contentWorld: .page)
            width = (value as? NSNumber)?.intValue ?? -1
            if width > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(width, 2, "the relative image loaded")
        // Only the page's own load navigates; a link from the folder opens in
        // the viewer, a web address goes nowhere from here but the system.
        var opened: [String] = []
        coordinator.onOpenFile = { opened.append($0) }
        _ = try? await view.callAsyncJavaScript(
            "window.open('notes.md', '_blank'); window.open('.git/config'); window.open('javascript:alert(1)'); location.href = 'x-custom://go'; return true;",
            arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(opened, [folder.appendingPathComponent("notes.md").standardizedFileURL.resolvingSymlinksInPath().path])
        XCTAssertEqual(view.url?.scheme, RenderedPageHandler.scheme, "the page stayed")
        let text = await coordinator.visibleText()
        XCTAssertEqual(text, edit.text, "the editor holds the file's text, CRLF and all")
        coordinator.tearDown(view)
    }
}
