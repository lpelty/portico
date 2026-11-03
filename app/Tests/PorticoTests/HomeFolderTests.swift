import Foundation
import XCTest
@testable import Portico

/// v0.17 §5: the folder `bin/install --home` writes into Info.plist comes
/// first, then `PORTICO_HOME`, then `~/.portico`; the gateway the app starts
/// gets it with `--state`, and a written folder that is missing is never
/// quietly created.
final class HomeFolderTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portico-home-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInfoPlistFolderComesBeforePorticoHome() {
        let home = GatewaySupervisor.resolveHome(
            environment: ["PORTICO_HOME": "/tmp/from-env"],
            infoDictionary: ["PorticoHome": "/opt/acme/app"])
        XCTAssertEqual(home.url.path, "/opt/acme/app")
        XCTAssertEqual(home.source, .infoPlist)
    }

    func testPorticoHomeWithoutTheInfoPlistKey() {
        let home = GatewaySupervisor.resolveHome(
            environment: ["PORTICO_HOME": "/tmp/from-env"], infoDictionary: ["PorticoGatewayBin": "/x"])
        XCTAssertEqual(home.url.path, "/tmp/from-env")
        XCTAssertEqual(home.source, .environment)
    }

    func testNeitherIsTheStandardFolder() {
        let home = GatewaySupervisor.resolveHome(environment: ["PORTICO_HOME": ""], infoDictionary: ["PorticoHome": ""])
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".portico", isDirectory: true)
        XCTAssertEqual(home.url.standardizedFileURL.path, standard.standardizedFileURL.path)
        XCTAssertEqual(home.source, .standard)
        XCTAssertEqual(GatewaySupervisor.resolveHome(environment: [:], infoDictionary: nil).source, .standard)
    }

    @MainActor
    func testAMissingInfoPlistFolderIsNotCreated() async throws {
        let dir = try tempDir()
        let missing = dir.appendingPathComponent("acme-root/app", isDirectory: true)
        let script = dir.appendingPathComponent("fake-gateway")
        try "#!/bin/sh\necho \"PORTICO_READY port=45678\"\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let supervisor = GatewaySupervisor(
            home: GatewaySupervisor.Home(url: missing, source: .infoPlist), gatewayCommand: script)
        addTeardownBlock { @MainActor in supervisor.killForTests() }
        do {
            _ = try await supervisor.start()
            XCTFail("a missing Info.plist folder must stop the start")
        } catch let error as GatewaySupervisor.SupervisorError {
            guard case .homeMissing(let path) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(path, missing.path)
        }
        XCTAssertEqual(supervisor.status, .failed("Portico's folder \(missing.path) is missing; reinstall"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(supervisor.pid, "nothing was started")
    }

    @MainActor
    func testAMissingEnvironmentFolderIsCreatedAsToday() async throws {
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("from-env", isDirectory: true)
        let script = dir.appendingPathComponent("fake-gateway")
        try "#!/bin/sh\necho \"PORTICO_READY port=45679\"\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let supervisor = GatewaySupervisor(
            home: GatewaySupervisor.Home(url: folder, source: .environment), gatewayCommand: script)
        addTeardownBlock { @MainActor in supervisor.killForTests() }
        _ = try? await supervisor.start()  // no token file: the start fails after the folder is made
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testTheGatewayStartsWithTheFolder() {
        let folder = URL(fileURLWithPath: "/opt/acme/app", isDirectory: true)
        XCTAssertEqual(
            GatewaySupervisor.launchArguments(state: folder), ["run", "--port", "0", "--state", "/opt/acme/app"])
    }

    @MainActor
    func testTheStartedGatewayIsGivenTheFolder() async throws {
        let dir = try tempDir()
        let args = dir.appendingPathComponent("args.txt")
        try "fresh-token\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("fake-gateway")
        try "#!/bin/sh\necho \"$@\" > \"\(args.path)\"\necho \"PORTICO_READY port=45680\"\nsleep 30\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let supervisor = GatewaySupervisor(stateDir: dir, gatewayCommand: script)
        addTeardownBlock { @MainActor in supervisor.killForTests() }
        _ = try await supervisor.start()
        let written = try String(contentsOf: args, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(written, "run --port 0 --state \(dir.path)")
    }

    // MARK: - fix round 1: what the gateway and the doctor are told

    @MainActor
    func testTheStartedGatewayHasTheFolderInItsEnvironment() async throws {
        let dir = try tempDir()
        let seen = dir.appendingPathComponent("env.txt")
        try "fresh-token\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("fake-gateway")
        try "#!/bin/sh\necho \"$PORTICO_HOME|$PORTICO_HOME_SOURCE\" > \"\(seen.path)\"\necho \"PORTICO_READY port=45681\"\nsleep 30\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let supervisor = GatewaySupervisor(
            home: GatewaySupervisor.Home(url: dir, source: .infoPlist), gatewayCommand: script)
        addTeardownBlock { @MainActor in supervisor.killForTests() }
        _ = try await supervisor.start()
        let written = try String(contentsOf: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(written, "\(dir.path)|Info.plist")
    }

    @MainActor
    func testTheDoctorIsToldWhereTheFolderCameFrom() async throws {
        let dir = try tempDir()
        let script = dir.appendingPathComponent("fake-gateway")
        try "#!/bin/sh\necho \"$1 $PORTICO_HOME|$PORTICO_HOME_SOURCE\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let baked = GatewaySupervisor(home: GatewaySupervisor.Home(url: dir, source: .infoPlist), gatewayCommand: script)
        let bakedLines = await baked.runDoctor()
        XCTAssertTrue(bakedLines.contains("doctor \(dir.path)|Info.plist"), "\(bakedLines)")

        let standard = GatewaySupervisor(home: GatewaySupervisor.Home(url: dir, source: .standard), gatewayCommand: script)
        let standardLines = await standard.runDoctor()
        XCTAssertTrue(standardLines.contains("doctor \(dir.path)|the default"), "\(standardLines)")
    }

    func testChildEnvironmentNamesEachSource() {
        let url = URL(fileURLWithPath: "/opt/acme/app", isDirectory: true)
        let base = ["PATH": "/usr/bin", "PORTICO_HOME": "/elsewhere"]
        let sources: [(GatewaySupervisor.Home.Source, String)] = [
            (.infoPlist, "Info.plist"), (.environment, "PORTICO_HOME"), (.standard, "the default"),
        ]
        for (source, word) in sources {
            let env = GatewaySupervisor.childEnvironment(home: .init(url: url, source: source), base: base)
            XCTAssertEqual(env["PORTICO_HOME"], "/opt/acme/app")
            XCTAssertEqual(env["PORTICO_HOME_SOURCE"], word)
            XCTAssertEqual(env["PATH"], "/usr/bin")
        }
    }
}
