import XCTest

@testable import Portico

/// v0.26.4: the diagnostics switch file, the directory under the app's home,
/// and the scroll trace living under it.
@MainActor
final class DiagnosticsSwitchTests: XCTestCase {
    private var tmp: URL!
    private var savedHome: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portico-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedHome = Diagnostics.home
        Diagnostics.home = tmp
        Diagnostics.onChange = []
        ScrollTrace.override = nil
        ScrollTrace.sink = nil
        Diagnostics.refresh()
    }

    override func tearDown() async throws {
        Diagnostics.stop()
        ScrollTrace.closeHandle()
        Diagnostics.onChange = []
        Diagnostics.home = savedHome
        Diagnostics.refresh()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func switchOn() throws {
        try FileManager.default.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Diagnostics.switchFile.path, contents: nil)
    }

    func testOffCreatesAndReadsNothingUnderDiagnostics() throws {
        Diagnostics.refresh()
        XCTAssertFalse(Diagnostics.isOn)
        ScrollTrace.note("x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Diagnostics.directory.path))
    }

    func testSwitchFileTurnsItOnAndTraceGoesUnderTheDirectory() throws {
        try switchOn()
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)
        ScrollTrace.note("hello")
        XCTAssertTrue(try String(contentsOf: Diagnostics.tracePath, encoding: .utf8).hasSuffix("hello\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("scroll-trace.log").path))
    }

    func testTraceFileModeIs0600() throws {
        try switchOn()
        Diagnostics.refresh()
        ScrollTrace.note("mode")
        let mode = try FileManager.default.attributesOfItem(atPath: Diagnostics.tracePath.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testPollNoticesTheSwitchWithinTheInterval() async throws {
        var seen: [Bool] = []
        Diagnostics.onChange = [{ seen.append($0) }]
        Diagnostics.start(pollEvery: 0.05)
        Diagnostics.start(pollEvery: 0.05)  // twice must not run two loops
        try switchOn()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(Diagnostics.isOn)
        try FileManager.default.removeItem(at: Diagnostics.directory)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(Diagnostics.isOn)
        XCTAssertEqual(seen, [true, false])
    }

    func testSwitchingOffClosesTheTraceAndDoesNotRecreateTheDirectory() throws {
        try switchOn()
        Diagnostics.refresh()
        ScrollTrace.note("one")
        XCTAssertTrue(ScrollTrace.isOpen)
        try FileManager.default.removeItem(at: Diagnostics.directory)
        Diagnostics.refresh()
        XCTAssertFalse(Diagnostics.isOn)
        XCTAssertFalse(ScrollTrace.isOpen)
        ScrollTrace.note("two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Diagnostics.directory.path))
    }
}
