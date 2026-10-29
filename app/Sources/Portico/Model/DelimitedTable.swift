import AppKit
import Foundation

/// A CSV or TSV file read as a table: the first line is the header, every
/// line after it a row. Pure parsing, no views, so the viewer can do it off
/// the main thread and the tests can feed it strings.
///
/// Quoting follows RFC 4180: a field that starts with `"` runs to the next
/// lone `"`, and inside it the separator, line breaks and doubled quotes
/// (`""` for one `"`) are part of the field. A quote in the middle of an
/// unquoted field is just a character (`5" screen`), as spreadsheets write
/// it. TSV uses the same rules with a tab for the comma.
struct DelimitedTable: Equatable, Sendable {
    let header: [String]
    let rows: [[String]]
    /// True when the parse stopped at `rowLimit` and the file has more rows.
    let rowLimitHit: Bool
    /// One flag per column: every non-empty cell below the header is a
    /// number (currency signs, thousands separators and `%` allowed), and
    /// at least one is not empty. Numeric columns align right.
    let numeric: [Bool]

    var columnCount: Int { header.count }

    /// The most rows the viewer parses. Past this the table says so; it is
    /// a guard against absurd files, not a page size (rows draw lazily).
    static let defaultRowLimit = 200_000

    /// The separator a file's extension implies: tab for `.tsv` (and
    /// `.tab`), comma for `.csv`; `nil` for anything else.
    static func separator(forExtension ext: String) -> Character? {
        switch ext.lowercased() {
        case "csv": ","
        case "tsv", "tab": "\t"
        default: nil
        }
    }

