import Foundation

// MARK: - CommentAnchoring (v0.23)

/// Anchoring a selection made in the rendered page. The page tags each
/// top-level block with its source lines (`data-lines`) and reports the
/// selected text and which occurrence of it in the block it is; the
/// Markdown source is the truth, and the text is searched for verbatim in
/// that block's source (markers invisible, `>` prefixes and whitespace runs
/// as one space, comment format v1's rules).
enum CommentAnchoring {
    struct Selection: Equatable, Sendable {
        var text: String
        /// 0-based source lines of the block the selection is in.
        var lines: ClosedRange<Int>
        /// How many times the text occurs in the block before the selection (0-based).
        var occurrence: Int
    }

    /// The UTF-16 range of the selected text in `source`, snapped to words, or why it can't be anchored.
    static func locate(_ s: Selection, in source: String) -> Result<Range<Int>, CommentFormat.Refusal> {
        guard let block = lineRange(s.lines, in: source) else { return .failure(.notFound) }
        switch CommentFormat.findQuote(source, s.text, occurrence: s.occurrence + 1, within: block) {
        case .success(let r): return .success(r)
        case .failure(.occurs): return .failure(.notFound)
        case .failure(let f): return .failure(f)
        }
    }

    /// The words the Comment item's tooltip gives.
    static func reason(_ r: CommentFormat.Refusal) -> String {
        switch r {
        case .notFound, .occurs, .crossesBlocks: "Select text within one paragraph, outside links and formatting."
        case .insideIgnored: "Comments can't go in code, tables or front matter."
        }
    }

    /// The UTF-16 range from the start of line `lines.lowerBound` through the end of line `lines.upperBound`.
    static func lineRange(_ lines: ClosedRange<Int>, in source: String) -> Range<Int>? {
        var line = 0
        var start: Int? = lines.lowerBound == 0 ? 0 : nil
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 10 {
                if line == lines.upperBound { return (start ?? 0)..<offset }
                line += 1
                if line == lines.lowerBound { start = offset }
            }
        }
        guard let start else { return nil }
        return start..<offset
    }
}
