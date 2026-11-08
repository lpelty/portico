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
        /// How many times the text occurs in the block (or cell) before the selection (0-based).
        var occurrence: Int
        /// In a table: the cell's index in its row, the row (0 is the header,
        /// then the body rows), and which table in the block (`lines`) it is.
        var cell: Int? = nil
        var row: Int = 0
        var table: Int = 0
    }

    static let cellWords = "Select text within one cell."
    static let tableWidgetWords = "Click into the table to comment."

    /// The UTF-16 range of the selected text in `source`, snapped to words, or why it can't be anchored.
    static func locate(_ s: Selection, in source: String) -> Result<Range<Int>, CommentFormat.Refusal> {
        guard var block = lineRange(s.lines, in: source) else { return .failure(.notFound) }
        if let cell = s.cell {
            // Only that cell's source is searched (spec §13).
            let tables = CommentFormat.tables(source).filter { s.lines.contains($0.header) }
            guard s.table >= 0, s.table < tables.count else { return .failure(.notFound) }
            let t = tables[s.table]
            let line = s.row == 0 ? t.header : t.delimiter + s.row
            guard s.row >= 0, line <= t.last, let rowRange = lineRange(line...line, in: source) else { return .failure(.notFound) }
            let cells = CommentFormat.tableCells(source, line: rowRange)
            guard cell >= 0, cell < cells.count else { return .failure(.notFound) }
            block = cells[cell]
        }
        switch CommentFormat.findQuote(source, s.text, occurrence: s.occurrence + 1, within: block) {
        case .success(let r): return .success(r)
        case .failure(.occurs): return .failure(.notFound)
        case .failure(let f): return .failure(f)
        }
    }

    /// The words the Comment item's tooltip gives.
    static func reason(_ r: CommentFormat.Refusal) -> String {
        switch r {
        case .notFound, .occurs, .crossesBlocks, .insideAtom: "Select text within one paragraph, outside links and formatting."
        case .notShown: "That text isn't shown in the table."
        case .insideIgnored: "Comments can't go in code or front matter."
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
