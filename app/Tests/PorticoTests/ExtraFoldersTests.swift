import Foundation
import XCTest
@testable import Portico

/// v0.19 §4.2: folders a person adds to the Files pane (`files.extra.v1`).
@MainActor
final class ExtraFoldersTests: XCTestCase {
    private final class Sent { var frames: [ClientMessage] = [] }

    private func make(capable: Bool) throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-extra-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        _ = model.handleHello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [],
            roots: [Root(name: "vault", path: "/tmp/vault")], commands: [],
            capabilities: capable ? [FilesRootsSet.capability] : []))
        return (model, sent)
    }

    private func paths(_ frame: ClientMessage?) -> [String]? {
        guard case .filesRootsSet(let set)? = frame else { return nil }
        return set.paths
    }

    func testAddingAFolderStoresItAndSendsTheList() throws {
        let (model, sent) = try make(capable: true)
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/design-refs"))
        XCTAssertEqual(model.settings.extraFolders, ["/tmp/design-refs"])
        XCTAssertEqual(paths(sent.frames.last), ["/tmp/design-refs"])
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/design-refs"))
        XCTAssertEqual(sent.frames.count, 1, "the same folder twice is one")
    }

    func testRemovingOneSendsTheShorterList() throws {
        let (model, sent) = try make(capable: true)
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/a"))
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/b"))
        model.removeExtraFolder("/tmp/a")
        XCTAssertEqual(model.settings.extraFolders, ["/tmp/b"])
        XCTAssertEqual(paths(sent.frames.last), ["/tmp/b"])
    }

    func testTheListIsSentAgainOnConnect() throws {
        let (model, _) = try make(capable: true)
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/a"))
        let frames = model.handleHello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.1.0", epoch: "e2",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [], commands: [],
            capabilities: [FilesRootsSet.capability]))
        XCTAssertEqual(frames.compactMap { paths($0) }, [["/tmp/a"]])
    }

    func testTheGatewaysExtraRootsJoinTheFilesPaneAfterTheDeploymentsOwn() throws {
        let (model, _) = try make(capable: true)
        model.apply(.filesRoots(FilesRoots(roots: [
            Root(name: "vault", path: "/tmp/vault"),
            Root(name: "design-refs", path: "/tmp/design-refs", extra: true),
        ])))
        XCTAssertEqual(model.fileRoots(for: 1).map(\.name), ["vault", "design-refs"])
        XCTAssertEqual(model.rootPath(root: "design-refs", chat: 1), "/tmp/design-refs")
    }

    func testARootMarkedMissingShowsNotFound() throws {
        let (model, _) = try make(capable: true)
        model.settings.extraFolders = ["/tmp/portico-surely-not-here-\(UUID().uuidString)"]
        XCTAssertEqual(model.extraFolderRows.map(\.missing), [true])
        let path = model.settings.extraFolders[0]
        model.apply(.filesRoots(FilesRoots(roots: [Root(name: "gone", path: path, extra: true, missing: true)])))
        XCTAssertEqual(model.extraFolderRows, [ExtraFolderRow(path: path, missing: true)])
        XCTAssertEqual(GeneralSettingsPresentation.extraFolderMissing, "Not found")
    }

    func testWithoutTheCapabilityTheNoteSaysSoAndNothingIsSent() throws {
        let (model, sent) = try make(capable: false)
        XCTAssertEqual(model.extraFoldersNote, "Needs a newer gateway")
        model.addExtraFolder(URL(fileURLWithPath: "/tmp/a"))
        model.removeExtraFolder("/tmp/a")
        XCTAssertTrue(sent.frames.isEmpty)
        XCTAssertTrue(model.settings.extraFolders.isEmpty)
    }

    func testTheNoteNamesTheBrandOtherwise() throws {
        let (model, _) = try make(capable: true)
        XCTAssertTrue(model.extraFoldersNote.contains("after Acme's own"))
    }
}
