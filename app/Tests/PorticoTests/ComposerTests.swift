import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// V2's composer and working line, model side: the permission mode chip
/// (`session.mode` out, `chat.state.mode` in), the working line's words and
/// time, and Enter / Shift+Enter.
@MainActor
final class ComposerTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    private func summary(_ chat: Int, mode: PermissionMode? = nil, state: ChatStateWord = .idle) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-28T12:00:00Z", mode: mode)
    }

    // MARK: - mode chip

    func testModeComesFromTheRecordAndChatStateAndTheChipSendsSessionMode() {
        let (model, sent) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        XCTAssertNil(model.mode(of: 1), "an older gateway: no mode, no chip")

        model.apply(.chatList(ChatList(chats: [summary(1, mode: .default)])))
        XCTAssertEqual(model.mode(of: 1), .default)

        model.setMode(.auto, for: 1)
        guard case .sessionMode(let change)? = sent.frames.last else { return XCTFail("expected session.mode") }
        XCTAssertEqual(change.chat, 1)
        XCTAssertEqual(change.mode, .auto)
        XCTAssertEqual(model.mode(of: 1), .default, "the chip follows the gateway's answer, not the click")

        model.apply(.chatState(ChatState(chat: 1, state: .idle, mode: .auto, seq: 2)))
        XCTAssertEqual(model.mode(of: 1), .auto)
        XCTAssertEqual(model.lastKnownMode, .auto)

        // A state without a mode leaves the mode alone; picking the current mode sends nothing.
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 3)))
        XCTAssertEqual(model.mode(of: 1), .auto)
        let count = sent.frames.count
        model.setMode(.auto, for: 1)
        XCTAssertEqual(sent.frames.count, count)
    }

    func testModeWordsAsTheMenuShowsThem() {
        XCTAssertEqual(PermissionModePresentation.all.map { PermissionModePresentation(mode: $0).label }, ["Ask each time", "Edits allowed", "Auto"])
        XCTAssertEqual(PermissionModePresentation.heading(agentName: "Portico"), "WHEN PORTICO WANTS TO ACT")
    }

    func testTheStartScreensPickIsAppliedToTheNewSession() throws {
        let (model, sent) = model()
        XCTAssertEqual(model.startModeShown, .auto, "nothing known: the protocol's default")
        model.startMode = .default
        XCTAssertEqual(model.startModeShown, .default)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.3.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [],
            roots: [Root(name: "work", path: NSTemporaryDirectory())], commands: [], capabilities: [])))
        model.startChat(text: "hello")
        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new") }
        model.apply(.chatList(ChatList(chats: [summary(1, mode: .auto)])))
        model.apply(.chatState(ChatState(chat: 1, state: .idle, mode: .auto, id: new.id, seq: 1)))

        let modes = sent.frames.compactMap { if case .sessionMode(let m) = $0 { m } else { nil } }
        XCTAssertEqual(modes.map(\.mode), [.default])
        XCTAssertEqual(modes.first?.chat, 1)
        XCTAssertNil(model.startMode, "the pick is spent")
    }

    // MARK: - working line

    func testWorkingLineSaysWhatTheTurnIsDoingAndForHowLong() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        XCTAssertFalse(model.showsWorkingLine(chat: 1))

        model.apply(.turnStarted(TurnStarted(chat: 1, turn: 1, seq: 1, ts: "2026-10-28T12:00:00Z")))
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 2)))
        XCTAssertTrue(model.showsWorkingLine(chat: 1))
        XCTAssertEqual(model.activity(for: 1), "Thinking")
        XCTAssertEqual(model.turnStartedAt[1], SessionTime.parse("2026-10-28T12:00:00Z"))

        model.apply(.toolStarted(ToolStarted(chat: 1, turn: 1, toolUseId: "t1", tool: "Write", summary: "/tmp/demo/Q3-synthesis.md", input: [:], seq: 3)))
        XCTAssertEqual(model.activity(for: 1), "Write Q3-synthesis.md")
        model.apply(.toolFinished(ToolFinished(chat: 1, turn: 1, toolUseId: "t1", ok: true, summary: "ok", seq: 4)))
        XCTAssertEqual(model.activity(for: 1), "Thinking")

        // Waiting on the person: the card and the row say so, not the working line.
        model.apply(.chatState(ChatState(chat: 1, state: .waitingOnYou, seq: 5)))
        XCTAssertFalse(model.showsWorkingLine(chat: 1))

        model.apply(.turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done, seq: 6)))
        model.apply(.chatState(ChatState(chat: 1, state: .idle, seq: 7)))
        XCTAssertFalse(model.showsWorkingLine(chat: 1))
        XCTAssertNil(model.turnStartedAt[1])
    }

    func testElapsedText() {
        XCTAssertEqual(AppModel.elapsedText(0), "0:00")
        XCTAssertEqual(AppModel.elapsedText(48), "0:48")
        XCTAssertEqual(AppModel.elapsedText(725), "12:05")
        XCTAssertEqual(AppModel.elapsedText(3729), "1:02:09")
        XCTAssertEqual(AppModel.elapsedText(-3), "0:00")
    }

    // MARK: - Enter and Shift+Enter

    func testEnterSendsAndShiftEnterAddsALine() {
        var sends = 0
        XCTAssertEqual(InputBar.handleReturn(modifiers: [], send: { sends += 1 }), .handled)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(InputBar.handleReturn(modifiers: .shift, send: { sends += 1 }), .ignored)
        XCTAssertEqual(InputBar.handleReturn(modifiers: .option, send: { sends += 1 }), .ignored)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(InputBar.enterHint, "Enter to send · Shift+Enter for a new line")
    }
}
