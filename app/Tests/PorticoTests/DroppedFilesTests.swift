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
