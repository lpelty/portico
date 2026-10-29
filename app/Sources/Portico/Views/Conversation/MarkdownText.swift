import Foundation
import SwiftUI

// MARK: - Blocks (v0.4, W1)

/// One block of the agent's Markdown, as the conversation draws it.
indirect enum MarkdownBlock: Equatable, Sendable {
    /// Inline Markdown; line breaks inside it are kept.
    case paragraph(String)
    /// `#`–`###` (deeper heads draw as `###`), or text over `===` / `---`:
    /// a bold head a little larger than the body, not a document title.
    case heading(level: Int, text: String)
    /// A run of list items, bulleted or numbered, two levels deep.
    case list([MarkdownListItem])
    /// A fenced block; `closed` is false while the fence is still open
    /// (streaming), and what has come so far draws as code.
    case code(language: String?, text: String, closed: Bool)
    /// A block quote's contents, parsed as blocks of their own.
    case quote([MarkdownBlock])
    case rule
    /// A table: the header's cells and each row's (inline Markdown),
    /// every row as wide as the widest.
    case table(header: [String], rows: [[String]])
}

struct MarkdownListItem: Equatable, Sendable {
    /// 0 for the outer list, 1 for a nested one.
    var level: Int
    /// `1.` for a numbered item (its number as written), nil for a bullet.
    var number: String?
    var text: String
    /// What else the item holds, drawn under its text at its indent: a
    /// fence indented under it, and text after that or after a blank line.
    var blocks: [MarkdownBlock] = []
}

