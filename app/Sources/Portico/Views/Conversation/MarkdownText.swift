import Foundation
import SwiftUI

// MARK: - Blocks (v0.4, W1)

/// One block of the agent's Markdown, as the conversation draws it.
enum MarkdownBlock: Equatable, Sendable {
    /// Inline Markdown; line breaks inside it are kept.
    case paragraph(String)
    /// `#`–`###` (deeper heads draw as `###`): a bold head a little larger
    /// than the body, not a document title.
    case heading(level: Int, text: String)
    /// A run of list items, bulleted or numbered, two levels deep.
    case list([MarkdownListItem])
    /// A fenced block; `closed` is false while the fence is still open
    /// (streaming), and what has come so far draws as code.
    case code(language: String?, text: String, closed: Bool)
    /// A block quote's text (inline Markdown).
    case quote(String)
    case rule
    /// A table, drawn as a monospaced block with its columns lined up.
    case table(String)
}

struct MarkdownListItem: Equatable, Sendable {
    /// 0 for the outer list, 1 for a nested one.
    var level: Int
    /// `1.` for a numbered item (its number as written), nil for a bullet.
    var number: String?
    var text: String
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
            blankInList = false
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
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

            // A fence: everything up to the closing fence, or to the end
            // while the answer is still streaming.
            if let fence = fenceOpening(line) {
                flushAll()
                var body: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if isFenceClosing(lines[index], marker: fence.marker) {
                        closed = true
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n"), closed: closed))
                index += 1
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

            if isRule(line) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let table = table(lines, at: index) {
                flushAll()
                blocks.append(.table(table.text))
                index = table.next
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                blankInList = false
                items.append(item)
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
            // belongs to that item, unless a blank line ended the list.
            if !items.isEmpty && !blankInList {
                items[items.count - 1].text += "\n" + trimmed
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

    static func fenceOpening(_ line: String) -> (marker: String, language: String?)? {
        guard indent(line) <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            guard run.count >= 3 else { continue }
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            // A backtick fence's info string has no backticks (else it is inline code).
            if character == "`" && info.contains("`") { return nil }
            let language = info.split(separator: " ").first.map(String.init)
            return (String(run), language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    private static func isFenceClosing(_ line: String, marker: String) -> Bool {
        guard indent(line) <= 3, let first = marker.first else { return false }
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
        // A closing run of #s is not part of the text.
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: min(hashes, 3), text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let compact = line.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listItem(_ line: String) -> MarkdownListItem? {
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
        let text = rest.trimmingCharacters(in: .whitespaces)
        return MarkdownListItem(level: spaces >= 2 ? 1 : 0, number: number, text: text)
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
    /// table drawn with its columns lined up, and the line after it.
    static func table(_ lines: [String], at start: Int) -> (text: String, next: Int)? {
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
        var widths = Array(repeating: 0, count: columns)
        for row in rows {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.count) }
        }
        func render(_ row: [String]) -> String {
            (0..<columns).map { column in
                let cell = column < row.count ? row[column] : ""
                return cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }
            .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        let rule = widths.map { String(repeating: "─", count: max($0, 1)) }.joined(separator: "  ")
        let text = ([render(rows[0]), rule] + rows.dropFirst().map(render)).joined(separator: "\n")
        return (text, index)
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let row = cells(line)
        guard !row.isEmpty, line.contains("-") else { return false }
        return row.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
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

// MARK: - The view

/// The agent's message as Markdown (W1). Each block is its own selectable
/// `Text`; links open in the default browser (the environment's
/// `openURL`). Re-parsed on every streamed delta: an answer is short, and
/// partial Markdown only ever draws as what it is so far.
struct MarkdownText: View {
    let text: String

    static let bodySize: CGFloat = 13
    static let lineSpacing: CGFloat = 5

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                block(entry.element, first: entry.offset == 0)
            }
        }
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
        case .heading(let level, let text):
            inlineText(text, font: .system(size: Self.bodySize + (level == 1 ? 3 : level == 2 ? 2 : 1), weight: .semibold))
                .padding(.top, first ? 0 : 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { entry in
                    listItem(entry.element)
                }
            }
        case .code(_, let text, _):
            codeBlock(text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.borderStrong).frame(width: 3)
                inlineText(text)
                    .foregroundStyle(Theme.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1)
                .padding(.vertical, 4)
        case .table(let text):
            codeBlock(text)
        }
    }

    /// `font` is applied here, not after: an outer `.font` loses to this one.
    private func inlineText(_ text: String, font: Font = .system(size: bodySize)) -> some View {
        Text(MarkdownParser.inline(text, codeBackground: Theme.surface))
            .font(font)
            .lineSpacing(Self.lineSpacing)
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
            inlineText(item.text)
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
}
