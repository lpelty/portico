import XCTest
@testable import Portico

/// v0.25 §3 (PORT-13): the date and time beside Copy, for agent and person messages.
@MainActor
final class MessageTimeTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = locale
        return c
    }

    private func d(_ text: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    private var now: Date { d("2026-11-08 15:50") }

    private func short(_ text: String) -> String {
        MessageTime.short(d(text), now: now, calendar: calendar, locale: locale)
    }

    func testShortFormats() {
        XCTAssertEqual(short("2026-11-08 15:42"), "3:42 PM")
        XCTAssertEqual(short("2026-11-07 15:42"), "Yesterday 3:42 PM")
        XCTAssertEqual(short("2026-11-06 15:42"), "Nov 6, 3:42 PM")
        XCTAssertEqual(short("2025-11-06 15:42"), "Nov 6, 2025, 3:42 PM")
    }

    func testFullFormat() {
        XCTAssertEqual(
            MessageTime.full(d("2026-11-06 15:42:10"), calendar: calendar, locale: locale),
            "Friday, November 6, 2026 at 3:42:10 PM")
    }

    func testShownTrustsOnlyRealTimes() {
        XCTAssertNil(MessageTime.shown("2026-11-06T21:42:10Z", noTime: nil, fromHistory: true, gatewayTimes: false))
        XCTAssertNil(MessageTime.shown("2026-11-06T21:42:10Z", noTime: true, fromHistory: false, gatewayTimes: true))
        XCTAssertNotNil(MessageTime.shown("2026-11-06T21:42:10Z", noTime: nil, fromHistory: false, gatewayTimes: false))
        XCTAssertNotNil(MessageTime.shown("2026-11-06T21:42:10Z", noTime: nil, fromHistory: true, gatewayTimes: true))
        XCTAssertNil(MessageTime.shown("not a time", noTime: nil, fromHistory: false, gatewayTimes: false))
    }

    // MARK: - the model keeps the times

    private func hello() -> HelloServer {
        HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Front", agentName: "Agent"), actions: [], roots: [], commands: [], capabilities: [])
    }

    func testALiveReplyKeepsTheTimeOfItsFirstDelta() {
        let model = AppModel()
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1, ts: "2026-11-08T21:40:00Z")))
        model.apply(.textDelta(TextDelta(chat: 1, turn: 1, text: "Hel", seq: 2, ts: "2026-11-08T21:42:10Z")))
        model.apply(.textDelta(TextDelta(chat: 1, turn: 1, text: "lo", seq: 3, ts: "2026-11-08T21:42:30Z")))
        guard case .assistantText(_, let text, let at)? = model.transcripts[1]?.last else {
            return XCTFail("expected a reply, got \(String(describing: model.transcripts[1]))")
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(at, "2026-11-08T21:42:10Z")
    }

    func testAReplayedEventHasNoTimeFromAGatewayThatDoesNotSaySo() {
        let model = AppModel()
        model.apply(.hello(hello()))
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .turnStarted(TurnStarted(chat: 1, turn: 1, ts: "2026-11-08T21:40:00Z")),
            .userText(UserText(chat: 1, turn: 1, text: "hi", ts: "2026-11-08T21:40:00Z")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "yo", ts: "2026-11-08T21:40:01Z")),
        ], truncated: false)))
        let items = model.transcripts[1] ?? []
        guard case .userText(let user)? = items.first else { return XCTFail("expected the bubble, got \(items)") }
        XCTAssertEqual(user.noTime, true)
        guard case .assistantText(_, _, let at)? = items.last else { return XCTFail("expected a reply, got \(items)") }
        XCTAssertNil(at)
    }

    func testRingEventsInAHistoryKeepTheirLiveTimes() {
        // A reconnect's replay from the ring: stamped events, live times.
        let model = AppModel()
        model.apply(.hello(hello()))
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1, ts: "2026-11-08T21:40:00Z")),
            .userText(UserText(chat: 1, turn: 1, text: "hi", seq: 2, ts: "2026-11-08T21:40:00Z")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "yo", seq: 3, ts: "2026-11-08T21:40:01Z")),
        ], truncated: false)))
        let items = model.transcripts[1] ?? []
        guard case .userText(let user)? = items.first else { return XCTFail("expected the bubble, got \(items)") }
        XCTAssertNil(user.noTime)
        guard case .assistantText(_, _, let at)? = items.last else { return XCTFail("expected a reply, got \(items)") }
        XCTAssertEqual(at, "2026-11-08T21:40:01Z")
    }

    func testNoTimeDecodes() throws {
        let json = #"{"type":"user.text","chat":1,"turn":1,"text":"hi","ts":"2026-11-08T21:40:00Z","no_time":true}"#
        guard case .userText(let user) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("user.text")
        }
        XCTAssertEqual(user.noTime, true)
        let delta = #"{"type":"text.delta","chat":1,"turn":1,"text":"yo","ts":"2026-11-08T21:40:00Z","no_time":true}"#
        guard case .textDelta(let d) = try JSONDecoder().decode(ServerMessage.self, from: Data(delta.utf8)) else {
            return XCTFail("text.delta")
        }
        XCTAssertEqual(d.noTime, true)
    }
}
