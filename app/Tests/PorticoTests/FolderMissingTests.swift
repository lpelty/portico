import Foundation
import XCTest

@testable import Portico

/// v0.22.1: a conversation whose folder was deleted. The gateway refuses the
/// turn with `chat.folder_missing` and plain words; the failed turn's line in
/// the conversation says them instead of the generic "This turn ended with an
/// error".
@MainActor
final class FolderMissingTests: XCTestCase {
    private let words = "This conversation's folder no longer exists: /tmp/gone. Start a new conversation in another folder."
    private let ts = "2026-11-06T12:00:00Z"

    private func failedTurn(_ model: AppModel, chat: Int = 1) {
        model.apply(.turnStarted(TurnStarted(chat: chat, turn: 1, seq: 1, ts: ts)))
        model.apply(.turnFinished(TurnFinished(chat: chat, turn: 1, outcome: .error, seq: 2, ts: ts)))
    }

    private func markers(_ model: AppModel, chat: Int = 1) -> [TurnMarker] {
        (model.transcripts[chat] ?? []).compactMap { if case .turnMarker(let m) = $0 { m } else { nil } }
    }

    func testTheFailedTurnSaysTheFolderIsGone() {
        let model = AppModel()
        failedTurn(model)
        model.apply(.error(ErrorMessage(code: "chat.folder_missing", message: words, chat: 1, id: "r1")))
        XCTAssertEqual(markers(model).last?.reason, words)
        XCTAssertEqual(TurnMarkerView.label(markers(model).last!), words)
        XCTAssertNil(model.status[1], "said once, on the turn, not again in the status line")
    }

    func testOtherErrorsKeepTheGenericLineAndTheStatusLine() {
        let model = AppModel()
        failedTurn(model)
        model.apply(.error(ErrorMessage(code: "engine.start_failed", message: "the engine could not start in /tmp/x: boom", chat: 1, id: "r1")))
        XCTAssertNil(markers(model).last?.reason)
        XCTAssertEqual(TurnMarkerView.label(markers(model).last!), "This turn ended with an error")
        XCTAssertEqual(model.status[1], "the engine could not start in /tmp/x: boom")
    }

    /// No failed turn to put it on (a refusal that ended no turn): the
    /// status line, as for any error.
    func testWithoutAFailedTurnItGoesToTheStatusLine() {
        let model = AppModel()
        model.apply(.error(ErrorMessage(code: "chat.folder_missing", message: words, chat: 1, id: "r1")))
        XCTAssertEqual(model.status[1], words)
    }

    /// A thread whose log step cannot start because its folder is gone may
    /// still be closed without logging.
    func testClosingWithoutLoggingIsOffered() {
        XCTAssertTrue(CloseFailure(code: "chat.folder_missing", message: words).offersCloseWithoutLogging)
    }
}
