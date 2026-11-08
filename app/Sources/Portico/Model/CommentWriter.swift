import Foundation

// MARK: - CommentWriter (v0.23)

/// A comment action in reading mode: read the file, apply the splice, and
/// save it atomically with the stamp the read saw. If the file changed in
/// between, it is read and the action applied once more; a second change
/// throws and nothing is written, so another writer's change is never lost.
enum CommentWriter {
    enum Op: Equatable {
        case add(CommentAnchoring.Selection, body: String)
        case reply(id: String, body: String)
        case setStatus(id: String, resolved: Bool)
        /// Edit mode: a new thread on a UTF-16 range of the buffer.
        case addRange(Range<Int>, body: String)
        /// Reading mode: a new thread where the draft was made (`range`, whose text was `quote`);
        /// if the text there changed, found again by its quote, once and only once, else `Stale`.
        case addAt(Range<Int>, quote: String, body: String)
        /// Replace comment `index`'s text (0 is the thread's first).
        case edit(id: String, index: Int, body: String)
        /// Delete reply `index`, or with 0 the whole thread.
        case delete(id: String, index: Int)
    }

    /// The text a draft was made on is no longer where it was, and isn't in the file exactly once.
    struct Stale: Error, Equatable {}

    /// The ID a new thread was given.
    final class Made {
        var id: String?
        init() {}
    }

    static func apply(_ edit: (String) throws -> String, to url: URL) throws {
        for attempt in 0..<2 {
            let read = try FileEditing.read(url)
            let text = try edit(read.text)
            do {
                try FileEditing.write(text, to: url, preserving: read.stamp, byteOrderMark: read.byteOrderMark)
                return
            } catch FileEditing.Failure.changedOnDisk where attempt == 0 {
                continue
            }
        }
    }

    /// The splice for `op`, applied to whatever text it is given (an `add`
    /// finds its selection again in that text).
    static func edit(
        for op: Op, author: String, now: Date, made: Made? = nil,
        newID: @escaping (String) -> String = { text in
            var rng = SystemRandomNumberGenerator()
            return CommentFormat.newID(in: text, using: &rng)
        }
    ) -> (String) throws -> String {
        let at = CommentFormat.timestamp(now)
        return { text in
            switch op {
            case .add(let selection, let body):
                let range = try CommentAnchoring.locate(selection, in: text).get()
                let id = newID(text)
                made?.id = id
                return CommentFormat.addThread(text, range: range, id: id, author: author, at: at, body: body)
            case .reply(let id, let body):
                return try CommentFormat.addReply(text, threadID: id, author: author, at: at, body: body)
            case .setStatus(let id, let resolved):
                return try CommentFormat.setStatus(text, threadID: id, resolved ? .resolved : .open)
            case .edit(let id, let index, let body):
                return try CommentFormat.editComment(text, threadID: id, index: index, body: body)
            case .delete(let id, let index):
                return try CommentFormat.deleteComment(text, threadID: id, index: index)
            case .addAt(let stored, let quote, let body):
                let units = Array(text.utf16)
                var range: Range<Int>? = nil
                if stored.upperBound <= units.count,
                    CommentFormat.quoteText(String(decoding: units[stored], as: UTF16.self)) == quote
                {
                    range = stored
                } else if case .success(let found) = CommentFormat.findQuote(text, quote, occurrence: 1),
                    case .failure = CommentFormat.findQuote(text, quote, occurrence: 2)
                {
                    range = found
                }
                guard let range else { throw Stale() }
                let id = newID(text)
                made?.id = id
                return CommentFormat.addThread(text, range: range, id: id, author: author, at: at, body: body)
            case .addRange(let raw, let body):
                let length = text.utf16.count
                guard raw.lowerBound >= 0, raw.upperBound <= length, !raw.isEmpty else { throw CommentFormat.Refusal.notFound }
                let range = CommentFormat.snapSelection(text, raw)
                if CommentFormat.ignoredRegions(text).contains(where: { $0.overlaps(range) }) {
                    throw CommentFormat.Refusal.insideIgnored
                }
                let units = Array(text.utf16)[range]
                if String(decoding: units, as: UTF16.self).range(of: #"\n[ \t>]*\r?\n"#, options: .regularExpression) != nil {
                    throw CommentFormat.Refusal.crossesBlocks
                }
                let id = newID(text)
                made?.id = id
                return CommentFormat.addThread(text, range: range, id: id, author: author, at: at, body: body)
            }
        }
    }
}

// MARK: - TextSplice

/// The smallest change from one text to another: the common prefix and
/// suffix kept, in UTF-16 offsets, never splitting a surrogate pair.
enum TextSplice {
    static func minimal(_ old: String, _ new: String) -> (from: Int, to: Int, insert: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        if p > 0, p < a.count || p < b.count, UTF16.isLeadSurrogate(a[min(p, a.count) - 1]) { p -= 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if s > 0, a.count - s < a.count, UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
        let insert = String(decoding: b[p..<(b.count - s)], as: UTF16.self)
        return (p, a.count - s, insert)
    }
}
