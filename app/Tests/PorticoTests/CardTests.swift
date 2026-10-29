import Foundation
import XCTest

@testable import Portico

/// The view-free side of the cards module: how each kind of card turns
/// what the person chose into a `card.answer`, and how a card's status
/// reads. No window.
@MainActor
final class CardTests: XCTestCase {

    private func permissionCard() -> CardAsk {
        CardAsk(
            chat: 1, id: "card-1", kind: .permission, title: "Write a file",
            permission: Permission(tool: "Write", summary: "/tmp/demo/a.md", input: ["file_path": .string("/tmp/demo/a.md")]),
            questions: nil, form: nil, seq: 1)
    }

    // MARK: - permission

    func testPermissionChoicesMapToDecisionAndScope() {
        let card = permissionCard()
        // V1: Deny… · Allow for this session · Allow once — no "Always allow".
        XCTAssertEqual(PermissionChoice.allCases.map(\.label), ["Deny…", "Allow for this session", "Allow once"])
        XCTAssertFalse(PermissionChoice.allCases.contains { $0.scope == .always }, "the app does not offer always")

        let once = PermissionChoice.allowOnce.answer(for: card, note: "")
        XCTAssertEqual(once.chat, 1)
        XCTAssertEqual(once.id, "card-1")
        XCTAssertEqual(once.answer, ["decision": .string("allow")])
        XCTAssertEqual(once.scope, .once)
        XCTAssertNil(once.note, "a blank note is left out")

        XCTAssertEqual(PermissionChoice.allowSession.answer(for: card).scope, .chat, "this session is the protocol's chat scope")
        XCTAssertNil(PermissionChoice.allowSession.answer(for: card, note: "  ok here ").note, "the note goes only with a deny")

        let deny = PermissionChoice.deny.answer(for: card, note: "  not that file ")
        XCTAssertEqual(deny.answer, ["decision": .string("deny")])
        XCTAssertNil(deny.scope, "deny carries no scope")
        XCTAssertEqual(deny.note, "not that file")
        XCTAssertNil(PermissionChoice.deny.answer(for: card, note: "   ").note)
    }

    func testPermissionCardReadsAsAPlainQuestionWithTheToolAsATag() {
        var card = permissionCard()
        card.title = "Save changes to Q3-synthesis.md?"
        let shown = PermissionPresentation(card: card)
        XCTAssertEqual(shown.question, "Save changes to Q3-synthesis.md?")
        XCTAssertEqual(shown.tool, "Write")
        card.title = "  "
        XCTAssertEqual(PermissionPresentation(card: card).question, "Use Write?")
        XCTAssertEqual(PermissionPresentation.whereLine(folder: "/Users/x/Research vault"), "in Research vault")
        XCTAssertNil(PermissionPresentation.whereLine(folder: nil))
        XCTAssertEqual(shown.scopeNote, PermissionPresentation.generalScopeNote, "an older gateway says nothing: the general line")
        card.scopeNote = "For this session: edits to files in Research vault, until you start a new session."
        XCTAssertEqual(PermissionPresentation(card: card).scopeNote, "For this session: edits to files in Research vault, until you start a new session.")
        card.scopeNote = "  "
        XCTAssertEqual(PermissionPresentation(card: card).scopeNote, PermissionPresentation.generalScopeNote)
        XCTAssertEqual(PermissionPresentation.noteHint(agentName: "Portico"), "Optional. Portico reads this instead of just being told no.")
    }

    func testPermissionPresentationShowsToolSummaryAndPrettyInput() {
        let shown = PermissionPresentation(card: permissionCard())
        XCTAssertEqual(shown.tool, "Write")
        XCTAssertEqual(shown.summary, "/tmp/demo/a.md")
        XCTAssertEqual(shown.prettyInput, "{\n  \"file_path\" : \"/tmp/demo/a.md\"\n}")

        // A permission card without its permission block still reads.
        var bare = permissionCard()
        bare.permission = nil
        XCTAssertEqual(PermissionPresentation(card: bare).tool, "tool")
        XCTAssertEqual(PermissionPresentation(card: bare).prettyInput, "{\n\n}")
    }

    // MARK: - question

