import Foundation
import XCTest

@testable import Portico

/// v0.11 (item 74): messages typed while the agent works. With a gateway
/// that lists `queue.v1`, Send stays available during a turn; the gateway
/// answers `chat.queued`, the card list follows `chat.queue`, Edit and
/// Cancel send `chat.unqueue`, and a queued message that goes becomes the
/// person's `user.text` in the conversation.
@MainActor
final class QueuedMessagesTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func model(queues: Bool = true) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.11.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: queues ? ["queue.v1"] : [])))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .working, created: "2026-10-30T12:00:00Z"),
        ])))
        return (model, sent)
    }

    func testTheAppListsQueueV1InItsHello() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("queue.v1"))
    }

    func testSendDuringATurnGoesOutAndTheGatewaysListIsTheCards() throws {
        let (model, sent) = model()
        XCTAssertTrue(InputBar.canSend(model, chat: 1, text: "Also check uvx."), "the composer stays usable")
        XCTAssertTrue(InputBar.showsSendWhileBusy(queues: true, text: "Also check uvx."))
        XCTAssertFalse(InputBar.showsSendWhileBusy(queues: true, text: "  "), "nothing typed: Stop alone")

        model.sendMessage(chat: 1, text: "Also check uvx.")
        guard case .messageSend(let send)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(model.draft(for: 1), "")
        XCTAssertTrue(model.isSending(chat: 1))

        model.apply(.chatQueued(ChatQueued(chat: 1, id: send.id)))
        XCTAssertFalse(model.isSending(chat: 1), "queued is an answer: the next can be typed and sent")
        model.apply(.chatQueue(ChatQueue(chat: 1, items: [QueuedMessage(id: try XCTUnwrap(send.id), text: "Also check uvx.")])))
        XCTAssertEqual(model.queuedMessages(chat: 1).map(\.text), ["Also check uvx."])
        XCTAssertEqual(model.queuedLine(chat: 1), "Queued — sends at Acme's next step")

        // It goes: the list empties and the person's words join the turn.
        model.apply(.chatQueue(ChatQueue(chat: 1, items: [])))
        model.apply(.userText(UserText(chat: 1, turn: 1, text: "Also check uvx.", seq: 9)))
        XCTAssertEqual(model.queuedMessages(chat: 1), [])
        XCTAssertEqual(model.transcripts[1]?.compactMap { if case .userText(let u) = $0 { u.text } else { nil } }, ["Also check uvx."])
    }

    func testAnOlderGatewayKeepsStopAlone() {
        let (model, _) = model(queues: false)
        XCTAssertFalse(model.queuesWhileWorking)
        XCTAssertFalse(InputBar.canSend(model, chat: 1, text: "hello"))
        XCTAssertFalse(InputBar.showsSendWhileBusy(queues: false, text: "hello"))
    }

    func testCancelTakesItOffAtOnceAndAsksTheGateway() {
        let (model, sent) = model()
        model.apply(.chatQueue(ChatQueue(chat: 1, items: [
            QueuedMessage(id: "q1", text: "one"), QueuedMessage(id: "q2", text: "two"),
        ])))
        model.cancelQueued(chat: 1, id: "q1")
        XCTAssertEqual(model.queuedMessages(chat: 1).map(\.id), ["q2"])
        guard case .chatUnqueue(let unqueue)? = sent.frames.last else { return XCTFail("expected chat.unqueue") }
        XCTAssertEqual(unqueue.chat, 1)
        XCTAssertEqual(unqueue.id, "q1")
    }

    func testEditPutsTheMessageBackInTheComposerAheadOfWhatWasTypedSince() {
        let (model, sent) = model()
        model.setDraft("and more", for: 1)
        model.apply(.chatQueue(ChatQueue(chat: 1, items: [
            QueuedMessage(id: "q1", text: "check uvx", attachments: ["/tmp/demo/notes.md"]),
        ])))
        model.editQueued(chat: 1, id: "q1")
        XCTAssertEqual(model.queuedMessages(chat: 1), [])
        XCTAssertEqual(model.draft(for: 1), "check uvx\nand more")
        XCTAssertEqual(model.draftAttachments[1], ["/tmp/demo/notes.md"])
        guard case .chatUnqueue(let unqueue)? = sent.frames.last else { return XCTFail("expected chat.unqueue") }
        XCTAssertEqual(unqueue.id, "q1")
    }

    func testARestartedGatewayForgetsTheQueue() {
        let (model, _) = model()
        model.apply(.chatQueue(ChatQueue(chat: 1, items: [QueuedMessage(id: "q1", text: "held")])))
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.11.0", epoch: "another",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: ["queue.v1"])))
        XCTAssertEqual(model.queuedMessages(chat: 1), [])
    }
}
