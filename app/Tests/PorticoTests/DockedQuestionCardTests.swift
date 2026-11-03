import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// v0.16 (AO1): question cards dock above the composer in the Claude
/// pattern. The draft's pager, ordering, skip and declines; the dock's
/// keys; the transcript's pill and record; and the model's side: no
/// inline copy, the docked card, and reply directly.
@MainActor
final class DockedQuestionCardTests: XCTestCase {

    final class Sent {
        var frames: [ClientMessage] = []
        func types() -> [String] { frames.map(\.type) }
    }

    // MARK: - fixtures

    private static let tone = "Which tone for step 2?"
    private static let length = "How long?"

    private static func question(
        _ text: String = tone, labels: [String] = ["Plain", "Explained"], multi: Bool = false, previews: [String?]? = nil
    ) -> Question {
        let options = labels.enumerated().map { index, label in
            Option(label: label, description: "", preview: previews?[index] ?? nil)
        }
        return Question(question: text, header: "Tone", options: options, multiSelect: multi)
    }

    private static func card(_ questions: [Question], chat: Int = 1, id: String = "card-q") -> CardAsk {
        CardAsk(
            chat: chat, id: id, kind: .question, title: "Acme has a question", permission: nil, questions: questions,
            form: nil, toolUseId: "toolu_q", seq: 2)
    }

    private static func twoQuestions() -> CardAsk {
        card([question(tone, labels: ["Plain", "Explained"]), question(length, labels: ["Short", "Long"])])
    }

