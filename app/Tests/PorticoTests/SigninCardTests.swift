import XCTest
@testable import Portico

/// v0.25 §4 (PORT-3, ZE3): the docked sign-in card, its fold, and the paused marker.
@MainActor
final class SigninCardTests: XCTestCase {
    final class Sent { var frames: [ClientMessage] = [] }

    private func model() -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Front", agentName: "Agent"), actions: [], roots: [], commands: [],
            capabilities: [SigninWait.capability])))
        model.setConnection(.connected)
        return (model, sent)
    }

    private func wait(_ state: SigninWait.State, turn: Int = 1, url: String? = nil, code: String? = nil,
                      wantsCode: Bool? = nil, canOpen: Bool = true) -> SigninWait {
        SigninWait(
            chat: 1, turn: turn, state: state, kind: "aws-sso", title: "Sign in again to continue",
            body: "Your sign-in to AWS has run out. Sign in in your browser; this conversation carries on by itself when you're done.",
            canOpen: canOpen, started: "2026-11-08T21:14:00Z", url: url, code: code, wantsCode: wantsCode,
            ts: "2026-11-08T21:31:00Z")
    }

    private func failTurn(_ model: AppModel, turn: Int = 1, reason: String? = "signin.expired") {
        model.apply(.turnStarted(TurnStarted(chat: 1, turn: turn, seq: turn * 10)))
        model.apply(.turnFinished(TurnFinished(chat: 1, turn: turn, outcome: .error, reason: reason, seq: turn * 10 + 1)))
    }

    private func marker(_ model: AppModel, turn: Int = 1) -> TurnMarker? {
        for item in model.transcripts[1] ?? [] {
            if case .turnMarker(let m) = item, m.turn == turn { return m }
        }
        return nil
    }

    func testTheAppListsSigninInItsHello() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("signin.v1"))
        XCTAssertEqual(SigninWait.capability, "signin.v1")
    }

    func testWaitingPausesTheMarkerAndDocksTheCard() {
        let (model, _) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        XCTAssertEqual(model.signinWaits[1]?.state, .waiting)
        let m = marker(model)
        XCTAssertEqual(m?.signinPaused, true)
        XCTAssertEqual(m.flatMap(TurnMarkerView.label), "Paused: sign-in ran out")
    }

    func testCurrentShowsContinuingThenCloses() async throws {
        let (model, _) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        model.apply(.signinWait(wait(.current)))
        XCTAssertNotNil(model.signinContinuing[1])
        XCTAssertEqual(model.signinWaits[1]?.state, .current)
        let notes = (model.transcripts[1] ?? []).compactMap { item -> String? in
            if case .signinContinued(_, let at) = item { return at } else { return nil }
        }
        XCTAssertEqual(notes, ["2026-11-08T21:31:00Z"])
        XCTAssertEqual(marker(model).flatMap(TurnMarkerView.label), "Paused: sign-in ran out", "ruling 15: the marker stays paused")
        try await Task.sleep(for: .seconds(SigninPresentation.continuingSeconds + 0.3))
        XCTAssertNil(model.signinWaits[1])
        XCTAssertNil(model.signinContinuing[1])
    }

    func testDontWaitSendsStopAndMarksEnded() {
        let (model, sent) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        model.stopSignin(chat: 1)
        guard case .signinStop(let stop)? = sent.frames.last else { return XCTFail("expected signin.stop, got \(sent.frames)") }
        XCTAssertEqual(stop.chat, 1)
        XCTAssertNil(model.signinWaits[1])
        XCTAssertEqual(marker(model).flatMap(TurnMarkerView.label), "Sign-in ran out")
        // The gateway's own `stopped` closes it as well.
        failTurn(model, turn: 2)
        model.apply(.signinWait(wait(.waiting, turn: 2)))
        model.apply(.signinWait(wait(.stopped, turn: 2)))
        XCTAssertNil(model.signinWaits[1])
        XCTAssertEqual(marker(model, turn: 2).flatMap(TurnMarkerView.label), "Sign-in ran out")
    }

    func testAReasonWithoutAWaitReadsSignInRanOut() {
        let (model, _) = model()
        failTurn(model)
        XCTAssertEqual(marker(model).flatMap(TurnMarkerView.label), "Sign-in ran out")
        XCTAssertTrue(TurnMarkerView.isDrawn(.turnMarker(marker(model)!)))
        failTurn(model, turn: 2, reason: nil)
        XCTAssertEqual(marker(model, turn: 2).flatMap(TurnMarkerView.label), "This turn ended with an error")
        failTurn(model, turn: 3, reason: "something.new")
        XCTAssertEqual(marker(model, turn: 3).flatMap(TurnMarkerView.label), "This turn ended with an error",
                       "a reason the app doesn't know reads as the plain outcome")
    }

    func testFoldIntroAndLinkVisibility() {
        XCTAssertNil(SigninPresentation.foldIntro(wait(.waiting)))
        XCTAssertFalse(SigninPresentation.offersTrouble(wait(.waiting)))
        XCTAssertEqual(SigninPresentation.foldIntro(wait(.waiting, url: "https://x.example", code: "QKXW-RTBN")),
                       "If the page didn't open, use this link and enter the code:")
        XCTAssertEqual(SigninPresentation.foldIntro(wait(.waiting, url: "https://x.example", wantsCode: true)),
                       "If the page didn't open, use this link and paste the code it gives you:")
        XCTAssertEqual(SigninPresentation.foldIntro(wait(.waiting, url: "https://x.example")),
                       "If the page didn't open, use this link:")
        XCTAssertTrue(SigninPresentation.offersTrouble(wait(.waiting, url: "https://x.example")))
    }

    func testWaitingLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = SessionTime.parse("2026-11-09T03:20:00Z")!
        XCTAssertEqual(
            SigninPresentation.waitingLine(wait(.waiting), now: now, calendar: calendar, locale: Locale(identifier: "en_US")),
            "Waiting for sign-in… since 3:14 PM")
    }

    func testOpenAndPasteCodeSend() {
        let (model, sent) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        model.openSignin(chat: 1)
        guard case .signinOpen(let open)? = sent.frames.last else { return XCTFail("expected signin.open, got \(sent.frames)") }
        XCTAssertEqual(open.chat, 1)
        model.sendSigninCode(chat: 1, code: "  abc  ")
        guard case .signinCode(let code)? = sent.frames.last else { return XCTFail("expected signin.code, got \(sent.frames)") }
        XCTAssertEqual(code.chat, 1)
        XCTAssertEqual(code.code, "abc")
        let count = sent.frames.count
        model.sendSigninCode(chat: 1, code: "   ")
        XCTAssertEqual(sent.frames.count, count, "a blank code sends nothing")
    }

    func testSigninCardsClearOnDisconnect() {
        let (model, _) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        model.setConnection(.disconnected)
        XCTAssertTrue(model.signinWaits.isEmpty)
        XCTAssertTrue(model.signinContinuing.isEmpty)
    }

    func testAReplayedFinishKeepsTheWaitsPause() {
        // The gateway re-sends the wait after a reconnect, and again after the chat's history.
        let (model, _) = model()
        model.apply(.signinWait(wait(.waiting)))
        failTurn(model)
        XCTAssertEqual(marker(model).flatMap(TurnMarkerView.label), "Paused: sign-in ran out")
    }

    func testCardStrings() {
        XCTAssertEqual(SigninPresentation.openTitle, "Open sign-in page")
        XCTAssertEqual(SigninPresentation.dontWaitTitle, "Don't wait")
        XCTAssertEqual(SigninPresentation.troubleTitle, "Trouble signing in?")
        XCTAssertEqual(SigninPresentation.hideTitle, "Hide")
        XCTAssertEqual(SigninPresentation.continuingText, "Signed in. Continuing…")
        XCTAssertEqual(SigninPresentation.continuedNote, "Continued after sign-in")
        XCTAssertEqual(SigninPresentation.pastePrompt, "Paste the code from the browser")
        XCTAssertEqual(SigninPresentation.continuingSeconds, 1.5)
        XCTAssertTrue(SigninPresentation.showsOpen(wait(.waiting, canOpen: true)))
        XCTAssertFalse(SigninPresentation.showsOpen(wait(.waiting, canOpen: false)))
    }

    // MARK: - v0.26 (review L5)

    private func notes(_ model: AppModel) -> [String] {
        (model.transcripts[1] ?? []).compactMap { item -> String? in
            if case .signinContinued(_, let at) = item { return at } else { return nil }
        }
    }

    func testAContinuedNoticeBecomesTheNoteOncePerTurn() {
        let (model, _) = model()
        failTurn(model)
        model.apply(.signinWait(wait(.waiting)))
        model.apply(.signinWait(wait(.current)))
        model.apply(.chatNotice(ChatNotice(chat: 1, text: "Continued after sign-in", kind: "signin.continued", seq: 20,
                                           ts: "2026-11-08T21:31:01Z")))
        XCTAssertEqual(notes(model), ["2026-11-08T21:31:00Z"], "one note, not two")
        XCTAssertFalse((model.transcripts[1] ?? []).contains { if case .notice = $0 { true } else { false } })
    }

    func testAReplayedContinuedNoticeSplitsTheReply() {
        let (model, _) = model()
        let events: [ServerMessage] = [
            .turnStarted(TurnStarted(chat: 1, turn: 1)),
            .userText(UserText(chat: 1, turn: 1, text: "Summarise")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "Could not load AWS credentials")),
            .chatNotice(ChatNotice(chat: 1, text: "Continued after sign-in", kind: "signin.continued", ts: "2026-11-08T21:31:00Z")),
            .textDelta(TextDelta(chat: 1, turn: 1, text: "Here is the summary.")),
            .turnFinished(TurnFinished(chat: 1, turn: 1, outcome: .done)),
        ]
        model.apply(.chatHistory(ChatHistory(chat: 1, events: events, truncated: false)))
        let shape = (model.transcripts[1] ?? []).compactMap { item -> String? in
            switch item {
            case .assistantText(_, let text, _): "reply: \(text)"
            case .signinContinued: "note"
            default: nil
            }
        }
        XCTAssertEqual(shape, ["reply: Could not load AWS credentials", "note", "reply: Here is the summary."])
    }

    func testAPlainNoticeStaysAPlainLine() throws {
        let data = Data(#"{"type":"chat.notice","chat":1,"text":"No command /foo here","seq":3,"ts":"2026-11-08T21:31:00Z"}"#.utf8)
        guard case .chatNotice(let notice) = try JSONDecoder().decode(ServerMessage.self, from: data) else { return XCTFail() }
        XCTAssertNil(notice.kind)
        let kinded = Data(#"{"type":"chat.notice","chat":1,"text":"x","kind":"signin.continued","ts":"2026-11-08T21:31:00Z"}"#.utf8)
        guard case .chatNotice(let k) = try JSONDecoder().decode(ServerMessage.self, from: kinded) else { return XCTFail() }
        XCTAssertEqual(k.kind, ChatNotice.signinContinued)
    }
}
