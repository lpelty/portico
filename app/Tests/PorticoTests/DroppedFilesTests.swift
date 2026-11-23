import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import Portico

/// v0.28 (PORT-79): what a drop over the conversation gives the message box.
/// A file on disk is attached where it is; a promised file (no file until
/// the drop asks) is kept in the pending folder first; a folder is left out.
@MainActor
final class DroppedFilesTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: base.appendingPathComponent("a-folder"), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: base.appendingPathComponent("notes.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func onDisk(_ name: String) throws -> NSItemProvider {
        try XCTUnwrap(NSItemProvider(contentsOf: base.appendingPathComponent(name)))
    }

    /// A provider as a promising app makes it: no file URL, a file handed over on request.
    private func promised(_ name: String, _ text: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        let source = base.appendingPathComponent("source-\(UUID().uuidString).txt")
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all
        ) { completion in
            if let text {
                try? Data(text.utf8).write(to: source)
                completion(source, false, nil)
            } else {
                completion(nil, false, CocoaError(.fileNoSuchFile))
            }
            return nil
        }
        return provider
    }

    /// Dragged text, as a text view or a browser gives it: no file's name.
    private func text(_ string: String, named name: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider(object: string as NSString)
        provider.suggestedName = name
        return provider
    }

    func testDraggedTextAndALinkAreNotFiles() async throws {
        let pending = base.appendingPathComponent("pending")
        let link = NSItemProvider(object: try XCTUnwrap(URL(string: "https://example.com/report.pdf")) as NSURL)
        link.suggestedName = "report.pdf"
        let notFiles = [text("some words"), text("some words", named: "A title"), text("some words", named: ".hidden"), link]
        for provider in notFiles {
            XCTAssertFalse(DroppedFiles.takes(provider))
        }
        XCTAssertFalse(DroppedFiles.takes(notFiles), "a drop of these alone is refused")
        XCTAssertFalse(DroppedFiles.takes([]))

        let result = await DroppedFiles.load(notFiles, promisedInto: pending)
        XCTAssertEqual(result, DroppedFiles.Result(), "nothing attached, nothing counted as a file that failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "nothing was written")

        // Beside a file, the file alone is taken.
        XCTAssertTrue(DroppedFiles.takes([text("some words"), try onDisk("notes.md")]))
        let mixed = await DroppedFiles.load([text("some words"), try onDisk("notes.md"), link], promisedInto: pending)
        XCTAssertEqual(mixed, DroppedFiles.Result(paths: [base.appendingPathComponent("notes.md").path]))

        XCTAssertTrue(DroppedFiles.takes(try onDisk("a-folder")), "a folder is a file on disk: counted and left out by load")
        XCTAssertTrue(DroppedFiles.takes(promised("Quarterly plan.txt", "plan")))
    }

    func testAFileOnDiskIsAttachedWhereItIs() async throws {
        let result = await DroppedFiles.load([try onDisk("notes.md")], promisedInto: nil)
        XCTAssertEqual(result, DroppedFiles.Result(paths: [base.appendingPathComponent("notes.md").path]))
    }

    func testAFolderIsCountedAndLeftOut() async throws {
        let result = await DroppedFiles.load([try onDisk("a-folder"), try onDisk("notes.md")], promisedInto: nil)
        XCTAssertEqual(result.paths, [base.appendingPathComponent("notes.md").path])
        XCTAssertEqual(result.folders, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testAPromisedFileIsKeptInThePendingFolderUnderItsName() async throws {
        let pending = base.appendingPathComponent("pending", isDirectory: true)
        let result = await DroppedFiles.load([promised("Quarterly plan.txt", "plan")], promisedInto: pending)
        XCTAssertEqual(result.paths, [pending.appendingPathComponent("Quarterly plan.txt").path])
        XCTAssertEqual(try String(contentsOfFile: try XCTUnwrap(result.paths.first), encoding: .utf8), "plan")

        // The same name again is kept beside the first, never over it.
        let again = await DroppedFiles.load([promised("Quarterly plan.txt", "second")], promisedInto: pending)
        XCTAssertEqual(again.paths, [pending.appendingPathComponent("Quarterly plan-2.txt").path])
        XCTAssertEqual(try String(contentsOf: pending.appendingPathComponent("Quarterly plan.txt"), encoding: .utf8), "plan")
    }

    func testAPromiseThatGivesNoFileIsCountedAsFailed() async {
        let pending = base.appendingPathComponent("pending", isDirectory: true)
        let result = await DroppedFiles.load([promised("gone.txt", nil)], promisedInto: pending)
        XCTAssertEqual(result, DroppedFiles.Result(paths: [], folders: 0, failed: 1))
    }

    func testAPromisedFileWithNowhereToKeepItIsCountedAsFailed() async {
        let result = await DroppedFiles.load([promised("plan.txt", "plan")], promisedInto: nil)
        XCTAssertEqual(result, DroppedFiles.Result(paths: [], folders: 0, failed: 1))
    }

    /// The model's side: a drop becomes the draft's attachments, once each.
    func testADropBecomesTheDraftsAttachments() async throws {
        let model = AppModel(settings: Settings(defaults: try XCTUnwrap(UserDefaults(suiteName: "dropped-\(UUID().uuidString)"))))
        model.attachmentsHome = base
        let first = await model.attachDropped([try onDisk("notes.md"), promised("plan.txt", "plan")], to: 3).value
        XCTAssertEqual(first.paths.count, 2)
        XCTAssertEqual(model.draftAttachments[3], first.paths)
        XCTAssertEqual(first.paths.last, PastedImages.pendingFolder(home: base).appendingPathComponent("plan.txt").path)
        _ = await model.attachDropped([try onDisk("notes.md"), try onDisk("a-folder")], to: 3).value
        XCTAssertEqual(model.draftAttachments[3], first.paths, "the same file is attached once; a folder never")
    }
}