    private func model(queues: Bool = true) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: queues ? ["queue.v1"] : [])))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/acme", alias: nil, state: .waitingOnYou, created: "2026-11-02T12:00:00Z"),
        ])))
        return (model, sent)
    }

    // MARK: - ordering

    func testRecommendedIsListedFirst() {
        let draft = QuestionDraft(card: Self.card([Self.question(labels: ["Plain", "Formal (Recommended)", "Playful"])]))
        let ordered = draft.ordered(0)
        XCTAssertEqual(ordered.map(\.label), ["Formal (Recommended)", "Plain", "Playful"])
        XCTAssertTrue(draft.isRecommended(ordered[0]))
        XCTAssertFalse(draft.isRecommended(ordered[1]))
    }

    // MARK: - single select

    func testChoosingAnswersAndMovesOnThenTheWholeAnswerGoesAfterTheLast() throws {
        var draft = QuestionDraft(card: Self.twoQuestions())
        XCTAssertEqual(draft.page, 0)
        XCTAssertNil(draft.choose("Plain", for: 0))
        XCTAssertEqual(draft.page, 1)
        let answer = try XCTUnwrap(draft.choose("Short", for: 1))
        XCTAssertEqual(answer.chat, 1)
        XCTAssertEqual(answer.id, "card-q")
        XCTAssertEqual(answer.answer, ["answers": .object([Self.tone: .string("Plain"), Self.length: .string("Short")])])
    }

    func testThePagerMovesWithinTheQuestions() {
        var draft = QuestionDraft(card: Self.twoQuestions())
        draft.goTo(1)
        XCTAssertEqual(draft.page, 1)
        draft.goTo(5)
        XCTAssertEqual(draft.page, 1, "past the last stays on the last")
        draft.goTo(-1)
        XCTAssertEqual(draft.page, 0)
        XCTAssertEqual(DockedCardPager(page: 0, count: 2).text, "1 of 2")
    }

    // MARK: - multi select

    func testMultiSelectTogglesAndNextAnswersInOptionOrder() throws {
        let card = Self.card([Self.question("Which steps?", labels: ["One", "Two", "Three"], multi: true)])
        var draft = QuestionDraft(card: card)
        XCTAssertNil(draft.next(), "nothing ticked: Next does nothing")
        draft.toggle("Three", for: 0)
        draft.toggle("One", for: 0)
        XCTAssertTrue(draft.isSelected("One", for: 0))
        let answer = try XCTUnwrap(draft.next())
        XCTAssertEqual(answer.answer, ["answers": .object(["Which steps?": .array([.string("One"), .string("Three")])])])
    }

    func testNextOrSubmit() {
        var draft = QuestionDraft(card: card2Multi())
        XCTAssertEqual(draft.advanceLabel, "Next")
        draft.goTo(1)
        XCTAssertEqual(draft.advanceLabel, "Next", "the first is still open")
        draft.goTo(0)
        draft.toggle("One", for: 0)
        _ = draft.next()
        XCTAssertEqual(draft.page, 1)
        XCTAssertEqual(draft.advanceLabel, "Submit")
    }

    private func card2Multi() -> CardAsk {
        Self.card([
            Self.question("Which steps?", labels: ["One", "Two"], multi: true),
            Self.question("Which screens?", labels: ["Home", "Settings"], multi: true),
        ])
    }

    // MARK: - Something else

    func testSomethingElseAnswersWithItsText() throws {
        var draft = QuestionDraft(card: Self.card([Self.question()]))
        draft.setOther("   ", for: 0)
        XCTAssertNil(draft.submitOther(for: 0), "blank answers nothing")
        draft.setOther("Warmer", for: 0)
        let answer = try XCTUnwrap(draft.submitOther(for: 0))
        XCTAssertEqual(answer.answer, ["answers": .object([Self.tone: .string("Warmer")])])
    }

    func testChoosingAfterTypingDropsTheTypedText() throws {
        var draft = QuestionDraft(card: Self.card([Self.question()]))
        draft.setOther("Warmer", for: 0)
        let answer = try XCTUnwrap(draft.choose("Plain", for: 0))
        XCTAssertEqual(answer.answer, ["answers": .object([Self.tone: .string("Plain")])])
    }

    // MARK: - Skip and ×

    func testSkipLeavesAQuestionOutAndSkippingAllDeclines() throws {
        var draft = QuestionDraft(card: Self.twoQuestions())
        XCTAssertNil(draft.skip(0))
        XCTAssertEqual(draft.page, 1)
        let answer = try XCTUnwrap(draft.choose("Short", for: 1))
        XCTAssertEqual(answer.answer, ["answers": .object([Self.length: .string("Short")])])

        var all = QuestionDraft(card: Self.twoQuestions())
        XCTAssertNil(all.skip(0))
        let skipped = try XCTUnwrap(all.skip(1))
        XCTAssertEqual(skipped.answer, ["declined": .string("skipped")], "never an empty answers map")
        XCTAssertEqual(skipped.declined, .skipped)
    }

    func testCloseDismisses() {
        let draft = QuestionDraft(card: Self.twoQuestions())
        let answer = draft.decline(.dismissed)
        XCTAssertEqual(answer.answer, ["declined": .string("dismissed")])
        XCTAssertEqual(answer.chat, 1)
        XCTAssertEqual(answer.id, "card-q")
    }

    func testAPagerJumpStillAsksTheQuestionLeftBehind() throws {
        var draft = QuestionDraft(card: Self.twoQuestions())
        draft.goTo(1)
        XCTAssertNil(draft.choose("Long", for: 1), "the first is not answered yet")
        XCTAssertEqual(draft.page, 0)
        let answer = try XCTUnwrap(draft.choose("Plain", for: 0))
        XCTAssertEqual(answer.answer, ["answers": .object([Self.tone: .string("Plain"), Self.length: .string("Long")])])
    }

    // MARK: - previews

    func testThePreviewIsTheFocusedOptionsAndHidesWithoutAny() {
        var draft = QuestionDraft(card: Self.card([
            Self.question(labels: ["Plain", "Explained"], previews: ["**Plain** copy", "Explained copy"]),
        ]))
        XCTAssertTrue(draft.hasPreviews(0))
        XCTAssertEqual(draft.focused, 0)
        XCTAssertEqual(draft.preview(0), "**Plain** copy")
        draft.move(by: 1)
        XCTAssertEqual(draft.preview(0), "Explained copy")
        draft.move(by: 5)
        XCTAssertEqual(draft.focused, 1, "focus stays on the options")

        let plain = QuestionDraft(card: Self.card([Self.question()]))
        XCTAssertFalse(plain.hasPreviews(0))
        XCTAssertNil(plain.preview(0), "no previews: the column hides")
    }

    func testThePreviewFollowsTheOrderShown() {
        let draft = QuestionDraft(card: Self.card([
            Self.question(labels: ["Plain", "Formal (Recommended)"], previews: ["plain", "formal"]),
        ]))
        XCTAssertEqual(draft.preview(0), "formal", "the Recommended one is first, and focused")
    }

    // MARK: - keys (Review Focus 3)

    func testKeysActOnlyWhileTheCardHasFocus() {
        XCTAssertNil(QuestionDockKeys.action(for: "2", cardFocused: false, optionCount: 3), "the composer has it: digits type")
        XCTAssertEqual(QuestionDockKeys.action(for: "2", cardFocused: true, optionCount: 3), .choose(1))
        XCTAssertEqual(QuestionDockKeys.action(for: "1", cardFocused: true, optionCount: 3), .choose(0))
        XCTAssertNil(QuestionDockKeys.action(for: "4", cardFocused: true, optionCount: 3), "no fourth option")
        XCTAssertNil(QuestionDockKeys.action(for: "5", cardFocused: true, optionCount: 5), "1–4 only")
        XCTAssertNil(QuestionDockKeys.action(for: "0", cardFocused: true, optionCount: 3))
        XCTAssertEqual(QuestionDockKeys.action(for: .downArrow, cardFocused: true, optionCount: 3), .move(1))
        XCTAssertEqual(QuestionDockKeys.action(for: .upArrow, cardFocused: true, optionCount: 3), .move(-1))
        XCTAssertEqual(QuestionDockKeys.action(for: .return, cardFocused: true, optionCount: 3), .confirm)
        XCTAssertNil(QuestionDockKeys.action(for: .return, cardFocused: false, optionCount: 3))
        XCTAssertNil(QuestionDockKeys.action(for: .escape, cardFocused: true, optionCount: 3), "Esc does nothing (Ruling 15)")
    }

    // MARK: - focus (fix round 1)

    func testTheCardsKeysAreLiveOnlyWhileTheCardItselfHasTheFocus() {
        XCTAssertTrue(QuestionDockKeys.isActive(cardFocused: true, fieldFocused: false), "the card focused")
        XCTAssertFalse(QuestionDockKeys.isActive(cardFocused: true, fieldFocused: true), "typing in Something else")
        XCTAssertFalse(QuestionDockKeys.isActive(cardFocused: false, fieldFocused: false), "the composer focused")
        // Typed in the field, the keys reach the card as inactive: digits, arrows and Return are the field's.
        let inField = QuestionDockKeys.isActive(cardFocused: true, fieldFocused: true)
        XCTAssertNil(QuestionDockKeys.action(for: "2", cardFocused: inField, optionCount: 3))
        XCTAssertNil(QuestionDockKeys.action(for: .downArrow, cardFocused: inField, optionCount: 3))
        XCTAssertNil(QuestionDockKeys.action(for: .return, cardFocused: inField, optionCount: 3), "Return submits the text")
    }

    func testADockingCardLeavesTypedTextItsFocus() {
        XCTAssertTrue(QuestionDockKeys.takesFocusOnAppear(composerFocused: false, composerText: "half a thought"))
        XCTAssertTrue(QuestionDockKeys.takesFocusOnAppear(composerFocused: true, composerText: ""))
        XCTAssertTrue(QuestionDockKeys.takesFocusOnAppear(composerFocused: true, composerText: "  \n"))
        XCTAssertFalse(QuestionDockKeys.takesFocusOnAppear(composerFocused: true, composerText: "half a thought"))
    }

    // MARK: - the dock's height (fix round 1)

    func testTheDockIsCappedNearHalfTheConversation() {
        XCTAssertEqual(DockedCardLayout.maxHeight(available: 800), 360)
        XCTAssertNil(DockedCardLayout.bodyCap(dockMax: nil, header: 30), "unmeasured: no cap")
        XCTAssertEqual(DockedCardLayout.bodyCap(dockMax: 360, header: 30), 360 - 30 - DockedCardLayout.chrome)
        XCTAssertEqual(DockedCardLayout.bodyCap(dockMax: 100, header: 30), DockedCardLayout.minBody, "never below the floor")
        XCTAssertEqual(DockedCardLayout.bodyHeight(content: 200, cap: 298), 200, "short content: its own height")
        XCTAssertEqual(DockedCardLayout.bodyHeight(content: 900, cap: 298), 298, "long content scrolls inside")
    }

    // MARK: - the transcript's record (Ruling 12)

    private static func input(_ questions: [String]) -> [String: JSONValue] {
        ["questions": .array(questions.map { .object(["question": .string($0), "header": .string("H"), "options": .array([])]) })]
    }

    func testTheRecordLine() {
        let one = Self.input([Self.tone])
        XCTAssertEqual(QuestionRecord.line(input: one, answers: nil, finished: false), "Asking a question")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: [Self.tone: .one("Plain")], finished: true),
            "Asked: Which tone for step 2? · Plain")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: nil, finished: true),
            "Asked: Which tone for step 2? · Not answered")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: nil, finished: true, ok: false),
            "Asked: Which tone for step 2? · Not answered")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: nil, finished: true, ok: true),
            "Asked: Which tone for step 2?", "a session from before v0.16 has no answers (Ruling 1)")

        let two = Self.input([Self.tone, Self.length])
        XCTAssertEqual(
            QuestionRecord.line(input: two, answers: [Self.length: .one("Short"), Self.tone: .one("Plain")], finished: true),
            "Asked 2 questions · Plain, Short", "answers in question order")
        XCTAssertEqual(
            QuestionRecord.line(input: two, answers: [Self.length: .one("Short")], finished: true),
            "Asked 2 questions · Short", "a skipped one is left out")
        XCTAssertEqual(
            QuestionRecord.line(input: two, answers: nil, finished: true, ok: false),
            "Asked 2 questions · Not answered")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: [Self.tone: .many(["One", "Two"])], finished: true),
            "Asked: Which tone for step 2? · One, Two")
        XCTAssertEqual(
            QuestionRecord.line(input: one, answers: [Self.tone: .one("Plain (Recommended)")], finished: true),
            "Asked: Which tone for step 2? · Plain", "the record drops the Recommended mark")
        XCTAssertEqual(QuestionRecord.shown("(Recommended)"), "(Recommended)", "a bare mark stays")
        XCTAssertEqual(QuestionRecord.shown("Recommended"), "Recommended")

        // The answer the agent gets keeps the label as written.
        var draft = QuestionDraft(card: Self.card([Self.question(labels: ["Plain (Recommended)", "Explained"])]))
        XCTAssertEqual(
            draft.choose("Plain (Recommended)", for: 0)?.answer,
            ["answers": .object([Self.tone: .string("Plain (Recommended)")])])
    }

    // MARK: - the model

    func testAQuestionDocksAndLeavesNoInlineCopyWhileAFormStillPins() {
        let (model, _) = model()
        let card = Self.twoQuestions()
        model.apply(.cardAsk(card))
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q")
        XCTAssertFalse((model.transcripts[1] ?? []).contains { if case .card = $0 { true } else { false } }, "no inline copy")
        XCTAssertEqual(model.pinnedCards(for: 1), [], "a question is docked, not pinned")

        let form = CardAsk(
            chat: 1, id: "card-f", kind: .form, title: "Details", permission: nil, questions: nil,
            form: [FormField(key: "name", label: "Name", kind: .text, options: nil)], seq: 3)
        model.apply(.cardAsk(form))
        XCTAssertEqual(model.pinnedCards(for: 1).map(\.id), ["card-f"], "a form still pins")
        XCTAssertEqual((model.transcripts[1] ?? []).last, .card(form), "and keeps its inline copy")
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q")

        // The oldest open question or permission card docks; the next follows it.
        let permission = CardAsk(
            chat: 1, id: "card-p", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/acme/a.md", input: [:]), questions: nil, form: nil, seq: 4)
        model.apply(.cardAsk(permission))
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q")
        model.answerCard(QuestionDraft(card: card).decline(.dismissed))
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-p")
        XCTAssertNil(model.dockedCard(for: 2), "a card docks only in its own conversation")
    }

    /// The gateway accepts the latest message.send: `chat.queued` with its id.
    private func accept(_ model: AppModel, _ sent: Sent) throws {
        guard case .messageSend(let send)? = sent.frames.last(where: { $0.type == "message.send" }) else {
            return XCTFail("expected a message.send")
        }
        model.apply(.chatQueued(ChatQueued(chat: 1, id: try XCTUnwrap(send.id))))
    }

    func testReplyDirectlySendsTheMessageThenTheDeclineOnceItIsAccepted() throws {
        let (model, sent) = model()
        model.apply(.cardAsk(Self.twoQuestions()))
        model.setDraft("Use the short one", for: 1)
        XCTAssertTrue(InputBar.canSend(model, chat: 1, text: "Use the short one"))

        model.replyDirectly(chat: 1, text: "Use the short one")
        XCTAssertEqual(sent.types().last, "message.send")
        XCTAssertFalse(sent.types().contains("card.answer"), "nothing is declined before the reply is accepted")
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q")
        XCTAssertEqual(model.draft(for: 1), "", "the composer is cleared, as any send")

        try accept(model, sent)
        let sends = sent.frames.filter { if case .messageSend = $0 { true } else if case .cardAnswer = $0 { true } else { false } }
        XCTAssertEqual(sends.map(\.type), ["message.send", "card.answer"], "the message first, then the decline")
        guard case .messageSend(let message) = sends[0], case .cardAnswer(let answer) = sends[1] else {
            return XCTFail("expected message.send then card.answer")
        }
        XCTAssertEqual(message.text, "Use the short one")
        XCTAssertEqual(answer.answer, ["declined": .string("replied")])
        XCTAssertEqual(answer.id, "card-q")
        XCTAssertNil(model.dockedCard(for: 1), "the card goes")
    }

    func testARefusedReplyDeclinesNothingAndTheCardStays() throws {
        let (model, sent) = model()
        model.apply(.cardAsk(Self.twoQuestions()))
        model.replyDirectly(chat: 1, text: "Use the short one")
        guard case .messageSend(let send)? = sent.frames.last else { return XCTFail("expected message.send") }
        model.apply(.error(ErrorMessage(code: "attachment.missing", message: "That file is gone.", chat: 1, id: send.id)))
        XCTAssertEqual(model.draft(for: 1), "Use the short one", "the text goes back in the composer")
        XCTAssertEqual(model.status[1], "That file is gone.", "the refusal shows")
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q", "the question is still asked")

        // A late chat.queued with that id declines nothing either.
        model.apply(.chatQueued(ChatQueued(chat: 1, id: send.id)))
        XCTAssertFalse(sent.types().contains("card.answer"))
    }

    func testAnOptionChosenWhileTheReplyWaitsIsTheAnswer() throws {
        let (model, sent) = model()
        let card = Self.twoQuestions()
        model.apply(.cardAsk(card))
        model.replyDirectly(chat: 1, text: "And one more thing")
        model.answerCard(QuestionDraft(card: card).decline(.dismissed))
        try accept(model, sent)
        XCTAssertEqual(sent.types().filter { $0 == "card.answer" }.count, 1, "the card was answered once; the reply is just a message")
    }

    func testTheComposersSendRepliesDirectlyWhileAQuestionIsDocked() throws {
        let (model, sent) = model()
        model.apply(.cardAsk(Self.twoQuestions()))
        model.sendMessage(chat: 1, text: "Neither, keep it as is")
        try accept(model, sent)
        XCTAssertEqual(sent.types().suffix(2), ["message.send", "card.answer"])
        XCTAssertEqual(
            InputBar.placeholder(
                connected: true, renewing: false, logging: false, sending: false, about: nil, agentName: "Acme", thread: nil,
                questionDocked: true),
            "Or reply directly…")
    }

    func testWithAPermissionCardDockedASendIsOnlyASend() {
        let (model, sent) = model()
        model.apply(.cardAsk(CardAsk(
            chat: 1, id: "card-p", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/acme/a.md", input: [:]), questions: nil, form: nil, seq: 4)))
        model.sendMessage(chat: 1, text: "Also check uvx.")
        XCTAssertEqual(sent.types().last, "message.send")
        XCTAssertFalse(sent.types().contains("card.answer"), "Ruling 16: the permission card stays")
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-p")
    }

    // MARK: - the answer as the person's reply (v0.16 §9.4)

    private static func input(_ questions: [(String, [String])]) -> [String: JSONValue] {
        ["questions": .array(questions.map { text, labels in
            .object([
                "question": .string(text), "header": .string("H"),
                "options": .array(labels.map { .object(["label": .string($0), "description": .string("")]) }),
            ])
        })]
    }

    func testTheBubbleIsSpokenAsYourAnswer() {
        XCTAssertEqual(
            AnswerBubble.spokenLabel(AnswerPair(question: "Which tone for step 2?", answer: "Plain")), "Your answer: Plain")
    }

    func testHoverHighlightsButDoesNotArm() {
        var draft = QuestionDraft(card: Self.card([Self.question(labels: ["Plain", "Explained", "Terse"])]))
        draft.hover(2)
        XCTAssertEqual(draft.highlighted, 2)
        XCTAssertEqual(draft.focused, 0, "Return and the digits still act on the keyboard focus")
        XCTAssertEqual(QuestionDockKeys.action(for: .return, cardFocused: true, optionCount: 3), .confirm)
        draft.move(by: 1)
        XCTAssertNil(draft.hovered, "an arrow takes the highlight back from the pointer")
        XCTAssertEqual(draft.highlighted, 1)
        draft.hover(2)
        draft.hover(nil)
        XCTAssertEqual(draft.highlighted, draft.focused)
    }

    /// R-c7: the preview shows the highlighted option, so the pointer moves
    /// it; whichever input came last wins, and Return stays on the focus.
    func testThePreviewFollowsTheHighlightedOption() {
        var draft = QuestionDraft(card: Self.card([Self.question(labels: ["Plain", "Explained", "Terse"],
                                                                previews: ["# Plain", "# Explained", "# Terse"])]))
        XCTAssertEqual(draft.preview(0), "# Plain")
        draft.hover(1)
        XCTAssertEqual(draft.preview(0), "# Explained", "the pointer moves the preview")
        XCTAssertEqual(draft.focused, 0)
        draft.focus(2)
        XCTAssertNil(draft.hovered, "a digit or click takes the highlight back from the pointer")
        XCTAssertEqual(draft.preview(0), "# Terse")
        draft.hover(0)
        draft.move(by: -1)
        XCTAssertEqual(draft.preview(0), "# Explained", "an arrow takes it back again")
    }

    func testOneAnsweredQuestionIsOneBubbleWithItsHeader() {
        let input = Self.input([(Self.tone, ["Plain", "Explained"])])
        XCTAssertEqual(
            QuestionRecord.answerPairs(input: input, answers: [Self.tone: .one("Plain")], finished: true),
            [AnswerPair(question: Self.tone, answer: "Plain")])
        XCTAssertEqual(AnswerPair(question: Self.tone, answer: "Plain").header, "Answer to: Which tone for step 2?")
    }

    func testSeveralQuestionsAreOnePairEachInQuestionOrder() {
        let input = Self.input([(Self.tone, ["Plain", "Explained"]), (Self.length, ["Short", "Long"])])
        XCTAssertEqual(
            QuestionRecord.answerPairs(
                input: input, answers: [Self.length: .one("Short"), Self.tone: .one("Plain")], finished: true),
            [AnswerPair(question: Self.tone, answer: "Plain"), AnswerPair(question: Self.length, answer: "Short")])
        XCTAssertEqual(
            QuestionRecord.answerPairs(input: input, answers: [Self.length: .one("Short")], finished: true),
            [AnswerPair(question: Self.length, answer: "Short")], "a skipped question has no pair")
        XCTAssertEqual(
            QuestionRecord.answerPairs(input: input, answers: [Self.tone: .many(["Plain", "Explained"])], finished: true),
            [AnswerPair(question: Self.tone, answer: "Plain, Explained")], "a multi-select's labels, joined")
    }

    func testATypedAnswerShowsInFull() {
        let input = Self.input([(Self.tone, ["Plain", "Explained"])])
        let typed = "Something else goes here. A second sentence, kept whole (Recommended)"
        XCTAssertEqual(
            QuestionRecord.answerPairs(input: input, answers: [Self.tone: .one(typed)], finished: true),
            [AnswerPair(question: Self.tone, answer: typed)], "typed text is not an option: nothing is stripped")
    }

    func testTheRecommendedMarkIsStrippedFromAChosenOption() {
        let input = Self.input([(Self.tone, ["Plain (Recommended)", "Explained"])])
        XCTAssertEqual(
            QuestionRecord.answerPairs(input: input, answers: [Self.tone: .one("Plain (Recommended)")], finished: true),
            [AnswerPair(question: Self.tone, answer: "Plain")])
    }

    func testADeclineOrAnOpenQuestionHasNoBubble() {
        let input = Self.input([(Self.tone, ["Plain", "Explained"])])
        XCTAssertNil(QuestionRecord.answerPairs(input: input, answers: nil, finished: true), "declined: the record line")
        XCTAssertNil(QuestionRecord.answerPairs(input: input, answers: [:], finished: true))
        XCTAssertNil(
            QuestionRecord.answerPairs(input: input, answers: [Self.tone: .one("Plain")], finished: false),
            "still asking: the pill")
        XCTAssertEqual(
            QuestionRecord.line(input: input, answers: nil, finished: true, ok: false),
            "Asked: Which tone for step 2? · Not answered")
    }

    func testAReplayedAnswerIsABubble() {
        let (model, _) = model()
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .toolStarted(ToolStarted(
                chat: 1, turn: 1, toolUseId: "toolu_q", tool: "AskUserQuestion", summary: "Asking a question",
                input: Self.input([(Self.tone, ["Plain", "Explained"])]), seq: 1)),
            .toolFinished(ToolFinished(
                chat: 1, turn: 1, toolUseId: "toolu_q", ok: true, summary: "Answered",
                answers: [Self.tone: .one("Explained")], seq: 2)),
        ], truncated: false)))
        guard case .tool(let row)? = model.transcripts[1]?.last else { return XCTFail("expected the question's row") }
        XCTAssertEqual(QuestionRecord.answerPairs(for: row), [AnswerPair(question: Self.tone, answer: "Explained")])
    }

    func testAReplyThatCannotGoSendsNoDecline() {
        let (model, sent) = model()
        model.apply(.cardAsk(Self.twoQuestions()))
        model.replyDirectly(chat: 1, text: "   ")
        XCTAssertFalse(sent.types().contains("card.answer"), "nothing was sent, so nothing is declined")
        XCTAssertEqual(model.dockedCard(for: 1)?.id, "card-q")
    }

    func testFinishedAnswersFillTheRowAndAReplayDrawsTheRecord() throws {
        let (model, _) = model()
        let questions: JSONValue = .array([.object(["question": .string(Self.tone), "header": .string("Tone"), "options": .array([])])])
        model.apply(.chatHistory(ChatHistory(chat: 1, events: [
            .toolStarted(ToolStarted(
                chat: 1, turn: 1, toolUseId: "toolu_q", tool: "AskUserQuestion", summary: "Asking a question",
                input: ["questions": questions], seq: 1)),
            .toolFinished(ToolFinished(
                chat: 1, turn: 1, toolUseId: "toolu_q", ok: true, summary: "Answered",
                answers: [Self.tone: .one("Plain")], seq: 2)),
        ], truncated: false)))
        guard case .tool(let row)? = model.transcripts[1]?.last else { return XCTFail("expected the question's row") }
        XCTAssertEqual(row.answers?[Self.tone], .one("Plain"))
        XCTAssertTrue(QuestionRecord.isRecord(row), "drawn as the record, not an ordinary row")
        XCTAssertEqual(QuestionRecord.line(for: row), "Asked: Which tone for step 2? · Plain")

        var other = row
        other.tool = "Read"
        XCTAssertFalse(QuestionRecord.isRecord(other))
    }

    func testAToolFinishedDecodedWithAnswersFillsTheRow() throws {
        let (model, _) = model()
        model.apply(.toolStarted(ToolStarted(
            chat: 1, turn: 1, toolUseId: "toolu_q", tool: "AskUserQuestion", summary: "", input: Self.input([Self.tone]), seq: 1)))
        let json = """
            {"type":"tool.finished","chat":1,"turn":1,"tool_use_id":"toolu_q","ok":true,"summary":"Answered",
             "answers":{"Which tone for step 2?":"Plain"},"seq":2,"ts":"2026-11-02T12:00:00Z"}
            """
        let message = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        model.apply(message)
        guard case .tool(let row)? = model.transcripts[1]?.last else { return XCTFail("expected the question's row") }
        XCTAssertEqual(QuestionRecord.line(for: row), "Asked: Which tone for step 2? · Plain")
    }
}