    func testQuestionAnswersMapLabelsAndOther() {
        let questions = [
            Question(question: "Which format?", header: "Format", options: [
                Option(label: "Markdown", description: "a .md file"), Option(label: "PDF", description: "a .pdf"),
            ], multiSelect: false),
            Question(question: "Which sections?", header: "Sections", options: [
                Option(label: "Summary", description: ""), Option(label: "Details", description: ""), Option(label: "Appendix", description: ""),
            ], multiSelect: true),
        ]
        let card = CardAsk(chat: 3, id: "card-q", kind: .question, title: "Format", permission: nil, questions: questions, form: nil, seq: 2)

        var draft = QuestionDraft(card: card)
        XCTAssertFalse(draft.isComplete, "nothing chosen yet")
        XCTAssertNil(draft.answer())

        draft.choose("Markdown", for: 0)
        XCTAssertFalse(draft.isComplete, "the second question is still unanswered")
        draft.toggle("Details", for: 1)
        draft.toggle("Summary", for: 1)
        XCTAssertTrue(draft.isComplete)

        let answer = try! XCTUnwrap(draft.answer())
        XCTAssertEqual(answer.chat, 3)
        XCTAssertEqual(answer.id, "card-q")
        XCTAssertNil(answer.scope)
        XCTAssertEqual(answer.answer, [
            "answers": .object([
                "Which format?": .string("Markdown"),
                "Which sections?": .array([.string("Summary"), .string("Details")]),
            ]),
        ])
        XCTAssertEqual(draft.labels(for: 1), ["Summary", "Details"], "multi-select answers keep the option order")

        // Single select: choosing again replaces; toggling off a multi-select removes it.
        draft.choose("PDF", for: 0)
        draft.toggle("Details", for: 1)
        XCTAssertEqual(draft.answer()?.answer["answers"]?["Which format?"], .string("PDF"))
        XCTAssertEqual(draft.answer()?.answer["answers"]?["Which sections?"], .array([.string("Summary")]))

        // "Other" text is the label for a single-select and one more label for a multi-select.
        draft.setOther("Plain text", for: 0)
        draft.setOther("Glossary", for: 1)
        XCTAssertEqual(draft.answer()?.answer["answers"]?["Which format?"], .string("Plain text"))
        XCTAssertEqual(draft.answer()?.answer["answers"]?["Which sections?"], .array([.string("Summary"), .string("Glossary")]))

        // Other alone answers a question; blank other does not.
        var fresh = QuestionDraft(card: card)
        fresh.setOther("Plain text", for: 0)
        fresh.setOther("   ", for: 1)
        XCTAssertFalse(fresh.isComplete)
        fresh.toggle("Appendix", for: 1)
        XCTAssertTrue(fresh.isComplete)
    }

    // MARK: - form

    func testFormAnswersCollectFieldsByKind() {
        let fields = [
            FormField(key: "name", label: "Name", kind: .text, options: nil),
            FormField(key: "size", label: "Size", kind: .choice, options: ["small", "large"]),
            FormField(key: "urgent", label: "Urgent", kind: .toggle, options: nil),
        ]
        let card = CardAsk(chat: 4, id: "card-f", kind: .form, title: "Details", permission: nil, questions: nil, form: fields, seq: 3)

        var draft = FormDraft(card: card)
        XCTAssertEqual(draft.text(for: "name"), "")
        XCTAssertEqual(draft.choice(for: "size"), "small", "a choice starts on its first option")
        XCTAssertFalse(draft.toggle(for: "urgent"))
        XCTAssertFalse(draft.isComplete, "a text field must be filled")

        draft.setText("Report", for: "name")
        draft.setChoice("large", for: "size")
        draft.setToggle(true, for: "urgent")
        XCTAssertTrue(draft.isComplete)

        let answer = try! XCTUnwrap(draft.answer())
        XCTAssertEqual(answer.chat, 4)
        XCTAssertEqual(answer.id, "card-f")
        XCTAssertEqual(answer.answer, ["name": .string("Report"), "size": .string("large"), "urgent": .bool(true)])
    }

    // MARK: - status

    func testCardStatusPresentation() {
        XCTAssertNil(CardStatusPresentation(status: .open).label)
        XCTAssertEqual(CardStatusPresentation(status: .answered).label, "answered")
        XCTAssertEqual(CardStatusPresentation(status: .cancelled("nobody was there to answer")).label, "cancelled: nobody was there to answer")
        XCTAssertEqual(CardStatusPresentation(status: .cancelled("")).label, "cancelled")
        XCTAssertEqual(CardStatusPresentation(status: .open).icon, "rectangle.on.rectangle.angled")
        XCTAssertEqual(CardStatusPresentation(status: .answered).icon, "checkmark.circle")
        XCTAssertEqual(CardStatusPresentation(status: .cancelled("x")).icon, "xmark.circle")
    }
}