    /// The table in `text`, or `nil` when it isn't one: nothing in it, a
    /// quote that never closes, text after a closing quote, or a row whose
    /// column count differs from the header's. The viewer shows such a file
    /// as plain text instead.
    ///
    /// A trailing line break, a byte-order mark and CRLF line ends are fine.
    static func parse(_ text: String, separator: Character, rowLimit: Int = defaultRowLimit) -> DelimitedTable? {
        // Works on UTF-8 bytes: the separator, quote and line breaks are all
        // ASCII, so they never appear inside a multi-byte character, and a
        // field is a byte slice made a String once (a 25 MB file parses in
        // about a second, where a scalar at a time took several).
        guard let sep = separator.asciiValue else { return nil }
        let quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var text = text
        return text.withUTF8 { all -> DelimitedTable? in
            var bytes = all[...]
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }

            var header: [String]?
            var rows: [[String]] = []
            var limitHit = false
            var record: [String] = []
            // Whether the record's last field was quoted: a lone `""` is a
            // real one-column row, an empty unquoted one a blank line.
            var lastQuoted = false
            // A quoted field's bytes, with doubled quotes made single.
            var quoted: [UInt8] = []

            /// Ends the current record. Returns false when its shape is wrong.
            func endRecord() -> Bool {
                defer { record = [] }
                if let header {
                    guard record.count == header.count else { return false }
                    rows.append(record)
                } else {
                    header = record
                }
                return true
            }

            var i = bytes.startIndex
            let end = bytes.endIndex
            while i < end {
                // At the start of a field.
                var field: String
                if bytes[i] == quote {
                    quoted.removeAll(keepingCapacity: true)
                    i += 1
                    var closedAt: Int?
                    while i < end {
                        let c = bytes[i]
                        if c == quote {
                            if i + 1 < end, bytes[i + 1] == quote {
                                quoted.append(quote)
                                i += 2
                                continue
                            }
                            closedAt = i
                            i += 1
                            break
                        }
                        quoted.append(c)
                        i += 1
                    }
                    guard closedAt != nil else { return nil }  // never closed
                    // Only the separator or a line end may follow.
                    if i < end, bytes[i] != sep, bytes[i] != lf, bytes[i] != cr { return nil }
                    field = String(decoding: quoted, as: UTF8.self)
                    lastQuoted = true
                } else {
                    lastQuoted = false
                    let start = i
                    while i < end, bytes[i] != sep, bytes[i] != lf, bytes[i] != cr { i += 1 }
                    field = String(decoding: bytes[start..<i], as: UTF8.self)
                }
                record.append(field)

                if i < end, bytes[i] == sep {
                    i += 1
                    // A separator at the very end leaves one empty field.
                    if i == end { record.append("") }
                    continue
                }
                // A line end, or the end of the text.
                if i < end {
                    if bytes[i] == cr, i + 1 < end, bytes[i + 1] == lf { i += 2 } else { i += 1 }
                }
                // A blank line is no row (a trailing one is common).
                if record.count == 1, record[0].isEmpty, !lastQuoted {
                    record = []
                } else {
                    guard endRecord() else { return nil }
                }
                // Skip blank lines here too, so the limit check below sees
                // whether real rows remain.
                while i < end, bytes[i] == lf || bytes[i] == cr { i += 1 }
                if rows.count >= rowLimit {
                    limitHit = i < end
                    break
                }
            }
            // A separator at the very end leaves a record open.
            if !record.isEmpty, !endRecord() { return nil }
            return finish(header: header, rows: rows, limitHit: limitHit)
        }
    }

    private static func finish(header: [String]?, rows: [[String]], limitHit: Bool) -> DelimitedTable? {
        guard let header, !header.isEmpty, !(header.count == 1 && header[0].isEmpty) else { return nil }
        let numeric = (0..<header.count).map { column in
            var any = false
            for row in rows {
                let cell = row[column]
                if cell.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                guard isNumber(cell) else { return false }
                any = true
            }
            return any
        }
        return DelimitedTable(header: header, rows: rows, rowLimitHit: limitHit, numeric: numeric)
    }

    /// Whether a cell reads as a number: `42`, `-3.5`, `1,200`, `$48,000`,
    /// `12%`, `(250)`, `1e6`. Letters, dates and versions (`1.2.3`) don't.
    static func isNumber(_ cell: String) -> Bool {
        // By hand over the bytes: every cell of a numeric column is checked,
        // and a big table has millions.
        var s = cell.utf8[...]
        let space: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 }
        while let first = s.first, space(first) { s = s.dropFirst() }
        while let last = s.last, space(last) { s = s.dropLast() }
        if s.first == UInt8(ascii: "("), s.last == UInt8(ascii: ")") { s = s.dropFirst().dropLast() }
        if let first = s.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") { s = s.dropFirst() }
        for symbol in ["$", "€", "£", "¥"] where s.starts(with: symbol.utf8) {
            s = s.dropFirst(symbol.utf8.count)
            break
        }
        if s.last == UInt8(ascii: "%") { s = s.dropLast() }

        var digits = 0, exponentDigits = 0
        var dot = false, exponent = false
        var previous: UInt8 = 0
        for c in s {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if exponent { exponentDigits += 1 } else { digits += 1 }
            case UInt8(ascii: ","), UInt8(ascii: "_"):
                // Thousands separators: between digits, before any point.
                guard digits > 0, !dot, !exponent else { return false }
            case UInt8(ascii: "."):
                guard !dot, !exponent else { return false }
                dot = true
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                guard digits > 0, !exponent else { return false }
                exponent = true
            case UInt8(ascii: "-"), UInt8(ascii: "+"):
                guard previous == UInt8(ascii: "e") || previous == UInt8(ascii: "E") else { return false }
            default:
                return false
            }
            previous = c
        }
        return digits > 0 && (!exponent || exponentDigits > 0)
    }

    // MARK: Column widths

    /// The size the table draws cells in (the header semibold).
    static let fontSize: CGFloat = 12
    /// How many rows below the header the widths are measured from: enough
    /// to be representative, few enough that a huge file opens at once.
    static let widthSampleRows = 200
    static let minColumnWidth: CGFloat = 60
    static let maxColumnWidth: CGFloat = 320
    /// Room on each side of a cell's text.
    static let cellPadding: CGFloat = 12

    /// Each column's width: its widest cell among the header and the first
    /// `widthSampleRows` rows, plus padding, kept between the minimum and
    /// maximum. Fixed widths let rows draw lazily and still line up; a cell
    /// wider than its column truncates.
    static func columnWidths(header: [String], rows: [[String]], sample: Int = widthSampleRows) -> [CGFloat] {
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize)]
        let headerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        return header.indices.map { column in
            var widest = (header[column] as NSString).size(withAttributes: headerAttributes).width
            for row in rows.prefix(sample) where column < row.count {
                // Only the first line of a cell shows.
                let line = row[column].prefix { $0 != "\n" && $0 != "\r" }
                widest = max(widest, (String(line) as NSString).size(withAttributes: cellAttributes).width)
                if widest >= maxColumnWidth { break }
            }
            return min(max(ceil(widest) + cellPadding * 2, minColumnWidth), maxColumnWidth)
        }
    }
}

