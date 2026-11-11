import AppKit
import SwiftUI
import XCTest

@testable import Portico

/// D8, D11: a conversation rebuilt from shapes alone lays out like the original.
@MainActor
final class SyntheticConversationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var folder: URL!

    override func setUp() async throws {
        let suite = "portico-synthetic-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("portico-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { [folder] in if let folder { try? FileManager.default.removeItem(at: folder) } }
        ConversationProbe.enabled = true
        addTeardownBlock { ConversationProbe.enabled = false }
    }

    private func shape(_ kind: EntryShape.Kind = .reply, _ configure: (inout EntryShape) -> Void) -> EntryShape {
        var shape = EntryShape(id: "x", kind: kind)
        configure(&shape)
        return shape
    }

    private func roundTrip(_ expected: EntryShape, file: StaticString = #filePath, line: UInt = #line) {
        let text = SyntheticConversation.text(matching: expected)
        let item: TranscriptItem = expected.kind == .person
            ? .userText(UserText(chat: 1, turn: 1, text: text))
            : .assistantText(id: "x", text: text)
        var got = EntryShape.of(.item(item), imageSize: { _ in nil })
        got.id = expected.id
        XCTAssertEqual(got, expected, "\(text)", file: file, line: line)
    }

    func testTextMatchesParagraphAndBlockCounts() {
        roundTrip(shape { $0.paragraphs = [12, 340, 1, 2, 700] })
        roundTrip(shape { $0.headings = [1, 2, 3, 3]; $0.paragraphs = [80, 80] })
        roundTrip(shape { $0.listItems = 7; $0.paragraphs = [50] })
        roundTrip(shape { $0.codeBlocks = [4, 1, 30]; $0.paragraphs = [60] })
        roundTrip(shape { $0.tables = [[3, 4], [1, 2]]; $0.paragraphs = [60] })
        roundTrip(shape { $0.quotes = 2; $0.paragraphs = [30, 200, 90] })
        roundTrip(shape { $0.rules = 3; $0.paragraphs = [30, 40] })
        roundTrip(shape {
            $0.paragraphs = [120, 45, 300, 9]; $0.headings = [2, 3]; $0.listItems = 5
            $0.codeBlocks = [6]; $0.tables = [[2, 3]]; $0.quotes = 1; $0.rules = 1
        })
        roundTrip(shape(.person) { $0.paragraphs = [5, 400, 33] })
        XCTAssertEqual(SyntheticConversation.text(matching: shape { $0.paragraphs = [200] }),
                       SyntheticConversation.text(matching: shape { $0.paragraphs = [200] }), "deterministic")
    }

    func testParagraphLengthIsExactAndWordsAreThreeToNineLetters() {
        for n in [1, 2, 3, 4, 5, 11, 12, 13, 57, 400] {
            let text = SyntheticConversation.text(matching: shape(.person) { $0.paragraphs = [n] })
            XCTAssertEqual(text.count, n)
            for word in text.split(separator: " ") where n >= 3 {
                XCTAssertTrue((3...9).contains(word.count), "\(word)")
            }
        }
    }

    func testSyntheticFromEmptyShapeIsEmpty() throws {
        let built = try SyntheticConversation.events(chat: 3, shapes: [], images: folder)
        XCTAssertEqual(built.events.count, 0)
        XCTAssertTrue(built.ids.isEmpty)
        let model = try SyntheticConversation.model(chat: 3, shapes: [], images: folder, defaults: defaults)
        XCTAssertEqual(model.transcripts[3] ?? [], [])
    }

    // MARK: - hosting

    private struct Selected: View {
        @EnvironmentObject var model: AppModel
        var body: some View {
            if let chat = model.selected { ConversationView(chat: chat).id(chat) }
        }
    }

    private func host(_ model: AppModel, width: CGFloat) throws -> (window: NSWindow, scroll: NSScrollView) {
        let settings = Settings(defaults: defaults)
        let view = NSHostingView(rootView: Selected()
            .environmentObject(model).environmentObject(settings)
            .environmentObject(ReadAloud(settings: settings)).environmentObject(Dictation(settings: settings)))
        let frame = NSRect(x: 0, y: 0, width: width, height: 600)
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        spin()
        return (window, try XCTUnwrap(Self.transcriptScroll(in: view), "the transcript's scroll view"))
    }

    private func spin(_ seconds: Double = 0.4) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func transcriptScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) { return scroll }
        for sub in view.subviews { if let found = transcriptScroll(in: sub) { return found } }
        return nil
    }

    private func scrollTo(_ scroll: NSScrollView, y: CGFloat, settle: Double = 0.3) {
        let clip = scroll.contentView
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, y)))
        scroll.reflectScrolledClipView(clip)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        spin(settle)
    }

    /// Row heights by entry index, gathered while walking the transcript top to bottom
    /// (the lazy stack lays out only the rows near the view).
    private func heights(_ model: AppModel, chat: Int, width: CGFloat, entryIds: [String]) throws -> [Int: CGFloat] {
        let hosted = try host(model, width: width)
        defer { hosted.window.close() }
        var out: [Int: CGFloat] = [:]
        func snapshot() {
            guard let frames = ConversationProbe.rows[chat]?.frames else { return }
            for (index, id) in entryIds.enumerated() { if let frame = frames[id] { out[index] = frame.height } }
        }
        snapshot()
        // Relative steps from wherever the stack leaves the view (its estimates move the
        // document under us), a screen at a time, up to the top.
        for _ in 0..<300 {
            let origin = hosted.scroll.contentView.bounds.origin.y
            if origin <= 0 { break }
            scrollTo(hosted.scroll, y: origin - 400, settle: 0.12)
            snapshot()
        }
        scrollTo(hosted.scroll, y: 0)
        snapshot()
        return out
    }

    private func originalModel(chat: Int) -> AppModel {
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.4", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = chat
        let reply = Array(repeating: "Sam asked Priya about the Acme launch plan and the reply ran long.", count: 6)
            .joined(separator: " ")
        var events: [ServerMessage] = []
        var seq = 0
        for turn in 1...40 {
            seq += 1
            events.append(.userText(UserText(chat: chat, turn: turn, text: "Question \(turn) from Jordan", seq: seq)))
            seq += 1
            let text = turn % 3 == 0 ? Array(repeating: reply, count: 8).joined(separator: "\n\n") : "Done."
            events.append(.textDelta(TextDelta(chat: chat, turn: turn, text: "Answer \(turn). \(text)", seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: chat, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: chat)))
        return model
    }

    /// Hosts `original` and its synthetic rebuild at 740 pt and compares row heights
    /// (rows both hostings laid out). Returns how many were compared and the worst
    /// relative deviation.
    private func compare(_ original: AppModel, chat: Int, expectedRows: Int, label: String) throws -> (rows: Int, worst: Double) {
        let shapes = TranscriptEntry.entries(original.transcripts[chat] ?? []).map {
            EntryShape.of($0, imageSize: { _ in nil })
        }
        XCTAssertEqual(shapes.count, expectedRows)
        let originalHeights = try heights(original, chat: chat, width: 740, entryIds: shapes.map(\.id))
        let built = try SyntheticConversation.events(chat: chat, shapes: shapes, images: folder)
        let synthetic = try SyntheticConversation.model(chat: chat, shapes: shapes, images: folder, defaults: defaults)
        let syntheticEntries = TranscriptEntry.entries(synthetic.transcripts[chat] ?? [])
        XCTAssertEqual(syntheticEntries.count, shapes.count)
        // Paired through the recorded-to-synthetic map, never by raw index.
        let mapped = shapes.map { built.ids[$0.id] ?? nil }
        XCTAssertEqual(mapped.compactMap { $0 }, syntheticEntries.map(\.id), "the map names the model's own entry ids")
        let syntheticHeights = try heights(synthetic, chat: chat, width: 740, entryIds: mapped.map { $0 ?? "" })

        let both = Set(originalHeights.keys).intersection(syntheticHeights.keys).sorted()
        var worst: Double = 0
        for index in both {
            let a = originalHeights[index]!, b = syntheticHeights[index]!
            worst = max(worst, Double(abs(a - b) / a))
            XCTAssertLessThanOrEqual(abs(a - b), max(0.05 * a, 4), "\(label) row \(index) (\(shapes[index].kind)): original \(a) synthetic \(b)")
        }
        print("SYNTHETIC \(label): rows compared \(both.count) of \(shapes.count); worst deviation \(String(format: "%.2f", worst * 100)) %")
        return (both.count, worst)
    }

    func testSyntheticRowsLayOutWithinFivePercentOfTheOriginals() throws {
        let result = try compare(originalModel(chat: 3), chat: 3, expectedRows: 80, label: "varied")
        XCTAssertGreaterThan(result.rows, 60, "rows laid out in both hostings")
    }

    /// Every block kind in one reply, in a different order each turn: the shapes keep no
    /// order and no list or heading lengths, so this is where the bound could slip.
    func testSyntheticRowsOfRichRepliesStayWithinTheBound() throws {
        let chat = 4
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.4", epoch: "e",
            brand: Brand(name: "Acme", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: chat, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z")])))
        model.selected = chat
        let prose = "Sam asked Priya about the Acme launch plan and the reply ran long, then the numbers came back"
        let blocks = [
            "# The plan\n\n\(prose) and \(prose).",
            "- first item about the launch\n- second item that runs a little longer than the first one does\n- third",
            "```swift\nlet launch = Plan()\nlaunch.run()\nlaunch.report()\n```",
            "| Name | Owner | Status |\n|---|---|---|\n| Launch | Priya | Open |\n| Review | Sam | Done |",
            "> \(prose).",
            "---",
            "\(prose).\n\n\(prose) \(prose).",
            "## Next steps\n\nShort one.",
        ]
        var events: [ServerMessage] = []
        var seq = 0
        for turn in 1...24 {
            seq += 1
            events.append(.userText(UserText(chat: chat, turn: turn, text: "Question \(turn)\n\nwith a second paragraph of the question", seq: seq)))
            seq += 1
            let picked = (0..<(2 + turn % 5)).map { blocks[($0 * 3 + turn) % blocks.count] }
            events.append(.textDelta(TextDelta(chat: chat, turn: turn, text: picked.joined(separator: "\n\n"), seq: seq)))
        }
        model.apply(.chatHistory(ChatHistory(chat: chat, events: events, truncated: false)))
        model.apply(.chatLive(ChatLive(chat: chat)))
        let result = try compare(model, chat: chat, expectedRows: 48, label: "rich")
        XCTAssertGreaterThan(result.rows, 20)
    }

    func testToolRowsAndRunsRoundTripThroughTheModel() throws {
        let shapes = [
            shape(.person) { $0.id = "p1"; $0.paragraphs = [30] },
            EntryShape(id: "t1", kind: .tool, toolRows: 1, folded: true),
            shape { $0.id = "r1"; $0.paragraphs = [80] },
            EntryShape(id: "run3", kind: .toolRun, toolRows: 4, folded: true),
            EntryShape(id: "t3", kind: .tool, toolRows: 1, folded: true),
            EntryShape(id: "run2", kind: .toolRun, toolRows: 2, folded: true),
            shape { $0.id = "r2"; $0.paragraphs = [40] },
            EntryShape(id: "t2", kind: .tool, toolRows: 1, folded: true),
            EntryShape(id: "n1", kind: .notice),
            shape(.person) { $0.id = "p2"; $0.paragraphs = [10] },
        ]
        let built = try SyntheticConversation.events(chat: 3, shapes: shapes, images: folder)
        let model = try SyntheticConversation.model(chat: 3, shapes: shapes, images: folder, defaults: defaults)
        let entries = TranscriptEntry.entries(model.transcripts[3] ?? [])
        let back = entries.map { EntryShape.of($0, imageSize: { _ in nil }) }
        let recorded = shapes.filter { $0.kind != .notice }
        XCTAssertEqual(back.count, recorded.count, "one entry for each recorded entry but the skipped kind")
        XCTAssertEqual(back.map(\.kind), recorded.map(\.kind))
        XCTAssertEqual(back.map(\.toolRows), recorded.map(\.toolRows))
        XCTAssertEqual(built.ids["n1"] ?? "x", nil, "a skipped kind maps to nil")
        XCTAssertEqual(shapes.compactMap { built.ids[$0.id] ?? nil }, entries.map(\.id))
    }

    // MARK: - images

    private func personHeight(image: [Int]) throws -> CGFloat {
        let shapes = [shape(.person) { $0.paragraphs = [20]; $0.images = [image] }]
        let model = try SyntheticConversation.model(chat: 3, shapes: shapes, images: folder, defaults: defaults)
        let hosted = try host(model, width: 740)
        defer { hosted.window.close() }
        spin(0.8)
        let entry = try XCTUnwrap(TranscriptEntry.entries(model.transcripts[3] ?? []).first)
        return try XCTUnwrap(ConversationProbe.rows[3]?.frames[entry.id]).height
    }

    func testImagesAreGeneratedAtTheRecordedSizeAndLoadThroughTheRealPath() throws {
        let shapes = [shape(.person) { $0.paragraphs = [20]; $0.images = [[640, 480], [0, 0]]; $0.documents = 1 }]
        let events = try SyntheticConversation.events(chat: 3, shapes: shapes, images: folder).events
        guard case .userText(let user)? = events.first else { return XCTFail("no person message") }
        let split = Attachment.split(try XCTUnwrap(user.attachments))
        XCTAssertEqual(split.images.count, 2)
        XCTAssertEqual(split.files.count, 1)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: split.images[0]))))
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [640, 480])
        let tiny = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: split.images[1]))))
        XCTAssertEqual([tiny.pixelsWide, tiny.pixelsHigh], [1, 1])
        guard case .image(let loaded) = AttachmentImageCache.shared.load(path: split.images[0]) else {
            return XCTFail("the real loader did not read it")
        }
        XCTAssertEqual(loaded.size.width, 640)

        // Hosted: the placeholder (90 pt) is swapped for the thumbnail, 120 pt for a tall image.
        let tall = try personHeight(image: [640, 480])
        let exactlyMax = try personHeight(image: [300, 120])
        let short = try personHeight(image: [200, 50])
        XCTAssertEqual(tall, exactlyMax, accuracy: 1)
        XCTAssertEqual(tall - short, 70, accuracy: 1)
    }
}
