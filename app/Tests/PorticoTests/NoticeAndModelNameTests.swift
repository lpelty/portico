import Foundation
import XCTest

@testable import Portico

/// v0.3: `chat.notice` as a quiet line in the conversation, and the
/// deployment's display name for the model (`model_name`) wherever the
/// model is shown. Model-only.
@MainActor
final class NoticeAndModelNameTests: XCTestCase {

    private func model() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        return model
    }

    private func notices(_ model: AppModel, chat: Int) -> [String] {
        (model.transcripts[chat] ?? []).compactMap { if case .notice(_, let text) = $0 { text } else { nil } }
    }

    func testNoticeIsALineLiveAndInReplayAndNotAppliedTwice() {
        let model = model()
        model.apply(.chatNotice(ChatNotice(chat: 1, text: "No command /foo here", seq: 4)))
        model.apply(.chatNotice(ChatNotice(chat: 1, text: "No command /foo here", seq: 4)))
        XCTAssertEqual(notices(model, chat: 1), ["No command /foo here"], "a re-sent frame is not drawn twice")
        XCTAssertEqual(model.lastSeq[1], 4)

        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .userText(UserText(chat: 1, turn: 1, text: "/foo")),
            .chatNotice(ChatNotice(chat: 1, text: "No command /foo here")),
        ], truncated: false)))
        XCTAssertEqual(notices(model, chat: 1), ["No command /foo here"], "the replay draws it in place")
        guard case .notice? = model.transcripts[1]?.last else { return XCTFail("the notice follows the message") }
    }

    func testModelNameWinsOverTheIdWhereverTheModelIsShown() {
        let model = model()
        model.apply(.chatList(ChatList(chats: [ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-28T12:00:00Z")])))
        model.selected = 1
        model.apply(.contextUsage(ContextUsage(chat: 1, percent: 10, model: "claude-opus-5-5")))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).modelText, "Claude Opus 5.5", "the id, made readable")

        model.apply(.contextUsage(ContextUsage(chat: 1, percent: 12, model: "claude-opus-5-5", modelName: "Claude Opus 5.5 (work)")))
        XCTAssertEqual(model.modelName(for: 1), "Claude Opus 5.5 (work)")
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).modelText, "Claude Opus 5.5 (work)")
        XCTAssertEqual(model.modelName(for: 2), "Claude Opus 5.5 (work)", "another session shows the deployment's model too")

        XCTAssertEqual(ContextUsage(chat: 1, percent: 1, model: "m", modelName: "  ").displayModel, "m", "a blank name falls back to the id")
        XCTAssertNil(ContextUsage(chat: 1, percent: 1).displayModel)
    }
}
