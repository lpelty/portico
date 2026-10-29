import Foundation

/// What Read aloud says for a reply, and what the conversation draws of
/// the `[TTS]` markers (v0.9 decisions 2 and 3). Pure, so it is tested
/// without a window or a voice.
///
/// - With `[TTS]…[/TTS]` parts, only they are spoken, joined, in order. An
///   open marker with no close runs to the end (a reply still streaming,
///   or one whose agent forgot the close); a close with no open is dropped.
///   `[TTS: …]` is one part too; brackets inside it pair up, so a link in
///   it stays whole.
/// - Markers are markers only outside code: in a fenced block or an inline
///   code span they are the code's own text, drawn, copied and never a part.
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
    static let colonMarker = "[TTS:"

    /// The string to speak for a reply's Markdown; empty when there is
    /// nothing to say.
    static func speech(fromMarkdown markdown: String) -> String {
        let tokens = self.tokens(markdown)
        if let parts = markedParts(tokens) {
            let spoken = parts.map(prose).filter { !$0.isEmpty }
            // Markers around nothing: the reply's prose, rather than silence.
            if !spoken.isEmpty { return spoken.joined(separator: " ") }
        }
        return prose(displayed(tokens))
    }

    /// The reply as drawn (decision 3): the `[TTS]`, `[/TTS]` and `[TTS: …]`
    /// markers removed, the text inside them kept. Any case (`[tts]`).
    static func displayed(_ text: String) -> String {
        guard text.range(of: "tts", options: .caseInsensitive) != nil else { return text }
        return displayed(tokens(text))
    }

    /// The text of each part, markers removed, in order; nil when the reply
    /// has no open marker.
    static func markedParts(_ text: String) -> [String]? {
        markedParts(tokens(text))
    }

    // MARK: markers

    /// A reply read for markers: its text, and where parts open and close.
    enum Token: Equatable {
        case text(String)
        case open
        case close
    }

    static func tokens(_ text: String) -> [Token] {
        var scanner = MarkerScanner()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            scanner.read(line)
            if index < lines.count - 1 { scanner.append("\n") }
        }
        return scanner.finish()
    }

    private static func displayed(_ tokens: [Token]) -> String {
        tokens.map { token in
            if case .text(let text) = token { return text }
            return ""
        }.joined()
    }

    private static func markedParts(_ tokens: [Token]) -> [String]? {
        var parts: [String] = []
        var current: String?
        var found = false
        for token in tokens {
            switch token {
            case .open:
                found = true
                current = ""
            case .text(let text):
                current? += text
            case .close:
                if let part = current { parts.append(part) }
                current = nil
            }
        }
        if let current { parts.append(current) }
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

/// Reads a reply line by line for `[TTS]` markers, passing over fenced
/// blocks and inline code spans (a span ends on its line).
private struct MarkerScanner {
    private enum Part {
        case tags
        /// `[TTS: …]`, with the `[` opened inside it and not yet closed.
        case colon(depth: Int)
    }

    private var tokens: [SpeakableText.Token] = []
    private var buffer = ""
    private var fence: MarkdownParser.Fence?
    private var part: Part?

    mutating func append(_ text: some StringProtocol) {
        buffer += text
    }

    mutating func read(_ line: Substring) {
        if let open = fence {
            buffer += line
            if Self.closes(line, open) { fence = nil }
            return
        }
        // Any indent: a fence under a list item is code too.
        if let opened = MarkdownParser.fenceOpening(String(line), maxIndent: .max) {
            buffer += line
            fence = opened
            return
        }
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "`" {
                let run = line[index...].prefix { $0 == "`" }
                if let close = Self.closingRun(of: run.count, in: line[run.endIndex...]) {
                    buffer += line[index..<close]
                    index = close
                } else {
                    buffer += run
                    index = run.endIndex
                }
                continue
            }
            if character == "[", let next = marker(at: index, in: line) {
                index = next
                continue
            }
            if case .colon(let depth) = part {
                if character == "[" {
                    part = .colon(depth: depth + 1)
                } else if character == "]" {
                    if depth == 0 {
                        closeColon()
                        index = line.index(after: index)
                        continue
                    }
                    part = .colon(depth: depth - 1)
                }
            }
            buffer.append(character)
            index = line.index(after: index)
        }
    }

    mutating func finish() -> [SpeakableText.Token] {
        flush()
        return tokens
    }

    /// A marker at `index`: handled, and the index after it; nil when it is
    /// not one (or, for `[TTS:` inside a part, plain text).
    private mutating func marker(at index: Substring.Index, in line: Substring) -> Substring.Index? {
        let rest = line[index...]
        func starts(_ marker: String) -> Substring.Index? {
            guard rest.count >= marker.count else { return nil }
            let end = rest.index(rest.startIndex, offsetBy: marker.count)
            return rest[..<end].caseInsensitiveCompare(marker) == .orderedSame ? end : nil
        }
        if let end = starts(SpeakableText.openMarker) {
            // A nested open is dropped: the part goes on.
            if part == nil { open(.tags) }
            return end
        }
        if let end = starts(SpeakableText.closeMarker) {
            // Closes a tag part; dropped anywhere else.
            if case .tags = part {
                flush()
                tokens.append(.close)
                part = nil
            }
            return end
        }
        if part == nil, var end = starts(SpeakableText.colonMarker) {
            open(.colon(depth: 0))
            // The space after the colon is not part of the words.
            while end < line.endIndex, line[end] == " " || line[end] == "\t" { end = line.index(after: end) }
            return end
        }
        return nil
    }

    private mutating func open(_ kind: Part) {
        flush()
        tokens.append(.open)
        part = kind
    }

    /// The `]` closing `[TTS: …]`: the space before it is not part of the words.
    private mutating func closeColon() {
        while let last = buffer.last, last == " " || last == "\t" { buffer.removeLast() }
        flush()
        tokens.append(.close)
        part = nil
    }

    private mutating func flush() {
        guard !buffer.isEmpty else { return }
        tokens.append(.text(buffer))
        buffer = ""
    }

    /// The end of the next run of exactly `count` backticks in `text`.
    private static func closingRun(of count: Int, in text: Substring) -> Substring.Index? {
        var index = text.startIndex
        while let start = text[index...].firstIndex(of: "`") {
            let run = text[start...].prefix { $0 == "`" }
            if run.count == count { return run.endIndex }
            index = run.endIndex
        }
        return nil
    }

    /// Whether `line` closes the fence `fence` opened.
    private static func closes(_ line: Substring, _ fence: MarkdownParser.Fence) -> Bool {
        guard let first = fence.marker.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == first }
        return run.count >= fence.marker.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty
    }
}
