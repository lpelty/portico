import AppKit
import XCTest

@testable import Portico

/// v0.28 (PORT-79, PORT-87): what a drop over the conversation gives the
/// message box, read from the drag's pasteboard as a drop on the message
/// text is. A file on disk is attached where it is; a folder is left out;
/// text and a link are refused.
@MainActor
final class DroppedFilesTests: XCTestCase {
    private var base: URL!
    private var pasteboard: NSPasteboard!
    private var model: AppModel!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: base.appendingPathComponent("a-folder"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: base.appendingPathComponent("notes.md"))
        try Data("plan".utf8).write(to: base.appendingPathComponent("plan.txt"))
        pasteboard = NSPasteboard.withUniqueName()
        model = AppModel(settings: Settings(defaults: try XCTUnwrap(UserDefaults(suiteName: "dropped-\(UUID().uuidString)"))))
        model.attachmentsHome = base
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: base)
    }

    private func path(_ name: String) -> String { base.appendingPathComponent(name).path }

    /// What Finder puts on the drag's pasteboard for these files.
    private func drag(_ names: [String]) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(names.map { base.appendingPathComponent($0) as NSURL }))
    }

    /// The attachments are there when the drop handler returns: nothing is awaited.
    func testADroppedFileIsAttachedBeforeTheDropHandlerReturns() {
        drag(["notes.md"])
        XCTAssertTrue(model.attachDropped(from: pasteboard, to: 3))
        XCTAssertEqual(model.draftAttachments[3], [path("notes.md")])
    }

    func testSeveralFilesAreAttachedInOrderAndTheSameFileOnce() {
        drag(["notes.md", "plan.txt"])
        XCTAssertTrue(model.attachDropped(from: pasteboard, to: 3))
        drag(["plan.txt"])
        XCTAssertTrue(model.attachDropped(from: pasteboard, to: 3))
        XCTAssertEqual(model.draftAttachments[3], [path("notes.md"), path("plan.txt")])
        XCTAssertNil(model.draftAttachments[4], "another chat's draft is untouched")
    }

    func testAFolderIsLeftOut() {
        drag(["a-folder", "notes.md"])
        XCTAssertTrue(model.attachDropped(from: pasteboard, to: 3))
        XCTAssertEqual(model.draftAttachments[3], [path("notes.md")])

        drag(["a-folder"])
        XCTAssertTrue(model.attachDropped(from: pasteboard, to: 5), "taken, so its path never lands as text")
        XCTAssertNil(model.draftAttachments[5])
    }

    func testDraggedTextAndALinkAreRefused() {
        pasteboard.clearContents()
        pasteboard.setString("some words", forType: .string)
        XCTAssertFalse(model.attachDropped(from: pasteboard, to: 3))

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([NSURL(string: "https://example.com/page")!]))
        XCTAssertFalse(model.attachDropped(from: pasteboard, to: 3))

        pasteboard.clearContents()
        XCTAssertFalse(model.attachDropped(from: pasteboard, to: 3), "an empty drop")
        XCTAssertNil(model.draftAttachments[3])
    }
}
