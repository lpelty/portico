import Foundation

/// What Read aloud says for a reply, and what the conversation draws of
/// the `[TTS]` markers (v0.9 decisions 2 and 3). Pure, so it is tested
/// without a window or a voice.
///
/// - With `[TTS]…[/TTS]` parts, only they are spoken, joined, in order. An
///   open marker with no close runs to the end (a reply still streaming,
///   or one whose agent forgot the close); a close with no open is dropped.
/// - Otherwise the prose is spoken. Code is never read aloud: each fenced
///   block is "See the code below.", each table "See the table below."
///   (one pointer for a run of the same kind). Links speak their text,
///   inline code its text; heads and list items end as sentences so the
///   voice pauses after them.
///
/// The prose/code split is `MarkdownRun.split`, the one that drives Copy and
/// selection (decision 2), over `MarkdownParser`'s blocks.
enum SpeakableText {
    static let codePointer = "See the code below."
    static let tablePointer = "See the table below."

    static let openMarker = "[TTS]"
    static let closeMarker = "[/TTS]"

    /// The string to speak for a reply's Markdown; empty when there is
    /// nothing to say.
    static func speech(fromMarkdown markdown: String) -> String {
        let markdown = expandingColonForm(markdown)
        if let parts = markedParts(markdown) {
            let spoken = parts.map { prose(displayed($0)) }.filter { !$0.isEmpty }
            // Markers around nothing: the reply's prose, rather than silence.
            if !spoken.isEmpty { return spoken.joined(separator: " ") }
        }
        return prose(displayed(markdown))
    }

    /// The reply as drawn (decision 3): the `[TTS]` and `[/TTS]` tags
    /// removed, the text inside them kept. Any case (`[tts]`).
    static func displayed(_ text: String) -> String {
        guard text.range(of: "tts", options: .caseInsensitive) != nil else { return text }
        var out = expandingColonForm(text)
        for marker in [openMarker, closeMarker] {
            out = out.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        return out
    }

    /// `[TTS: words]`, the shorthand other agents already write, as
    /// `[TTS]words[/TTS]`: the part runs to the first `]` after the colon,
    /// and the space after the colon is dropped. Any case.
    static func expandingColonForm(_ text: String) -> String {
        guard text.range(of: "[tts:", options: .caseInsensitive) != nil else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return colonForm.stringByReplacingMatches(in: text, range: range, withTemplate: "\(openMarker)$1\(closeMarker)")
    }

    private static let colonForm = try! NSRegularExpression(pattern: #"\[TTS:[ \t]*([^\]]*?)[ \t]*\]"#, options: [.caseInsensitive])

    /// The text inside each `[TTS]…[/TTS]`, in order; nil when the reply
    /// has no open marker.
    static func markedParts(_ text: String) -> [String]? {
        var parts: [String] = []
        var rest = text[...]
        var found = false
        while let open = rest.range(of: openMarker, options: .caseInsensitive) {
            found = true
            let inside = rest[open.upperBound...]
            if let close = inside.range(of: closeMarker, options: .caseInsensitive) {
                parts.append(String(inside[..<close.lowerBound]))
                rest = inside[close.upperBound...]
            } else {
                parts.append(String(inside))
                break
            }
        }
        return found ? parts : nil
    }

    // MARK: prose

    /// Markdown as sentences: one string, pieces joined by a space.
    static func prose(_ markdown: String) -> String {
        var pieces: [String] = []
        for piece in self.pieces(MarkdownParser.parse(markdown)) where !piece.isEmpty {
            // A pointer straight after the same pointer says nothing new.
            if isPointer(piece), pieces.last == piece { continue }
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }

    private static func pieces(_ blocks: [MarkdownBlock]) -> [String] {
        MarkdownRun.split(blocks).flatMap { run -> [String] in
            switch run {
            case .prose(let blocks, _): blocks.flatMap(pieces(of:))
            case .block(let block, _): pieces(of: block)
            }
        }
    }

    private static func pieces(of block: MarkdownBlock) -> [String] {
        switch block {
        case .paragraph(let text):
            [plain(text)]
        case .heading(_, let text):
            [sentence(plain(text))]
        case .list(let items):
            // Nested items follow their parent, each its own sentence.
            items.flatMap { [sentence(plain($0.text))] + pieces($0.blocks) }
        case .code:
            [codePointer]
        case .table:
            [tablePointer]
        case .quote(let blocks):
            pieces(blocks)
        case .rule:
            []
        }
    }

    private static func isPointer(_ piece: String) -> Bool {
        piece == codePointer || piece == tablePointer
    }

    /// Inline Markdown as the words it shows: emphasis dropped, a link's
    /// text, inline code's text; line breaks and runs of space as one space.
    static func plain(_ inline: String) -> String {
        let shown = String(MarkdownParser.inline(inline).characters)
        return shown.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2028}" }).joined(separator: " ")
    }

    /// The text ending as a sentence, so the voice pauses after a head or
    /// a list item; text that already ends in punctuation is left alone.
    static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?:;…".contains(last) ? text : text + "."
    }
}
