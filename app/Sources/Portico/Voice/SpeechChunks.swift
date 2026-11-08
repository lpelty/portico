import Foundation

/// v0.26 (PORT-23): a reply cut into pieces ElevenLabs takes in one request,
/// played in order. Paragraphs (split at blank lines) are packed together
/// while a chunk stays within `limit`; a paragraph over the limit is split at
/// sentence ends, then at the last whitespace before the limit, then hard.
enum SpeechChunks {
    static func split(_ text: String, limit: Int) -> [String] {
        let limit = max(1, limit)
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if paragraph.count > limit {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks += splitLong(paragraph, limit: limit)
            } else if current.isEmpty {
                current = paragraph
            } else if current.count + 2 + paragraph.count <= limit {
                current += "\n\n" + paragraph
            } else {
                chunks.append(current)
                current = paragraph
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One paragraph over the limit: sentences packed with a space, a sentence
    /// over the limit cut at words, a word over the limit cut hard.
    private static func splitLong(_ paragraph: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { out.append(current); current = "" } }
        for sentence in sentences(paragraph) {
            if sentence.count > limit {
                flush()
                out += splitWords(sentence, limit: limit)
            } else if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= limit {
                current += " " + sentence
            } else {
                flush()
                current = sentence
            }
        }
        flush()
        return out
    }

    /// Sentences: cut after ". ", "! " or "? " (the punctuation kept, the space dropped).
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var previous: Character?
        for c in text {
            if c.isWhitespace, let p = previous, ".!?".contains(p) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            } else {
                current.append(c)
            }
            previous = c
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    /// At the last whitespace before the limit, else hard at the limit.
    private static func splitWords(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit + 1)
            if let space = window.lastIndex(where: \.isWhitespace), space > rest.startIndex {
                out.append(String(rest[..<space]).trimmingCharacters(in: .whitespacesAndNewlines))
                rest = rest[rest.index(after: space)...].drop(while: \.isWhitespace)
            } else {
                let cut = rest.index(rest.startIndex, offsetBy: limit)
                out.append(String(rest[..<cut]))
                rest = rest[cut...].drop(while: \.isWhitespace)
            }
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }
}
