import Foundation
import XCTest

@testable import Portico

/// V4, first launch: no sidebar until the first message of Session 1, the
/// title `Session 1`, and the quiet line saying where the agent works (the
/// folder is chosen once and changed in Settings). Model-only.
@MainActor
final class FirstLaunchTests: XCTestCase {

    private func model() throws -> AppModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v03-first-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        return model
    }

    private func hello(_ presentation: String?, roots: [Root] = []) -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.3.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: roots, commands: [],
            capabilities: ["sessions"], presentation: presentation)
    }

    private func session(_ chat: Int) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-28T12:00:00Z")
    }

    func testNoSidebarUntilTheFirstSessionExists() throws {
        let model = try model()
        XCTAssertFalse(model.sidebarShown, "nothing known yet: no sidebar")
        model.apply(.hello(hello("single")))
        model.apply(.chatList(ChatList(chats: [])))
        XCTAssertTrue(model.awaitingFirstSession)
        XCTAssertFalse(model.sidebarShown)
        XCTAssertEqual(model.startTitle, "Session 1")

        model.apply(.chatList(ChatList(chats: [session(1)])))
        XCTAssertFalse(model.awaitingFirstSession)
        XCTAssertTrue(model.sidebarShown, "the first session brings the sidebar")
        model.sidebarVisible = false
        XCTAssertFalse(model.sidebarShown, "and the person can still hide it")
    }

    func testMultiplePresentationKeepsItsSidebarAndTitle() throws {
        let model = try model()
        model.apply(.hello(hello("multiple")))
        model.apply(.chatList(ChatList(chats: [])))
        XCTAssertTrue(model.sidebarShown, "the chat list is the way to start one")
        XCTAssertEqual(model.startTitle, "New chat")
    }

    func testTheFolderLineNamesTheFolderAndSettingsChangesIt() throws {
        let model = try model()
        XCTAssertEqual(model.workingFolderLine, "No folder yet · choose one in Settings")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Research vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        model.apply(.hello(hello("single", roots: [Root(name: "vault", path: root.path)])))
        XCTAssertEqual(model.workingFolderLine, "Working in \(root.lastPathComponent) · chosen at setup, change it in Settings")

        let other = FileManager.default.temporaryDirectory.appendingPathComponent("Design-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        model.chooseStartFolder(other)
        XCTAssertEqual(model.startFolder?.path, other.path)
        XCTAssertTrue(model.workingFolderLine.hasPrefix("Working in \(other.lastPathComponent)"))
    }
}