/// A small block splitter for the agent's answers: the block structure
/// is found here and each block's inline runs go to
/// `AttributedString(markdown:)`. No package dependency (design §2.1), and
/// pure, so it is tested without a window. Built for chat answers, not for
/// the whole of CommonMark: what it does not recognise stays a paragraph,
/// and partial input (a streaming answer) never fails.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownListItem] = []
        /// Each item's content indent (where its text starts), beside `items`.
        var contentIndents: [Int] = []
        var quote: [String] = []
        /// A blank line inside a list: the list goes on if an item follows.
        var blankInList = false

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)) }
            items = []
            contentIndents = []
            blankInList = false
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(parse(quote.joined(separator: "\n")))) }
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineIndent = indent(line)

            // A fence indented under a list item (up to three past where
            // the item's text starts) is that item's code: the list goes on.
            if let limit = contentIndents.last.map({ $0 + 3 }), lineIndent >= 1,
                let fence = fenceOpening(line, maxIndent: limit)
            {
                let read = readFence(lines, from: index + 1, fence: fence, stripIndent: lineIndent, closeIndent: limit)
                items[items.count - 1].blocks.append(read.block)
                blankInList = false
                index = read.next
                continue
            }

            // A fence: everything up to the closing fence, or to the end
            // while the answer is still streaming.
            if let fence = fenceOpening(line) {
                flushAll()
                let read = readFence(lines, from: index + 1, fence: fence, stripIndent: lineIndent, closeIndent: 3)
                blocks.append(read.block)
                index = read.next
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                if !items.isEmpty { blankInList = true }
                index += 1
                continue
            }

            if let heading = heading(line) {
                flushAll()
                blocks.append(heading)
                index += 1
                continue
            }

            // Text over `===` or `---` is a heading (CommonMark's setext),
            // not a paragraph and a rule.
            if !paragraph.isEmpty, let level = setextLevel(line) {
                blocks.append(.heading(level: level, text: paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")))
                paragraph = []
                index += 1
                continue
            }

            if isRule(line) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let table = table(lines, at: index) {
                flushAll()
                blocks.append(.table(header: table.header, rows: table.rows))
                index = table.next
                continue
            }

            // A numbered line interrupts a paragraph only when it starts at
            // 1: "Released in\n2024. It was good" is one paragraph.
            if let found = listItemAndIndent(line),
                paragraph.isEmpty || (found.item.number.flatMap { Int($0.dropLast()) } ?? 1) == 1
            {
                flushParagraph()
                flushQuote()
                blankInList = false
                items.append(found.item)
                contentIndents.append(found.contentIndent)
                index += 1
                continue
            }

            if let quoted = quoteLine(line) {
                flushParagraph()
                flushList()
                quote.append(quoted)
                index += 1
                continue
            }

            // Text under a list item (indented, or a lazy continuation)
            // belongs to that item. After a blank line only indented text
            // does, as a paragraph of its own; else the list has ended.
            if let contentIndent = contentIndents.last, !blankInList || lineIndent >= contentIndent {
                var item = items[items.count - 1]
                if blankInList {
                    item.blocks.append(.paragraph(trimmed))
                } else if case .paragraph(let text)? = item.blocks.last {
                    item.blocks[item.blocks.count - 1] = .paragraph(text + "\n" + trimmed)
                } else if !item.blocks.isEmpty {
                    item.blocks.append(.paragraph(trimmed))
                } else {
                    item.text += "\n" + trimmed
                }
                items[items.count - 1] = item
                blankInList = false
                index += 1
                continue
            }
            if !quote.isEmpty {
                quote.append(trimmed)
                index += 1
                continue
            }
            flushList()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    // MARK: recognisers

    /// Leading spaces (a tab counts four).
    private static func indent(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    /// The line without up to `columns` of its leading indent (CommonMark:
    /// a fence's own indent comes off each of its lines).
    private static func dropIndent(_ line: String, upTo columns: Int) -> String {
        var remaining = columns
        var rest = Substring(line)
        while remaining > 0, let first = rest.first {
            if first == " " {
                remaining -= 1
            } else if first == "\t" {
                remaining -= 4
            } else {
                break
            }
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    struct Fence: Equatable, Sendable {
        var marker: String
        var language: String?
    }

    static func fenceOpening(_ line: String, maxIndent: Int = 3) -> Fence? {
        guard indent(line) <= maxIndent else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            guard run.count >= 3 else { continue }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string has no backticks (else it is inline code).
            if character == "`" && info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return Fence(marker: String(run), language: language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    /// A fence's code from the line after it up to its closing fence (the
    /// end, unclosed, while streaming), `stripIndent` off each line, and
    /// the line after the block.
    private static func readFence(
        _ lines: [String], from start: Int, fence: Fence, stripIndent: Int, closeIndent: Int
    ) -> (block: MarkdownBlock, next: Int) {
        var body: [String] = []
        var index = start
        while index < lines.count {
            if isFenceClosing(lines[index], marker: fence.marker, maxIndent: closeIndent) {
                return (.code(language: fence.language, text: body.joined(separator: "\n"), closed: true), index + 1)
            }
            body.append(dropIndent(lines[index], upTo: stripIndent))
            index += 1
        }
        return (.code(language: fence.language, text: body.joined(separator: "\n"), closed: false), index)
    }

    private static func isFenceClosing(_ line: String, marker: String, maxIndent: Int) -> Bool {
        guard indent(line) <= maxIndent, let first = marker.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == first }
        return run.count >= marker.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        // A closing run of #s is not part of the text, when a space comes
        // before it (CommonMark): `## Why C#` keeps its #.
        var text = rest.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing == text.count {
            text = ""
        } else if closing > 0, text.dropLast(closing).last == " " {
            text = String(text.dropLast(closing))
        }
        return .heading(level: min(hashes, 3), text: text.trimmingCharacters(in: .whitespaces))
    }

    /// `===` (level 1) or `---` (level 2) under text. Three at least, so a
    /// streaming `-` that is about to be a list item is not a heading.
    static func setextLevel(_ line: String) -> Int? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, let first = trimmed.first, first == "=" || first == "-",
            trimmed.allSatisfy({ $0 == first })
        else { return nil }
        return first == "=" ? 1 : 2
    }

    static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
        listItemAndIndent(line)?.item
    }

    /// The item and its content indent: the column its text starts at.
    private static func listItemAndIndent(_ line: String) -> (item: MarkdownListItem, contentIndent: Int)? {
        let spaces = indent(line)
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        var number: String?
        var rest: Substring
        if let first = trimmed.first, "-*+".contains(first) {
            rest = trimmed.dropFirst()
        } else {
            let digits = trimmed.prefix { $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            let after = trimmed.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")" else { return nil }
            number = String(digits) + "."
            rest = after.dropFirst()
        }
        // The marker is followed by a space (or ends the line, an item
        // still being written).
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let marker = trimmed.count - rest.count
        let gap = rest.prefix { $0 == " " }.count
        let text = rest.trimmingCharacters(in: .whitespaces)
        // Five spaces or more after the marker: the text is indented code
        // in CommonMark, and the content starts one space in.
        let contentIndent = spaces + marker + (gap == 0 || gap > 4 || text.isEmpty ? 1 : gap)
        return (MarkdownListItem(level: spaces >= 2 ? 1 : 0, number: number, text: text), contentIndent)
    }

    static func quoteLine(_ line: String) -> String? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == ">" else { return nil }
        var rest = trimmed.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// A table starts at a row with pipes followed by its delimiter row
    /// (`| --- | :-: |`); it runs while lines have pipes. Returns the
    /// header's cells, each row's (as wide as the widest), and the line
    /// after it.
    static func table(_ lines: [String], at start: Int) -> (header: [String], rows: [[String]], next: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"), isDelimiterRow(lines[start + 1]) else { return nil }
        var rows: [[String]] = [cells(lines[start])]
        var index = start + 2
        while index < lines.count, lines[index].contains("|"),
            !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
        {
            rows.append(cells(lines[index]))
            index += 1
        }
        let columns = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        return (padded[0], Array(padded.dropFirst()), index)
    }

    /// `| --- | :-: |`: at least one pipe, and every cell `:?-+:?`.
    private static func isDelimiterRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let row = cells(line)
        guard !row.isEmpty else { return false }
        return row.allSatisfy { cell in
            var core = Substring(cell)
            if core.first == ":" { core = core.dropFirst() }
            if core.last == ":" { core = core.dropLast() }
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: inline

    /// A block's inline runs: bold, italic, `code`, links, strikethrough,
    /// whitespace and line breaks kept. Text that does not parse is shown
    /// as written.
    static func inline(_ text: String, codeBackground: Color? = nil) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        if let codeBackground {
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].backgroundColor = codeBackground
            }
        }
        return attributed
    }
}

// MARK: - The cache

/// Parsed blocks by text, the most recently used kept. A streaming answer
/// redraws the transcript on every delta; every other message's text is
/// unchanged, so it is parsed once, not once per delta. Keyed by the text
/// itself, so a hit is always right.
@MainActor
enum MarkdownCache {
    static let capacity = 200
    private static var entries: [String: [MarkdownBlock]] = [:]
    /// Least recently used first.
    private static var order: [String] = []
    /// How many times `blocks(for:)` has parsed (for the tests).
    private(set) static var parses = 0

    static func blocks(for text: String) -> [MarkdownBlock] {
        if let hit = entries[text] {
            if order.last != text, let at = order.lastIndex(of: text) {
                order.remove(at: at)
                order.append(text)
            }
            return hit
        }
        let blocks = MarkdownParser.parse(text)
        parses += 1
        entries[text] = blocks
        order.append(text)
        if order.count > capacity {
            entries[order.removeFirst()] = nil
        }
        return blocks
    }
}

// MARK: - The view

/// The agent's message as Markdown (W1). Each block is its own selectable
/// `Text`; links open in the default browser (the environment's
/// `openURL`). Parsed through `MarkdownCache`: on a streamed delta only the
/// message that changed is parsed again, and partial Markdown only ever
/// draws as what it is so far.
struct MarkdownText: View {
    let text: String

    static let bodySize: CGFloat = 13
    static let lineSpacing: CGFloat = 5

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownCache.blocks(for: text))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
    }
}

