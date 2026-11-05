import Foundation
import XCTest
@testable import Portico

/// v0.19 §4.1: a deployment can fix "Works in".
@MainActor
final class FolderLockTests: XCTestCase {
    private func dir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portico-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hello(default folder: URL, root: URL, locked: Bool) -> HelloServer {
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [Root(name: "vault", path: root.path)],
            commands: [], capabilities: [])
        hello.defaultFolder = folder.path
        hello.lockFolder = locked
        return hello
    }

    func testALockedFolderIgnoresTheSavedAndChosenFolders() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-lock-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let home = try dir(), root = try dir(), other = try dir()
        _ = model.handleHello(hello(default: home, root: root, locked: true))
        model.settings.lastFolder = other.path
        model.chosenStartFolder = other
        XCTAssertTrue(model.isFolderLocked)
        XCTAssertEqual(model.startFolder?.path, home.path)
    }

    func testLockedWithoutADefaultFolderUsesTheFirstRoot() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-lock-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let root = try dir()
        var hello = hello(default: root, root: root, locked: true)
        hello.defaultFolder = nil
        _ = model.handleHello(hello)
        XCTAssertEqual(model.startFolder?.path, root.path)
    }

    func testChooseStartFolderRefusesWhileLocked() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-lock-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let home = try dir(), other = try dir()
        _ = model.handleHello(hello(default: home, root: home, locked: true))
        model.chooseStartFolder(other)
        XCTAssertNil(model.settings.lastFolder)
        XCTAssertNil(model.chosenStartFolder)
    }

    func testAnUnlockedDeploymentStillChooses() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-lock-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let home = try dir(), other = try dir()
        _ = model.handleHello(hello(default: home, root: home, locked: false))
        model.chooseStartFolder(other)
        XCTAssertEqual(model.startFolder?.path, other.path)
    }

    func testTheLockedNoteNamesTheBrand() {
        XCTAssertEqual(GeneralSettingsPresentation.folderLockedNote(brand: "Acme"), "Set by Acme")
    }
}
