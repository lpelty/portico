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

    func testNoteAfterTheDirectoryVanishesRecreatesNothing() throws {
        try switchOn()
        Diagnostics.refresh()
        try FileManager.default.removeItem(at: Diagnostics.directory)
        ScrollTrace.note("late")  // no refresh: isOn is still cached true
        XCTAssertFalse(FileManager.default.fileExists(atPath: Diagnostics.directory.path))
    }

    func testOffThenOnWithinOnePollReopensTheTrace() throws {
        try switchOn()
        Diagnostics.refresh()
        ScrollTrace.note("before")
        try FileManager.default.removeItem(at: Diagnostics.directory)
        try switchOn()
        Diagnostics.refresh()  // isOn unchanged, but the trace file is gone
        ScrollTrace.note("after")
        let text = try String(contentsOf: Diagnostics.tracePath, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("after\n"))
        XCTAssertFalse(text.contains("before"))
    }

    /// A `recordings/` that cannot be made (a `diagnostics/` the app may not write) is not retried
    /// at every poll: no restart notice, the same recorder, until the switch turns off and on.
    func testARecordingsFolderThatCannotBeMadeIsNotRetriedEveryPoll() throws {
        try switchOn()
        Diagnostics.refresh()
        XCTAssertTrue(Diagnostics.isOn)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: Diagnostics.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Diagnostics.directory.path) }
        let first = try XCTUnwrap(Diagnostics.recorder(for: 3))
        XCTAssertFalse(first.isWriting, "no recordings/ could be made")
        var notices = 0
        let token = NotificationCenter.default.addObserver(forName: Diagnostics.switched, object: nil, queue: nil) { _ in notices += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        for _ in 0..<3 { Diagnostics.refresh() }
        XCTAssertEqual(notices, 0, "no restart at each poll")
        XCTAssertTrue(Diagnostics.recorder(for: 3) === first, "the same recorder")
        // Off and on again: tried afresh.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Diagnostics.directory.path)
        try FileManager.default.removeItem(at: Diagnostics.switchFile)
        Diagnostics.refresh()
        try switchOn()
        Diagnostics.refresh()
        let again = try XCTUnwrap(Diagnostics.recorder(for: 3))
        XCTAssertFalse(again === first)
        XCTAssertTrue(again.isWriting)
        Diagnostics.closeAll()
    }
}
