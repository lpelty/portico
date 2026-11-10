import Foundation

/// One transcript entry's shape: its id, its kind and the sizes that decide
/// the height of its row, never its words, paths or names (D4). The recorder
/// writes these as JSON Lines; the synthetic conversation renders stand-in
/// text from them.
struct EntryShape: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case person, reply, tool, toolRun, card, turnMarker, compacted, notice, agents, signin, brief, divider
    }

    var id: String
    var kind: Kind
    /// Character count per paragraph, in order.
    var paragraphs: [Int] = []
    /// Levels.
    var headings: [Int] = []
    var listItems: Int = 0
    /// Line counts.
    var codeBlocks: [Int] = []
    /// `[rows, columns]` per table (rows exclude the header).
    var tables: [[Int]] = []
    var quotes: Int = 0
    var rules: Int = 0
    /// `[width, height]` in pixels per image attachment; `[0, 0]` when unreadable.
    var images: [[Int]] = []
    /// Attachments that are not images.
    var documents: Int = 0
    /// Rows in a tool run.
    var toolRows: Int = 0
    var folded: Bool = false
}

enum Shape {
    /// `imageSize` reads an image's pixel size from its path (`nil` when it
    /// cannot); it is a parameter so tests need no files.
    static func of(_ entry: TranscriptEntry, imageSize: (String) -> [Int]?) -> EntryShape {
        switch entry {
        case .toolRun(_, let rows):
            // A run draws folded until the person opens it, whatever its kind.
            return EntryShape(id: entry.id, kind: .toolRun, toolRows: rows.count, folded: true)
        case .item(let item):
            return shape(of: item, id: entry.id, imageSize: imageSize)
        }
    }

    private static func shape(of item: TranscriptItem, id: String, imageSize: (String) -> [Int]?) -> EntryShape {
        switch item {
        case .userText(let user):
            var shape = EntryShape(id: id, kind: .person)
            // The plain bubble, not Markdown: paragraphs split on blank lines.
            shape.paragraphs = plainParagraphs(user.text)
            let split = Attachment.split(user.attachments ?? [])
            shape.images = split.images.map { imageSize($0) ?? [0, 0] }
            shape.documents = split.files.count
            return shape
        case .assistantText(_, let text, _):
            var shape = EntryShape(id: id, kind: .reply)
            count(MarkdownParser.parse(text), into: &shape)
            return shape
        case .tool:
            return EntryShape(id: id, kind: .tool, toolRows: 1, folded: true)
        case .card: return EntryShape(id: id, kind: .card)
        case .turnMarker: return EntryShape(id: id, kind: .turnMarker)
        case .compacted: return EntryShape(id: id, kind: .compacted)
        case .notice: return EntryShape(id: id, kind: .notice)
        case .agents: return EntryShape(id: id, kind: .agents)
        case .signinContinued: return EntryShape(id: id, kind: .signin)
        }
    }

    private static func plainParagraphs(_ text: String) -> [Int] {
        var out: [Int] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { out.append(current.joined(separator: "\n").count) }
            current = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return out
    }

    private static func count(_ blocks: [MarkdownBlock], into shape: inout EntryShape) {
        for block in blocks {
            switch block {
            case .paragraph(let text): shape.paragraphs.append(text.count)
            case .heading(let level, _): shape.headings.append(level)
            case .list(let items):
                shape.listItems += items.count
                for item in items { count(item.blocks, into: &shape) }
            case .code(_, let text, _):
                shape.codeBlocks.append(text.isEmpty ? 0 : text.components(separatedBy: "\n").count)
            case .quote(let inner):
                shape.quotes += 1
                count(inner, into: &shape)
            case .rule: shape.rules += 1
            case .table(let header, let rows): shape.tables.append([rows.count, header.count])
            }
        }
    }
}
