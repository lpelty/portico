import SwiftUI

/// How an `AskUserQuestion` row reads in the transcript (v0.16 §3.1,
/// Ruling 12): "Asking a question" while the card is up, then one line of
/// what became of it. View-free so it can be tested.
enum QuestionRecord {
    /// The engine's question tool; its row is drawn as this record.
    static let tool = "AskUserQuestion"
    static let asking = "Asking a question"
    static let notAnswered = "Not answered"

    /// Whether a tool row is a question's, drawn as the record.
    static func isRecord(_ row: ToolRow) -> Bool {
        row.tool == tool
    }

    /// The question texts in the tool's input, in order.
    static func questions(in input: [String: JSONValue]) -> [String] {
        guard case .array(let list)? = input["questions"] else { return [] }
        return list.compactMap { $0["question"]?.stringValue }
    }

    /// "Asking a question" until the row finishes; then "Asked: <question>
    /// · Plain" (a multi-select's labels joined), or "Asked 2 questions ·
    /// Plain, Short" (answers in question order, skipped ones left out).
    /// A decline, or a cancel, reads "· Not answered". A row that finished
    /// well with no answers is a session from before v0.16 (Ruling 1): the
    /// question alone. `ok` is the row's; unknown reads as not answered.
    static func line(input: [String: JSONValue], answers: [String: QuestionAnswer]?, finished: Bool, ok: Bool? = nil) -> String {
        guard finished else { return asking }
        let asked = questions(in: input)
        let chosen = asked.flatMap { answers?[$0]?.labels ?? [] }.map(shown)
        let head = asked.count > 1 ? "Asked \(asked.count) questions" : asked.first.map { "Asked: \($0)" } ?? "Asked a question"
        if !chosen.isEmpty { return "\(head) · \(chosen.joined(separator: ", "))" }
        return ok == true && (answers ?? [:]).isEmpty ? head : "\(head) · \(notAnswered)"
    }

    /// A label as the record shows it: without a trailing "(Recommended)"
    /// (fix round 1). The answer the agent got keeps the label as written.
    static func shown(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let suffix = "(Recommended)"
        guard trimmed.hasSuffix(suffix) else { return label }
        let bare = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? label : bare
    }

    static func line(for row: ToolRow) -> String {
        line(input: row.input, answers: row.answers, finished: row.finished, ok: row.ok)
    }

    /// An answered question as the person's reply (v0.16 §9.4): one pair
    /// per answered question, in question order; a skipped one has none.
    /// `nil` while asking and for a decline (no answers): those keep the
    /// pill and the one-line record. A chosen option's label loses its
    /// "(Recommended)"; typed "Something else" text, not one of the
    /// question's options, is shown in full.
    static func answerPairs(input: [String: JSONValue], answers: [String: QuestionAnswer]?, finished: Bool) -> [AnswerPair]? {
        guard finished, let answers, !answers.isEmpty else { return nil }
        let pairs = questionsWithOptions(in: input).compactMap { question, options -> AnswerPair? in
            guard let labels = answers[question]?.labels, !labels.isEmpty else { return nil }
            let shownLabels = labels.map { options.contains($0) ? shown($0) : $0 }
            return AnswerPair(question: question, answer: shownLabels.joined(separator: ", "))
        }
        return pairs.isEmpty ? nil : pairs
    }

    static func answerPairs(for row: ToolRow) -> [AnswerPair]? {
        answerPairs(input: row.input, answers: row.answers, finished: row.finished)
    }

    /// Each question's text with its options' labels.
    private static func questionsWithOptions(in input: [String: JSONValue]) -> [(String, Set<String>)] {
        guard case .array(let list)? = input["questions"] else { return [] }
        return list.compactMap { item in
            guard let question = item["question"]?.stringValue else { return nil }
            var labels: Set<String> = []
            if case .array(let options)? = item["options"] {
                for option in options { if let label = option["label"]?.stringValue { labels.insert(label) } }
            }
            return (question, labels)
        }
    }
}

/// One answered question in the answer bubble: "Answer to: <question>"
/// over what was chosen or typed.
struct AnswerPair: Equatable {
    let question: String
    let answer: String

    var header: String { "Answer to: \(question)" }
}

/// The question's place in the transcript (v0.16 §3.1): a small amber
/// pill, "Asking a question", while the card is docked; once answered (or
/// declined) a one-line record of it in place of an ordinary tool row,
/// live and after a restart (the gateway replays the row's answers).
struct QuestionRecordView: View {
    let row: ToolRow

    var body: some View {
        if row.finished {
            record
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.wait)
                .frame(width: 8, height: 8)
            Text(QuestionRecord.asking)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Theme.wait)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.waitSoft, in: Capsule())
                .overlay(Capsule().stroke(Theme.wait.opacity(0.6), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
        .help("Answer in the card above the composer, or reply directly")
    }

    private var record: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(Theme.iconFont(12))
                .foregroundStyle(Theme.text2)
            Text(QuestionRecord.line(for: row))
                .scaledFont(13)
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .help(QuestionRecord.line(for: row))
    }
}

/// An answered question drawn as the person's reply (v0.16 §9.4): a
/// right-aligned bubble like a sent message, each answered question's
/// small "Answer to: <question>" header (one line, cut in the middle)
/// over the chosen label or the typed text. Rebuilt after a restart from
/// the row's recorded answers.
struct AnswerBubble: View {
    let pairs: [AnswerPair]
    /// The bubble's widest (`ConversationColumn.bubbleMaxWidth`).
    var maxWidth: CGFloat = UserBubble.fallbackMaxWidth

    /// What VoiceOver reads for one answer; the question is its hint.
    static func spokenLabel(_ pair: AnswerPair) -> String { "Your answer: \(pair.answer)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.header)
                        .scaledFont(11, weight: .medium)
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pair.question)
                    Text(pair.answer)
                        .scaledFont(MarkdownText.bodySize)
                        .lineSpacing(MarkdownText.lineSpacing)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AnswerBubble.spokenLabel(pair))
                .accessibilityHint(pair.question)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
