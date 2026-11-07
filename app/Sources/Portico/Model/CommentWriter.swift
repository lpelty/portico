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
    }

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
            }
        }
    }
}
