import Foundation
import XCTest

@testable import Portico

/// What the conversation pane and input bar lean on in the model and in
/// their view-free helpers: sending text (with attachments), stopping a
/// turn, the draft attachments the Files pane and drag-and-drop feed, and
/// how a tool row presents a call. No window.
@MainActor
final class ConversationTests: XCTestCase {

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        return (model, sent)
    }

    final class Sent {
        var frames: [ClientMessage] = []
    }

    private func summary(_ chat: Int, state: ChatStateWord = .idle) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-27T12:00:00Z")
    }

    // MARK: - send and stop

    func testSendMessageEmitsMessageSendWithAttachmentsAndClearsDraft() {
        let (model, sent) = model()
        model.attach(["/tmp/demo/notes.md", "/tmp/demo/notes.md", "/tmp/demo/b.txt"], to: 1)
        XCTAssertEqual(model.draftAttachments[1], ["/tmp/demo/notes.md", "/tmp/demo/b.txt"], "attachments are de-duplicated, order kept")

        model.detach("/tmp/demo/b.txt", from: 1)
        model.sendMessage(chat: 1, text: "  Summarise the attached notes.\n")

        XCTAssertEqual(sent.frames.count, 1)
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(send.chat, 1)
        XCTAssertEqual(send.text, "Summarise the attached notes.")
        XCTAssertEqual(send.attachments, ["/tmp/demo/notes.md"])
        XCTAssertNotNil(send.id, "a send carries an id so a refusal can be correlated")
        XCTAssertEqual(model.draftAttachments[1] ?? [], [], "a send clears the chat's draft attachments")
    }

    func testSendMessageWithBlankTextSendsNothing() {
        let (model, sent) = model()
        model.sendMessage(chat: 1, text: "   \n")
        XCTAssertTrue(sent.frames.isEmpty)
    }

    func testActionTextIsSentAsMessageSend() {
        let (model, sent) = model()
        let action = Action(label: "Review", text: "/review")
        model.sendMessage(chat: 2, text: action.text)
        guard case .messageSend(let send)? = sent.frames.first else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(send.text, "/review")
        XCTAssertEqual(send.attachments, [])
    }

    func testStopTurnEmitsTurnStop() {
        let (model, sent) = model()
        model.stopTurn(chat: 4)
        guard case .turnStop(let stop)? = sent.frames.first else { return XCTFail("expected turn.stop, got \(sent.frames)") }
        XCTAssertEqual(stop.chat, 4)
    }

    func testChatBusyFollowsTheStateWord() {
        let (model, _) = model()
        model.apply(.chatList(ChatList(chats: [summary(1, state: .idle), summary(2, state: .working), summary(3, state: .waitingOnYou), summary(4, state: .stopped)])))
        XCTAssertFalse(model.isBusy(chat: 1))
        XCTAssertTrue(model.isBusy(chat: 2))
        XCTAssertTrue(model.isBusy(chat: 3))
        XCTAssertFalse(model.isBusy(chat: 4))
        XCTAssertFalse(model.isBusy(chat: 9), "an unknown chat is not busy")
    }

    // MARK: - tool row presentation

    func testToolRowPresentationIconAndPrettyInput() {
        let row = ToolRow(
            toolUseId: "tu-1", turn: 1, tool: "Read", summary: "/tmp/demo/a.md",
            input: ["file_path": .string("/tmp/demo/a.md"), "limit": .int(20)])
        let shown = ToolRowPresentation(row: row)
        XCTAssertEqual(shown.icon, "doc.text")
        XCTAssertEqual(shown.prettyInput, "{\n  \"file_path\" : \"/tmp/demo/a.md\",\n  \"limit\" : 20\n}")
        XCTAssertEqual(shown.stateText, "running")

        XCTAssertEqual(ToolRowPresentation(row: ToolRow(toolUseId: "x", turn: 1, tool: "Bash", summary: "ls", input: [:])).icon, "terminal")
        XCTAssertEqual(ToolRowPresentation(row: ToolRow(toolUseId: "x", turn: 1, tool: "Mystery", summary: "", input: [:])).icon, "wrench.and.screwdriver")

        var done = row
        done.finished = true
        done.ok = true
        done.result = "read 120 lines"
        XCTAssertEqual(ToolRowPresentation(row: done).stateText, "read 120 lines")

        var failed = row
        failed.finished = true
        failed.ok = false
        failed.result = "permission denied"
        XCTAssertEqual(ToolRowPresentation(row: failed).stateText, "failed: permission denied")
        XCTAssertEqual(ToolRowPresentation(row: ToolRow(toolUseId: "x", turn: 1, tool: "Bash", summary: "ls", input: [:])).prettyInput, "{\n\n}")
    }
}
