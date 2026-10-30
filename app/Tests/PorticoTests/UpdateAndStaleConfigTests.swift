import Foundation
import XCTest

@testable import Portico

/// v0.3: the stale-config warning and restart, the update offer, the
/// updater's command runner and relaunch arguments, and the gateway
/// command from the `.app`'s Info.plist. No window, no real gateway.
@MainActor
final class UpdateAndStaleConfigTests: XCTestCase {

    private func model() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        return model
    }

    private func hello(configStale: Bool? = nil, canUpdate: Bool? = nil, epoch: String = "e") -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.3.0", epoch: epoch,
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: [],
            capabilities: [], configStale: configStale, canUpdate: canUpdate)
    }

    // MARK: - stale config

    func testStaleConfigFromHelloOrConfigStaleAndClearedByAFreshGateway() {
        let model = model()
        model.apply(.hello(hello()))
        XCTAssertFalse(model.configStale)
        model.apply(.configStale(ConfigStale()))
        XCTAssertTrue(model.configStale)
        model.apply(.hello(hello(configStale: false, epoch: "f")))
        XCTAssertFalse(model.configStale, "the restarted gateway read the config")
        model.apply(.hello(hello(configStale: true, epoch: "g")))
        XCTAssertTrue(model.configStale, "hello carries the same fact on connect")
        // v0.11 (63): the notice names its cause, and reads nothing like the update offer.
        XCTAssertEqual(StatusStripPresentation.restartText, "Settings changed — restart the gateway to use them")
        XCTAssertFalse(StatusStripPresentation.restartText.contains("Update"))
        XCTAssertNotEqual(StatusStripPresentation.Measure.restartIcon.name, StatusStripPresentation.Measure.updateIcon.name)
    }

    // MARK: - update offer

    func testUpdateIsOfferedOnlyWhenTheDeploymentCanRunIt() {
        let model = model()
        model.apply(.hello(hello(canUpdate: false)))
        model.apply(.updateAvailable(UpdateAvailable(version: "0.3.1")))
        XCTAssertEqual(model.updateVersion, "0.3.1")
        XCTAssertNil(model.offeredUpdate, "no update command: nothing to click")
        model.apply(.hello(hello(canUpdate: true)))
        XCTAssertEqual(model.offeredUpdate, "0.3.1")
        XCTAssertEqual(StatusStripPresentation.updateText("0.3.1"), "Update available (0.3.1)")
    }

    // MARK: - updater mode

    func testUpdaterLaunchAndRelaunchArguments() {
        XCTAssertTrue(Updater.isUpdaterLaunch(["/Applications/Portico.app/Contents/MacOS/Portico", "--update"]))
        XCTAssertFalse(Updater.isUpdaterLaunch(["/x/Portico"]))
        XCTAssertFalse(Updater.isUpdaterLaunch(["--update"]), "the program's own name does not count")
        XCTAssertEqual(
            Updater.relaunchArguments(["/x/Portico", "-psn_0_123", "--verbose"], updating: true, pid: 4321),
            ["--verbose", "--update", "--wait-pid", "4321"])
        XCTAssertEqual(Updater.relaunchArguments(["/x/Portico", "--update", "--wait-pid", "4321", "--verbose"], updating: false), ["--verbose"])
        XCTAssertEqual(Updater.waitPid(["/x/Portico", "--update", "--wait-pid", "4321"]), 4321)
        XCTAssertNil(Updater.waitPid(["/x/Portico", "--update"]))
        XCTAssertNil(Updater.waitPid(["/x/Portico", "--wait-pid"]))
        XCTAssertEqual(Updater.brandName(info: ["CFBundleName": "Acme Agent"]), "Acme Agent")
        XCTAssertEqual(Updater.brandName(info: ["CFBundleDisplayName": "Acme", "CFBundleName": "acme"]), "Acme")
        XCTAssertEqual(Updater.brandName(info: [:]), "Portico")
    }

    func testRunnerStreamsOutputAndReportsSuccess() async throws {
        let script = try script("echo stopping the gateway\necho pulling 0.3.1 >&2\nprintf 'no newline at the end'\nexit 0\n")
        let runner = UpdateRunner(resolve: { script }, arguments: ["update"], environment: ["PATH": "/usr/bin:/bin"])
        let state = await runner.run()
        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(Array(runner.lines.dropFirst()), ["stopping the gateway", "pulling 0.3.1", "no newline at the end"])
        XCTAssertTrue(runner.lines.first?.hasSuffix(" update") == true, "the command line is shown first")
    }

    func testRunnerWaitsForTheOldAppToExitBeforeUpdating() async throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["0.6"]
        try old.run()
        let pid = old.processIdentifier
        let script = try script("kill -0 \(pid) 2>/dev/null && echo old app alive || echo old app gone\n")
        let runner = UpdateRunner(resolve: { script }, environment: ["PATH": "/usr/bin:/bin"], waitFor: pid)
        let state = await runner.run()
        XCTAssertEqual(state, .succeeded)
        XCTAssertEqual(runner.lines.first, "Waiting for the app to quit…")
        XCTAssertEqual(runner.lines.last, "old app gone")
    }

    func testRunnerDoesNotUpdateWhileTheOldAppWillNotQuit() async throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["30"]
        try old.run()
        defer { old.terminate() }
        let script = try script("echo should not run\n")
        let runner = UpdateRunner(resolve: { script }, environment: ["PATH": "/usr/bin:/bin"], waitFor: old.processIdentifier, waitSeconds: 0.3)
        let state = await runner.run()
        guard case .couldNotStart = state else { return XCTFail("expected couldNotStart, got \(state)") }
        XCTAssertFalse(runner.lines.contains("should not run"))
    }

    func testRunnerKeepsTheLogOnFailure() async throws {
        let script = try script("echo something broke\nexit 3\n")
        let runner = UpdateRunner(resolve: { script }, environment: ["PATH": "/usr/bin:/bin"])
        let state = await runner.run()
        XCTAssertEqual(state, .failed(3))
        XCTAssertTrue(runner.lines.contains("something broke"))
        XCTAssertEqual(runner.lines.last, "The update exited with code 3.")
    }

    func testRunnerWithNoCommandSaysSo() async {
        let runner = UpdateRunner(resolve: { throw GatewaySupervisor.SupervisorError.commandNotFound(["/nowhere/portico-gateway"]) })
        let state = await runner.run()
        guard case .couldNotStart(let why) = state else { return XCTFail("expected couldNotStart, got \(state)") }
        XCTAssertTrue(why.contains("/nowhere/portico-gateway"))
    }

    // MARK: - the gateway command from the .app

    func testInfoPlistGatewayBinComesRightAfterTheEnvironmentVariable() {
        let both = GatewaySupervisor.candidateCommands(
            environment: ["PORTICO_GATEWAY_BIN": "/env/portico-gateway"],
            infoDictionary: ["PorticoGatewayBin": "/Users/x/portico/bin/portico-gateway"])
        XCTAssertEqual(Array(both.prefix(2)).map(\.path), ["/env/portico-gateway", "/Users/x/portico/bin/portico-gateway"])

        let plistOnly = GatewaySupervisor.candidateCommands(
            environment: [:], infoDictionary: ["PorticoGatewayBin": "/Users/x/portico/bin/portico-gateway"])
        XCTAssertEqual(plistOnly.first?.path, "/Users/x/portico/bin/portico-gateway")

        let none = GatewaySupervisor.candidateCommands(environment: [:], infoDictionary: ["PorticoGatewayBin": ""])
        XCTAssertFalse(none.contains { $0.path.isEmpty || $0.path == "/" })
    }

    // MARK: - helpers

    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("portico-gateway")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
