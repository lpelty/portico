import XCTest
@testable import Portico

/// Spec §6: the welcome when sessions ran outside the app.
@MainActor
final class PassedByTests: XCTestCase {
    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    private func make(next: Int?, extra: [ChatSummary] = []) throws -> (AppModel, Sent) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "passedby-\(UUID().uuidString)"))
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.6.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["log"], capabilities: ["files", "sessions", "context"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [session(152)] + extra, nextChat: next)))
        return (model, sent)
    }

    private func session(_ chat: Int, ended: String? = nil) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: ended == nil ? .idle : .stopped,
                    created: "2026-10-29T09:14:00Z", ended: ended, unlogged: true, lastReply: nil)
    }

    private func thread(_ chat: Int) -> ChatSummary {
        var summary = session(chat)
        summary.thread = ThreadInfo(label: "t", slot: 1, parent: 152, brief: "b", openedAt: "2026-10-29T09:14:00Z")
        return summary
    }

    func testPassedByWhenTheNextNumberIsPastTheNextOne() throws {
        let (model, _) = try make(next: 159)
        XCTAssertEqual(model.mainScreen, .passedBy(live: 152, next: 159))
        XCTAssertEqual(model.startTitle, "Session 159")
    }

    func testContinuingWhenNothingRanOutside() throws {
        XCTAssertEqual(try make(next: 153).0.mainScreen, .continuing(152))
        XCTAssertEqual(try make(next: nil).0.mainScreen, .continuing(152))
    }

    func testTheLines() throws {
        XCTAssertEqual(SessionsPresentation.passedByLine(live: 152, outside: Array(153...158)),
                       "Sessions 153\u{2013}158 ran outside the app. Session 152 is in History.")
        XCTAssertEqual(SessionsPresentation.passedByLine(live: 152, outside: [153]),
                       "Session 153 ran outside the app. Session 152 is in History.")
        XCTAssertEqual(SessionsPresentation.passedByPlaceholder(next: 159), "Start Session 159 \u{2014} what's first?")
        let (only, _) = try make(next: 154)
        XCTAssertEqual(only.passedByNumbers, [153])
    }

    func testThreadsSharingTheCounterAreNotPassedBy() throws {
        let (model, _) = try make(next: 155, extra: [thread(153), thread(154)])
        XCTAssertEqual(model.mainScreen, .continuing(152))
        let (other, _) = try make(next: 159, extra: [thread(153)])
        XCTAssertEqual(other.mainScreen, .passedBy(live: 152, next: 159))
        XCTAssertEqual(other.passedByNumbers, Array(154...158))
    }

    func testADropBeforeRenewedRestoresTheDraft() throws {
        let (model, _) = try make(next: 159)
        model.startPassedBy(text: "hello")
        XCTAssertEqual(model.passedByTexts.count, 1)
        model.startDraft = "more"
        model.setConnection(.disconnected)
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.6.0", epoch: "e2",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["log"], capabilities: ["files", "sessions", "context"], presentation: "single", canLog: true)))
        XCTAssertEqual(model.startDraft, "hello\nmore")
        XCTAssertTrue(model.passedByTexts.isEmpty)
    }

    func testSendingStartsTheNextSessionWithoutLoggingOrAsking() throws {
        let (model, sent) = try make(next: 159)
        model.startPassedBy(text: "hello")
        XCTAssertNil(model.askingToLog, "no log dialog")
        guard case .sessionRenew(let renew)? = sent.frames.last else { return XCTFail("expected session.renew") }
        XCTAssertEqual(renew.chat, 152)
        XCTAssertFalse(renew.log, "the way New does with Start without logging")
        model.apply(.sessionRenewed(SessionRenewed(
            ended: session(152, ended: "2026-11-04T10:00:00Z"), next: session(159), id: renew.id)))
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send, got \(sent.types())") }
        XCTAssertEqual(message.chat, 159)
        XCTAssertEqual(message.text, "hello")
        XCTAssertTrue(model.passedByTexts.isEmpty, "delivered and cleared")
    }
}
