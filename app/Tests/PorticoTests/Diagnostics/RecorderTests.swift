import XCTest

@testable import Portico

@MainActor
final class RecorderTests: XCTestCase {
    private var root: URL!
    private var recordings: URL { root.appendingPathComponent("diagnostics/recordings", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("diagnostics"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let start = Date(timeIntervalSince1970: 1_794_344_700) // fixed instant

    func testEventsRoundTripAsJSONLinesWithTimes() throws {
        let recorder = Recorder(chat: 3, directory: recordings, startedAt: start)
        let events: [RecordingEvent] = [
            .open(chat: 3, appVersion: "0.26.4", macOS: "27.0", window: [1000, 700], column: 640, viewerVisible: true, viewerWidth: 420, sidebarVisible: false, textScale: 1.1),
            .shape(EntryShape(id: "r1", kind: .reply, paragraphs: [10, 20])),
            .viewer(visible: true, width: 400, shown: nil),
            .wheel(deltaY: -3.5, precise: true, phase: 2, momentum: 0),
        ]
        for e in events { recorder.note(e) }
        recorder.close()
        let back = try Recorder.read(recorder.url)
        XCTAssertEqual(back.map(\.event), events)
        XCTAssertEqual(back.map(\.t), back.map(\.t).sorted())
        let first = try String(contentsOf: recorder.url, encoding: .utf8).split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(first.contains("\"kind\":\"open\""))
        XCTAssertTrue(first.contains("\"t\":"))
    }

    func testFileNameIsChatAndFileSafeStartTime() {
        let recorder = Recorder(chat: 3, directory: recordings, startedAt: Date(timeIntervalSince1970: 1_794_344_700))
        defer { recorder.close() }
        XCTAssertEqual(recorder.url.lastPathComponent, "3-2026-11-10T21-05-00.000Z.jsonl")
    }

    func testFileIsCreated0600UnderRecordings() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        recorder.note(.removed(id: "x"))
        recorder.close()
        XCTAssertEqual(recorder.url.deletingLastPathComponent().path, recordings.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: recorder.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: recordings.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCapEndsRecordingWithFinalLine() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start, cap: 2_000)
        for i in 0..<100 { recorder.note(.shape(EntryShape(id: "entry-\(i)", kind: .reply, paragraphs: [100, 200]))) }
        recorder.close()
        let back = try Recorder.read(recorder.url)
        guard case .capped(let bytes) = back.last?.event else { return XCTFail("last line is not capped") }
        XCTAssertGreaterThanOrEqual(bytes, 2_000)
        XCTAssertEqual(back.filter { if case .capped = $0.event { return true } else { return false } }.count, 1)
        let fileSize = try FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, bytes)
        XCTAssertLessThan(back.count, 100)
    }

    func testWriterToleratesDirectoryRemoved() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        recorder.note(.removed(id: "a"))
        recorder.drain()
        try FileManager.default.removeItem(at: root.appendingPathComponent("diagnostics"))
        for i in 0..<100 { recorder.note(.removed(id: "b\(i)")) }
        recorder.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("diagnostics").path))
    }

    func testRecorderCreatesNothingWhenParentIsGone() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("diagnostics"))
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        for i in 0..<10 { recorder.note(.removed(id: "b\(i)")) }
        recorder.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("diagnostics").path))
    }

    func testCloseIsIdempotentAndLaterNotesAreDropped() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        recorder.note(.removed(id: "a"))
        recorder.close()
        recorder.close()
        recorder.note(.removed(id: "late"))
        XCTAssertEqual(try Recorder.read(recorder.url).count, 1)
    }

    func testReadThrowsOnMalformedLineAndUnknownKind() throws {
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let bad = recordings.appendingPathComponent("bad.jsonl")
        try "{\"kind\":\"removed\",\"t\":1,\"id\":\"a\"}\nnot json\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Recorder.read(bad))
        try "{\"kind\":\"mystery\",\"t\":1}\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Recorder.read(bad))
    }

    func testNoteCostsUnderOneMillisecondOnMain() throws {
        XCTAssertTrue(Thread.isMainThread)
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        var worst = 0.0
        let begin = DispatchTime.now().uptimeNanoseconds
        for i in 0..<10_000 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            recorder.note(.wheel(deltaY: Double(i), precise: true, phase: 1, momentum: 0))
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let average = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6 / 10_000
        recorder.close()
        XCTAssertLessThan(average, 1.0)
        XCTAssertLessThan(worst, 5.0)
    }

    func testNoContentFieldsExistInTheEventType() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        let events: [RecordingEvent] = [
            .open(chat: 1, appVersion: "v", macOS: "m", window: [1, 2], column: 3, viewerVisible: true, viewerWidth: 4, sidebarVisible: true, textScale: 1),
            .shape(EntryShape(id: "id-1", kind: .person)), .removed(id: "id-2"), .imageLoaded(id: "id-3", index: 0, height: 9),
            .window(width: 1, height: 2), .column(width: 3), .viewer(visible: true, width: 4, shown: "id-4"), .sidebar(visible: false),
            .textScale(1.2), .wheel(deltaY: 1, precise: false, phase: 0, momentum: 0), .key(.pageUp), .jump(id: "id-5"),
            .phase(.idle), .delta(turn: 1, chars: 5), .turnFinished(turn: 1), .toolRow(id: "id-6"), .card(id: "id-7", docked: true), .capped(bytes: 1),
        ]
        for e in events { recorder.note(e) }
        recorder.close()
        let text = try String(contentsOf: recorder.url, encoding: .utf8)
        var keys = Set<String>()
        for line in text.split(separator: "\n") {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            collect(obj, into: &keys)
        }
        for banned in ["text", "name", "path", "url", "title"] { XCTAssertFalse(keys.contains(banned), banned) }
        var strings = Set<String>()
        for line in text.split(separator: "\n") {
            collectStrings(try JSONSerialization.jsonObject(with: Data(line.utf8)), into: &strings)
        }
        var allowed: Set<String> = ["id-1", "id-2", "id-3", "id-4", "id-5", "id-6", "id-7", "v", "m"]
        allowed.formUnion(["open", "shape", "removed", "imageLoaded", "window", "column", "viewer", "sidebar", "textScale", "wheel", "key", "jump", "phase", "delta", "turnFinished", "toolRow", "card", "capped"])
        allowed.insert("person")  // EntryShape.kind
        allowed.formUnion(["pageUp", "idle"])  // ScrollKey, ScrollPhaseName
        XCTAssertEqual(strings.subtracting(allowed), [])
        XCTAssertEqual(try Recorder.read(recorder.url).count, events.count)
    }

    private func collect(_ value: Any, into keys: inout Set<String>) {
        if let d = value as? [String: Any] { for (k, v) in d { keys.insert(k); collect(v, into: &keys) } }
        if let a = value as? [Any] { for v in a { collect(v, into: &keys) } }
    }

    private func collectStrings(_ value: Any, into out: inout Set<String>) {
        if let s = value as? String { out.insert(s) }
        if let d = value as? [String: Any] { for v in d.values { collectStrings(v, into: &out) } }
        if let a = value as? [Any] { for v in a { collectStrings(v, into: &out) } }
    }

    func testTimerFlushesToDiskWhileOpen() throws {
        let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
        recorder.note(.removed(id: "a"))
        let deadline = Date().addingTimeInterval(1.5)
        var size = 0
        while Date() < deadline && size == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            size = (try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? Int) ?? 0
        }
        XCTAssertGreaterThan(size, 0, "the 250 ms timer should have flushed before close()")
        recorder.close()
        XCTAssertEqual(try Recorder.read(recorder.url).count, 1)
    }

    func testDroppedRecorderFlushesBufferedLines() throws {
        var url: URL?
        do {
            let recorder = Recorder(chat: 1, directory: recordings, startedAt: start)
            recorder.note(.removed(id: "a"))
            recorder.note(.removed(id: "b"))
            url = recorder.url
        }
        let deadline = Date().addingTimeInterval(1)
        var count = 0
        while Date() < deadline && count < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            count = (try? Recorder.read(url!).count) ?? 0
        }
        XCTAssertEqual(count, 2)
    }

    func testTwoRecordersSameChatSameInstantDoNotClobber() throws {
        let a = Recorder(chat: 1, directory: recordings, startedAt: start)
        let b = Recorder(chat: 1, directory: recordings, startedAt: start)
        XCTAssertNotEqual(a.url, b.url)
        a.note(.removed(id: "a")); b.note(.removed(id: "b"))
        a.close(); b.close()
        XCTAssertEqual(try Recorder.read(a.url).map(\.event), [.removed(id: "a")])
        XCTAssertEqual(try Recorder.read(b.url).map(\.event), [.removed(id: "b")])
    }
}
