import Foundation
import XCTest

@testable import Portico

/// v0.22.1 item 25: the Folders tab keeps which folders are open per session
/// (per chat), in the model, like the session's own "Changed this session":
/// switching to Bookmarks or to another session and back shows the tree as
/// it was left.
@MainActor
final class OpenFoldersTests: XCTestCase {
    private func model() throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-open-folders-\(UUID().uuidString)"))
        return AppModel(settings: Settings(defaults: defaults))
    }

    func testAFolderOpensAndClosesInItsChat() throws {
        let model = try model()
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
    }

    func testEachChatKeepsItsOwnOpenFolders() throws {
        let model = try model()
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        model.toggleFolder(chat: 1, root: "chat", path: "docs/notes")
        model.toggleFolder(chat: 2, root: "Vault", path: "docs")
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs/notes"))
        XCTAssertFalse(model.isFolderOpen(chat: 2, root: "chat", path: "docs"))
        XCTAssertTrue(model.isFolderOpen(chat: 2, root: "Vault", path: "docs"))
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "Vault", path: "docs"), "same path, other root")
        // Switching chats and back changes nothing.
        model.selected = 2
        model.selected = 1
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs/notes"))
    }

    /// The tree's view is torn down when the tab switches: its open folders
    /// live in the model, not the view.
    func testTheTreeKeepsNoOpenFoldersOfItsOwn() throws {
        let source = try String(
            contentsOf: ListFontSweepTests.sources.appendingPathComponent("Views/Sidebar/FilesView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("@State private var expanded: Set<String>"))
        XCTAssertTrue(source.contains("model.toggleFolder("))
    }
}
