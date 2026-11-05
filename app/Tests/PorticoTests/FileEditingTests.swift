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

    func testAFailedSaveCancelsTheFirstQuitThenKeepsCopiesAndQuits() async throws {
        let recovery = folder.appendingPathComponent("home/unsaved")
        let registry = EditSessions(recoveryFolder: recovery)
        let url = try write("c.md", "c\n")
        let edit = try session(url, registry: registry, writer: { _, _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })
        edit.currentText = { "c, edited\n" }
        var broughtForward: [String] = []
        registry.onQuitHeld = { broughtForward.append($0.location) }
        let delegate = AppDelegate()
        delegate.editSessions = registry
        var handled = 0
        delegate.quitHandler = { handled += 1 }

        let first = await delegate.prepareToTerminate()
        XCTAssertFalse(first, "the quit is cancelled, with no alert")
        XCTAssertEqual(handled, 0)
        XCTAssertEqual(broughtForward, [url.path], "the failing file is brought forward")
        XCTAssertEqual(edit.notice, "Couldn't save c.md — ⌘Q again quits and keeps your edits in \(EditRecovery.display(recovery))/")
        XCTAssertEqual(edit.text, "c, edited\n", "the text is kept")

        let second = await delegate.prepareToTerminate()
        XCTAssertTrue(second, "a second quit goes ahead")
        XCTAssertEqual(handled, 1)
        let copy = try XCTUnwrap(edit.recoveryURL)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "c, edited\n")
        XCTAssertEqual(EditRecovery.source(of: copy), url.path)
    }

    func testASuccessfulQuitSaveResetsTheHold() async throws {
        let registry = EditSessions(recoveryFolder: folder.appendingPathComponent("unsaved"))
        let url = try write("d.md", "d\n")
        let failing = FailingWriter()
        let edit = try session(url, registry: registry, writer: { text, url, stamp, bom in
            if failing.on { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            return try FileEditing.write(text, to: url, preserving: stamp, byteOrderMark: bom)
        })
        edit.currentText = { "d, edited\n" }
        let delegate = AppDelegate()
        delegate.editSessions = registry
        let firstQuit = await delegate.prepareToTerminate()
        XCTAssertFalse(firstQuit)
        // The disk has room again; the person retries, then quits: it quits.
        failing.on = false
        let quits = await delegate.prepareToTerminate()
        XCTAssertTrue(quits)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "d, edited\n")
        // A later failure holds the quit again (the hold was reset).
        let other = try write("e.md", "e\n")
        failing.on = true
        let second = try session(other, registry: registry, writer: { _, _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })
        second.currentText = { "e, edited\n" }
        let held = await delegate.prepareToTerminate()
        XCTAssertFalse(held)
    }

    func testQuitGate() {
        XCTAssertEqual(QuitGate.decide(saved: true, stage: .none), .quit)
        XCTAssertEqual(QuitGate.decide(saved: true, stage: .held), .quit)
        XCTAssertEqual(QuitGate.decide(saved: false, stage: .none), .cancel)
        XCTAssertEqual(QuitGate.decide(saved: false, stage: .held), .keepAndQuit)
        XCTAssertEqual(QuitGate.decide(saved: false, stage: .keepFailed), .quitAnyway)
    }

    func testAQuitWhoseRecoveryCopyFailsNeedsAThirdQuit() async throws {
        // The home folder can't be written: the recovery copy fails too.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("edit-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let registry = EditSessions(recoveryFolder: home.appendingPathComponent("unsaved"))
        let url = try write("f.md", "f\n")
        let edit = try session(url, registry: registry, writer: { _, _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        })
        edit.currentText = { "f, edited\n" }
        let delegate = AppDelegate()
        delegate.editSessions = registry
        var handled = 0
        delegate.quitHandler = { handled += 1 }
        let first = await delegate.prepareToTerminate()
        XCTAssertFalse(first)
        XCTAssertEqual(delegate.quitStage, .held)
        let second = await delegate.prepareToTerminate()
        XCTAssertFalse(second, "the copy couldn't be kept: cancelled once more")
        XCTAssertEqual(delegate.quitStage, .keepFailed)
        XCTAssertEqual(edit.notice, "Couldn't keep your edits to f.md — quit anyway with ⌘Q once more")
        let third = await delegate.prepareToTerminate()
        XCTAssertTrue(third)
        XCTAssertEqual(handled, 1)
    }

    // MARK: - the viewer's switch (fix round 1: no lost text)

    private func artifact(_ url: URL) -> Artifact {
        Artifact(id: "a-1", kind: .file, location: url.path, media: .markdown, title: "", source: .tool, open: false)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testEditIsOffAtEveryOpenAndAnotherFileSavesTheOld() async throws {
        let url = try write("switch.md", "x\n")
        let registry = EditSessions()
        let edit = ViewerEdit(registry: registry)
        XCTAssertFalse(edit.isEditing)
        edit.turnOn(artifact(url))
        let session = try XCTUnwrap(edit.session)
        session.currentText = { "x, edited\n" }
        edit.shown("/somewhere/else.md")
        XCTAssertFalse(edit.isEditing)
        try await eventually { (try? String(contentsOf: url, encoding: .utf8)) == "x, edited\n" }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x, edited\n")
        XCTAssertTrue(registry.all.isEmpty, "saved, it leaves the registry")
    }

    func testAFileSwitchAfterAFailedSaveKeepsTheTextAndARecoveryCopy() async throws {
        // The home folder is elsewhere: the file's own folder is made read-only.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("edit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let recovery = home.appendingPathComponent("unsaved")
        let registry = EditSessions(recoveryFolder: recovery)
        let url = try write("lost.md", "before\n")
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        let session = try XCTUnwrap(edit.session)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        session.currentText = { "typed and unsaved\n" }
        weak var weakSession = session
        edit.shown("/somewhere/else.md")
        try await eventually { session.recoveryURL != nil }
        XCTAssertFalse(edit.isEditing)
        XCTAssertTrue(registry.all.contains { $0 === session }, "the registry keeps it")
        let copy = try XCTUnwrap(session.recoveryURL)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "typed and unsaved\n")
        XCTAssertTrue(copy.lastPathComponent.hasSuffix("-lost.md"))
        XCTAssertEqual(session.notice, "Couldn't save lost.md; your edits are kept in \(EditRecovery.display(copy))")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        // Shown again, the file comes back in Edit with the person's text.
        edit.shown(url.path)
        XCTAssertTrue(edit.session === session)
        XCTAssertEqual(session.text, "typed and unsaved\n")
        _ = weakSession
    }

    func testHidingTheViewerSavesTheEdit() async throws {
        let url = try write("hide.md", "h\n")
        let registry = EditSessions()
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        edit.session?.markDirty()
        edit.session?.currentText = { "h, edited\n" }
        edit.shown(nil)  // the viewer went away (onDisappear)
        try await eventually { registry.all.isEmpty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "h, edited\n")
    }

    func testEndIsFalseWhenTheEditorsTextCantBeReached() async throws {
        let registry = EditSessions(recoveryFolder: folder.appendingPathComponent("unsaved"))
        let url = try write("gone.md", "g\n")
        let edit = try session(url, registry: registry)
        edit.markDirty()
        edit.currentText = { nil }
        let ended = await edit.end()
        XCTAssertFalse(ended)
        XCTAssertTrue(edit.isFailed)
        XCTAssertTrue(registry.all.contains { $0 === edit })
        edit.currentText = nil
        let endedWithNoEditor = await edit.end()
        XCTAssertFalse(endedWithNoEditor, "still dirty with no editor to ask")
    }

    func testConcurrentSavesAreSerialised() async throws {
        let url = try write("busy.md", "0\n")
        let probe = ConcurrencyProbe()
        let edit = try session(url, writer: { text, url, stamp, bom in
            probe.enter()
            defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.02)
            return try FileEditing.write(text, to: url, preserving: stamp, byteOrderMark: bom)
        })
        edit.textChanged("1\n")
        edit.textChanged("2\n")
        edit.textChanged("3\n")
        async let a: Void = edit.saveNow()
        async let b: Void = edit.saveNow()
        _ = await (a, b)
        await edit.saveNow()
        XCTAssertEqual(probe.maximum, 1, "one write at a time")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "3\n")
        XCTAssertEqual(edit.state, .saved)
    }

    func testAReconnectReplayKeepsTheEditedFileShown() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "edit-replay-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        let shown = Artifact(id: "t-1", kind: .file, location: "/tmp/demo/plan.md", media: .markdown,
                             title: "plan.md", source: .tool, open: true)
        model.apply(.artifactCreated(ArtifactCreated(chat: 3, artifact: shown)))
        model.show(shown, in: 3)
        XCTAssertEqual(model.current[3]?.id, "t-1")
        let loaded = EditableText(text: "", stamp: FileStamp(modified: nil, size: 0), lineEnding: .lf,
                                  trailingNewline: false, byteOrderMark: false)
        let session = EditSession(url: URL(fileURLWithPath: shown.location), loaded: loaded, mode: .markdown,
                                  language: "markdown", registry: .shared)
        session.attached = true
        defer { EditSessions.shared.remove(session) }
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [], truncated: false)))
        XCTAssertEqual(model.current[3]?.id, "t-1", "the replay doesn't throw the person out of Edit")
        session.attached = false
        model.apply(.chatHistory(ChatHistory(chat: 3, events: [], truncated: false)))
        XCTAssertNil(model.current[3], "not editing: the replay restores as before")
    }

    func testTurningEditOffSavesFirstAndStaysOnWhenItFails() async throws {
        let url = try write("off.md", "y\n")
        let edit = ViewerEdit(registry: EditSessions())
        edit.turnOn(artifact(url))
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

    func testRestoreUnsavedEditsIsOfferedForANewerRecoveryCopy() async throws {
        let recovery = folder.appendingPathComponent("unsaved")
        let registry = EditSessions(recoveryFolder: recovery)
        let url = try write("back.md", "old\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        let copy = try EditRecovery.newURL(for: "back.md", in: recovery)
        try EditRecovery.write("recovered\n", byteOrderMark: false, to: copy, source: url.resolvingSymlinksInPath())
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        XCTAssertEqual(edit.restore?.url, copy)
        await edit.restoreUnsaved()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "recovered\n")
        XCTAssertNil(edit.restore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the copy goes once its text is saved")
    }

    func testRestoreIsOfferedOnlyWhenTheCopyDiffers() throws {
        let recovery = folder.appendingPathComponent("unsaved")
        let registry = EditSessions(recoveryFolder: recovery)
        let url = try write("same.md", "same\n")
        let copy = try EditRecovery.newURL(for: "same.md", in: recovery)
        try EditRecovery.write("same\n", byteOrderMark: false, to: copy, source: url.resolvingSymlinksInPath())
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        XCTAssertNil(edit.restore)
    }

    // MARK: - fix round 2

    func testReattachingDuringASlowEndKeepsTheSessionHooked() async throws {
        let url = try write("aba.md", "a\n")
        let registry = EditSessions()
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        let session = try XCTUnwrap(edit.session)
        let gate = AsyncGate()
        session.currentText = { await gate.wait(); return "a, edited\n" }
        edit.shown("/elsewhere/b.md")  // A → B: the end starts and waits on the editor
        try await Task.sleep(nanoseconds: 20_000_000)
        edit.shown(url.path)  // B → A while the end is still running
        XCTAssertTrue(edit.session === session)
        let newHook: () async -> String? = { "from the new editor\n" }
        session.currentText = newHook
        gate.open()
        try await eventually { session.text == "a, edited\n" }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(registry.all.contains { $0 === session }, "still registered: a viewer shows it")
        XCTAssertNotNil(session.currentText, "the new editor's hook is left alone")
        let latest = await session.currentText?()
        XCTAssertEqual(latest, "from the new editor\n")
    }

    func testOneSessionPerFile() throws {
        let url = try write("shared.md", "s\n")
        let link = folder.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let registry = EditSessions()
        let first = ViewerEdit(registry: registry)
        let second = ViewerEdit(registry: registry)
        first.turnOn(artifact(url))
        XCTAssertTrue(first.isEditing)
        // The same file, through a link, in another viewer: read-only there.
        second.turnOn(artifact(link))
        XCTAssertFalse(second.isEditing)
        XCTAssertEqual(second.note, "Being edited in another viewer")
        XCTAssertTrue(second.editedElsewhere(link.path))
        XCTAssertEqual(registry.all.count, 1)
    }

    func testDiscardGoesBackToTheFileAndDeletesTheCopy() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("edit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = EditSessions(recoveryFolder: home.appendingPathComponent("unsaved"))
        let url = try write("discard.md", "on disk\n")
        let edit = ViewerEdit(registry: registry)
        edit.turnOn(artifact(url))
        let session = try XCTUnwrap(edit.session)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        session.textChanged("mine, unsaved\n")
        await session.saveNow()
        // textChanged's own save attempt finishes (and fails) too.
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.saveNow()
        XCTAssertTrue(session.isFailed)
        let copy = try XCTUnwrap(session.recoveryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await edit.discard()
        XCTAssertEqual(session.state, .saved)
        XCTAssertEqual(session.text, "on disk\n")
        XCTAssertFalse(session.hasUnsavedText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(DiscardConfirm.title, "Discard my edits")
        XCTAssertEqual(DiscardConfirm.confirmTitle, "Discard — sure?")
        XCTAssertEqual(DiscardConfirm.window, .seconds(4))
    }

    func testDiscardingADetachedSessionRemovesIt() async throws {
        let registry = EditSessions()
        let url = try write("away.md", "x\n")
        let edit = try session(url, registry: registry)
        edit.markDirty()
        await registry.discard(edit)
        XCTAssertTrue(registry.all.isEmpty)
    }

    func testARecoveryCopyIsDeletedAfterASuccessfulSave() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("edit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = EditSessions(recoveryFolder: home.appendingPathComponent("unsaved"))
        let url = try write("later.md", "l\n")
        let edit = try session(url, registry: registry)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        edit.textChanged("l2\n")
        await edit.saveNow()
        let copy = try XCTUnwrap(edit.recoveryURL)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: copy.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.int16Value, 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await edit.saveNow()
        XCTAssertEqual(edit.state, .saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNil(edit.recoveryURL)
    }

    func testOldRecoveryCopiesAreSwept() throws {
        let recovery = folder.appendingPathComponent("unsaved")
        let old = try EditRecovery.newURL(for: "old.md", in: recovery)
        try EditRecovery.write("o", byteOrderMark: false, to: old, source: URL(fileURLWithPath: "/tmp/old.md"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -31 * 86_400)], ofItemAtPath: old.path)
        let fresh = try EditRecovery.newURL(for: "fresh.md", in: recovery)
        try EditRecovery.write("f", byteOrderMark: false, to: fresh, source: URL(fileURLWithPath: "/tmp/fresh.md"))
        let stranger = recovery.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: stranger)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60 * 86_400)], ofItemAtPath: stranger.path)
        EditRecovery.sweep(recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "only recovery copies are swept")
    }

    func testUseTheirsWithNoEditorKeepsACopyFirst() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("edit-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = EditSessions(recoveryFolder: home.appendingPathComponent("unsaved"))
        let url = try write("noundo.md", "one\n")
        let edit = try session(url, registry: registry)
        edit.markDirty()
        try agentWrites("agent's\n", to: url)
        await edit.recheckDisk()
        XCTAssertEqual(edit.conflict, .agentChanged)
        edit.currentText = nil
        await edit.useTheirs()
        XCTAssertEqual(edit.text, "agent's\n")
        XCTAssertNotNil(edit.recoveryURL, "no undo to hold the person's text: a copy does")
    }

    func testADetachedFailureRaisesTheStatusNotice() async throws {
        let registry = EditSessions()
        var noticed: [String] = []
        registry.onDetachedFailure = { noticed.append($0.name) }
        let url = try write("bg.md", "b\n")
        let edit = try session(url, registry: registry, writer: { _, _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        edit.textChanged("b2\n")
        await edit.saveNow()
        XCTAssertEqual(noticed, ["bg.md"])
        XCTAssertEqual(EditNotice(name: "bg.md", path: url.path, chat: 3).text, "Couldn't save bg.md — open it to fix")
    }

    // MARK: - safe writes (fix round 1)

    func testAFileWithoutWritePermissionIsReadOnly() throws {
        let url = try write("locked.md", "l\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        XCTAssertEqual(FileEditing.editability(for: shown(url.path, media: .markdown)),
                       .readOnly(reason: "You don't have permission to change this file"))
    }

    func testALinkToALargeFileIsReadOnly() throws {
        let big = try write("big.log", Data(repeating: 0x61, count: Int(FileEditing.sizeLimit) + 10))
        let link = folder.appendingPathComponent("small-looking.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        XCTAssertEqual(FileEditing.editability(for: shown(link.path, media: .text)), .readOnly(reason: FileEditing.tooLarge))
    }

    func testTheTemporaryFileNeverHasWiderPermissions() throws {
        let url = try write("secret.md", "s\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let loaded = try FileEditing.read(url)
        var seen: NSNumber?
        try FileEditing.write("s2\n", to: url, preserving: loaded.stamp, beforeRename: {
            let names = try FileManager.default.contentsOfDirectory(atPath: self.folder.path)
            let temp = try XCTUnwrap(names.first { FileEditing.isTemporary($0, for: url) })
            seen = try FileManager.default.attributesOfItem(atPath: self.folder.appendingPathComponent(temp).path)[.posixPermissions] as? NSNumber
        })
        XCTAssertEqual(seen?.int16Value, 0o600)
    }

    func testExtendedAttributesAreKept() throws {
        let url = try write("tagged.md", "t\n")
        let value = Array("blue".utf8)
        XCTAssertEqual(value.withUnsafeBytes { setxattr(url.path, "com.example.tag", $0.baseAddress, $0.count, 0, 0) }, 0)
        let loaded = try FileEditing.read(url)
        try FileEditing.write("t2\n", to: url, preserving: loaded.stamp)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = buffer.withUnsafeMutableBytes { getxattr(url.path, "com.example.tag", $0.baseAddress, 16, 0, 0) }
        XCTAssertEqual(size, 4)
        XCTAssertEqual(String(decoding: buffer.prefix(4), as: UTF8.self), "blue")
    }

    func testStaleTemporariesAreSweptAtLoad() throws {
        let url = try write("note.md", "n\n")
        let stale = try write(".note.md.0a1b2c3d.saving", "half")
        let other = try write(".note.md.backup.saving", "not ours")
        let unrelated = try write(".other.md.0a1b2c3d.saving", "another file's")
        _ = try FileEditing.read(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - the agent changed the file (§2.6, Task 3)

    private func conflictSession(_ url: URL) throws -> (EditSession, ReplaceLog) {
        let log = ReplaceLog()
        let edit = try session(url)
        edit.editorReplace = { text, options in
            log.calls.append((text, options))
            return log.accept
        }
        return (edit, log)
    }

    private func agentWrites(_ text: String, to url: URL) throws {
        // A different size, so the stamp moves whatever the clock's grain.
        try Data(text.utf8).write(to: url)
    }

    func testACleanSessionReloadsWithNoBar() async throws {
        let url = try write("clean.md", "one\n")
        let (edit, log) = try conflictSession(url)
        try agentWrites("one, and the agent's line\n", to: url)
        await edit.recheckDisk()
        XCTAssertNil(edit.conflict)
        XCTAssertEqual(edit.state, .saved)
        XCTAssertEqual(edit.text, "one, and the agent's line\n")
        XCTAssertEqual(edit.baseline, FileStamp.of(url))
        XCTAssertEqual(log.calls.first?.1, EditSession.Replace(keepCursorLine: true, keepUndo: false, force: false))
    }

    func testTheEditorRefusingAReloadShowsTheBar() async throws {
        let url = try write("refuse.md", "one\n")
        let (edit, log) = try conflictSession(url)
        log.accept = false
        try agentWrites("agent's\n", to: url)
        await edit.recheckDisk()
        XCTAssertEqual(edit.conflict, .agentChanged)
        XCTAssertEqual(edit.state, .paused)
    }

    func testADirtySessionShowsTheBarAndWritesNothing() async throws {
        let url = try write("dirty.md", "one\n")
        let (edit, log) = try conflictSession(url)
        edit.markDirty()
        try agentWrites("the agent's version\n", to: url)
        await edit.recheckDisk()
        XCTAssertEqual(edit.conflict, .agentChanged)
        XCTAssertEqual(edit.state, .paused)
        XCTAssertTrue(log.calls.isEmpty, "never replaced while edits are unsaved")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "the agent's version\n")
    }

    func testASaveTimeMismatchShowsTheBarAndWritesNothing() async throws {
        let url = try write("race.md", "one\n")
        let (edit, _) = try conflictSession(url)
        try agentWrites("the agent got there first\n", to: url)
        edit.textChanged("one, mine\n")
        await edit.saveNow()
        XCTAssertEqual(edit.conflict, .agentChanged)
        XCTAssertEqual(edit.state, .paused)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "the agent got there first\n")
    }

    func testWhilePausedAutosaveDoesNothing() async throws {
        let url = try write("paused.md", "one\n")
        let (edit, _) = try conflictSession(url)
        edit.markDirty()
        try agentWrites("agent's text\n", to: url)
        await edit.recheckDisk()
        edit.textChanged("more of mine\n")
        await edit.saveNow()
        XCTAssertEqual(edit.state, .paused)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "agent's text\n")
        let ended = await edit.end()
        XCTAssertFalse(ended, "ending while the bar is up keeps the session")
    }

    func testKeepMineWrites() async throws {
        let url = try write("mine.md", "one\n")
        let (edit, _) = try conflictSession(url)
        edit.textChanged("one, mine\n")
        try agentWrites("the agent's longer version\n", to: url)
        await edit.saveNow()
        XCTAssertEqual(edit.conflict, .agentChanged)
        edit.currentText = { "one, mine, final\n" }
        await edit.keepMine()
        XCTAssertNil(edit.conflict)
        XCTAssertEqual(edit.state, .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one, mine, final\n")
        XCTAssertEqual(edit.baseline, FileStamp.of(url))
    }

    func testUseTheirsLoadsTheDiskText() async throws {
        let url = try write("theirs.md", "one\n")
        let (edit, log) = try conflictSession(url)
        edit.markDirty()
        try agentWrites("the agent's version\n", to: url)
        await edit.recheckDisk()
        XCTAssertEqual(edit.conflict, .agentChanged)
        await edit.useTheirs()
        XCTAssertNil(edit.conflict)
        XCTAssertEqual(edit.state, .saved)
        XCTAssertEqual(edit.text, "the agent's version\n")
        XCTAssertFalse(edit.hasUnsavedText, "a forced replace clears the editor's dirty flag")
        XCTAssertEqual(log.calls.last?.1, EditSession.Replace(keepCursorLine: true, keepUndo: true, force: true))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "the agent's version\n", "nothing written")
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
        // Wrap code changes in place (a compartment); Markdown always wraps.
        coordinator.wrap = true
        await coordinator.reconfigure()
        let text = await coordinator.visibleText()
        XCTAssertEqual(text, edit.text, "the editor holds the file's text, CRLF and all")
        coordinator.tearDown(view)
    }
}

/// Records the editor replacements a session asked for.
@MainActor
private final class ReplaceLog {
    var calls: [(String, EditSession.Replace)] = []
    var accept = true
}

private final class FailingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maximum = 0
    func enter() { lock.withLock { current += 1; maximum = max(maximum, current) } }
    func leave() { lock.withLock { current -= 1 } }
}

/// A gate a test opens by hand.
@MainActor
private final class AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
