import Foundation
import XCTest

@testable import Portico

/// The Files tree's open folders (v0.22.1 item 25; v0.26.5): kept in the
/// model, by where each folder is on disk, and written to the settings, so
/// the tree is as it was left after switching tabs or chats, after a
/// restart, and in a later session that shows the same folder.
@MainActor
final class OpenFoldersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var base: URL!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-open-folders-\(UUID().uuidString)"))
        base = FileManager.default.temporaryDirectory.appendingPathComponent("open-folders-\(UUID().uuidString)", isDirectory: true)
        for path in ["one/docs/notes", "two/docs", "vault/docs"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        base = base.standardizedFileURL
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func session(_ chat: Int, _ folder: String) -> ChatSummary {
        ChatSummary(chat: chat, folder: base.appendingPathComponent(folder).path, alias: nil, state: .idle,
                    created: "2026-10-29T09:14:00Z", ended: nil)
    }

    /// A model as after a launch: chats 1 and 2 in their own folders, a
    /// later session 7 in chat 1's folder, and a vault every chat shows.
    private func model() -> AppModel {
        let model = AppModel(settings: Settings(defaults: defaults))
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.5", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [],
            roots: [Root(name: "Vault", path: base.appendingPathComponent("vault").path)],
            commands: ["log"], capabilities: ["files", "sessions", "context"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [session(1, "one"), session(2, "two"), session(7, "one")])))
        return model
    }

    func testAFolderOpensAndCloses() {
        let model = model()
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
    }

    /// A folder is open by where it is on disk: another chat's own folder
    /// is another folder, and the vault is the same folder in every chat.
    func testAFolderIsOpenWhereverTheSameFolderIsShown() {
        let model = model()
        model.toggleFolder(chat: 1, root: "chat", path: "docs")
        model.toggleFolder(chat: 1, root: "chat", path: "docs/notes")
        model.toggleFolder(chat: 2, root: "Vault", path: "docs")
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs/notes"))
        XCTAssertFalse(model.isFolderOpen(chat: 2, root: "chat", path: "docs"), "chat 2's own folder is another folder")
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "Vault", path: "docs"), "the vault is the same folder in every chat")
        XCTAssertTrue(model.isFolderOpen(chat: 7, root: "chat", path: "docs"), "a later session in the same folder")
        XCTAssertFalse(model.isFolderOpen(chat: 1, root: "Nowhere", path: "docs"), "a root the chat does not have")
        // Switching chats and back changes nothing.
        model.selected = 2
        model.selected = 1
        XCTAssertTrue(model.isFolderOpen(chat: 1, root: "chat", path: "docs"))
    }

    /// v0.26.5: after a restart (a new model on the same settings) the
    /// folders left open are open, a closed one is closed, and one that is
    /// gone from disk is dropped.
    func testOpenFoldersComeBackAfterARestart() throws {
        let first = model()
        first.toggleFolder(chat: 1, root: "chat", path: "docs")
        first.toggleFolder(chat: 1, root: "chat", path: "docs/notes")
        first.toggleFolder(chat: 1, root: "Vault", path: "docs")
        first.toggleFolder(chat: 2, root: "chat", path: "docs")
        first.toggleFolder(chat: 2, root: "chat", path: "docs")  // closed again
        try FileManager.default.removeItem(at: base.appendingPathComponent("one/docs/notes"))

        let second = model()
        XCTAssertTrue(second.isFolderOpen(chat: 1, root: "chat", path: "docs"))
        XCTAssertTrue(second.isFolderOpen(chat: 2, root: "Vault", path: "docs"))
        XCTAssertFalse(second.isFolderOpen(chat: 2, root: "chat", path: "docs"), "closing is remembered")
        XCTAssertEqual(second.openFolders.count, 2, "the folder that is gone was dropped")
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