/// A run of blocks, one under the other: a message, a quote's contents,
/// or what a list item holds under its text.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                MarkdownBlockView(block: entry.element, first: entry.offset == 0)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let first: Bool

    private static let bodySize = MarkdownText.bodySize

    var body: some View {
        switch block {
        case .paragraph(let text):
            Self.inlineText(text)
        case .heading(let level, let text):
            Self.inlineText(text, font: .system(size: Self.bodySize + (level == 1 ? 3 : level == 2 ? 2 : 1), weight: .semibold))
                .padding(.top, first ? 0 : 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    listItem(entry.element)
                }
            }
        case .code(_, let text, _):
            codeBlock(text)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.borderStrong).frame(width: 3)
                MarkdownBlocksView(blocks: blocks, spacing: 8)
                    .foregroundStyle(Theme.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 4)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        }
    }

    /// `font` is applied here, not after: an outer `.font` loses to this one.
    static func inlineText(_ text: String, font: Font = .system(size: bodySize)) -> some View {
        Text(MarkdownParser.inline(text, codeBackground: Theme.surface))
            .font(font)
            .lineSpacing(MarkdownText.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listItem(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let number = item.number {
                    Text(number)
                        .font(.system(size: Self.bodySize).monospacedDigit())
                } else {
                    Text(item.level == 0 ? "•" : "◦")
                        .font(.system(size: Self.bodySize))
                }
            }
            .foregroundStyle(Theme.text3)
            .frame(minWidth: 10, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Self.inlineText(item.text)
                if !item.blocks.isEmpty {
                    MarkdownBlocksView(blocks: item.blocks, spacing: 8)
                }
            }
        }
        .padding(.leading, item.level == 0 ? 6 : 26)
    }

    /// Monospaced on the surface colour; a long line scrolls sideways.
    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    /// The columns lined up in a grid, each cell's inline Markdown drawn
    /// (bold, `code`), the header semibold over a line; a wide table
    /// scrolls sideways.
    private func table(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { cell in
                        tableCell(cell.element, weight: .semibold)
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                            tableCell(cell.element)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func tableCell(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(MarkdownParser.inline(text, codeBackground: Theme.border))
            .font(.system(size: 12, weight: weight))
            .fixedSize()
    }
}