// MARK: - Loading for the viewer

/// What the viewer's table pane shows for a `.csv` or `.tsv` file, worked
/// out off the main thread: the table with its column widths, or (when it
/// doesn't parse into a consistent shape) the file as text.
enum TableLoad: Sendable {
    case table(DelimitedTable, widths: [CGFloat], note: String?)
    case text(TextFileRead)
    case unreadable

    /// Reads at most `TextFileRead.tableLimit` bytes and `rowLimit` rows,
    /// and says so in `note` when either cuts the file short.
    static func load(_ file: URL, separator: Character, rowLimit: Int = DelimitedTable.defaultRowLimit) -> TableLoad {
        if let read = TextFileRead.read(file, limit: TextFileRead.tableLimit, wholeLines: true),
           let table = DelimitedTable.parse(read.text, separator: separator, rowLimit: rowLimit) {
            let widths = DelimitedTable.columnWidths(header: table.header, rows: table.rows)
            return .table(table, widths: widths, note: note(table: table, read: read))
        }
        guard let text = TextFileRead.read(file, limit: TextFileRead.textLimit) else { return .unreadable }
        return .text(text)
    }

    /// The line under a table cut short, or `nil` when it is all there.
    static func note(table: DelimitedTable, read: TextFileRead) -> String? {
        let rows = table.rows.count.formatted()
        if read.truncated {
            let size = ByteCountFormatter.string(fromByteCount: Int64(read.totalBytes), countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: Int64(TextFileRead.tableLimit), countStyle: .file)
            return "Showing \(rows) rows from the first \(limit) of \(size). Open it externally for the rest."
        }
        if table.rowLimitHit {
            return "Showing the first \(rows) rows; the file has more. Open it externally for the rest."
        }
        return nil
    }
}

// MARK: - Reading text files

/// The start of a text file, read for the viewer: at most `limit` bytes so
/// a huge log can't stall the app, decoded as UTF-8.
struct TextFileRead: Equatable, Sendable {
    let text: String
    /// The file's whole size in bytes.
    let totalBytes: Int
    /// True when only the first `limit` bytes were read.
    let truncated: Bool

    /// The text pane's cap: a megabyte is far more than anyone reads in a
    /// viewer and lays out in well under a second.
    static let textLimit = 1_000_000
    /// The table's cap: big enough for any table a person means to look at.
    static let tableLimit = 50_000_000

    /// The file's first `limit` bytes as UTF-8, or `nil` when it can't be
    /// read or isn't UTF-8. A cut that lands inside a multi-byte character
    /// backs off to the character before it. With `wholeLines`, a cut file
    /// also drops its last, partial line (a table parses whole rows only).
    static func read(_ url: URL, limit: Int, wholeLines: Bool = false) -> TextFileRead? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()).map(Int.init) ?? 0
        guard (try? handle.seek(toOffset: 0)) != nil else { return nil }
        var data = (try? handle.read(upToCount: limit)) ?? Data()
        let truncated = data.count < total
        if truncated && wholeLines, let lastBreak = data.lastIndex(of: 0x0A) {
            data = data.prefix(through: lastBreak)
        }
        var text = String(data: data, encoding: .utf8)
        if text == nil && truncated {
            // A UTF-8 character is at most four bytes: drop up to three.
            for drop in 1...3 where data.count > drop {
                if let shorter = String(data: data.dropLast(drop), encoding: .utf8) {
                    text = shorter
                    break
                }
            }
        }
        guard let text else { return nil }
        return TextFileRead(text: text, totalBytes: total, truncated: truncated)
    }
}
