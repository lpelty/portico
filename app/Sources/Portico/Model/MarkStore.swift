import Foundation

/// Where a mark sits on its page: the path the page script wrote, the
/// element's tag and its visible text, so the mark can be found again.
struct MarkLocator: Codable, Equatable, Sendable {
    var path: String
    var tag: String
    var text: String
}

/// A page marks belong to. The key is a file path or a URL without its
/// fragment; the name is what the list shows. A page is its key alone:
/// the name can differ by how the page was reached (a space's title while
/// the space is open, the file's name otherwise), so it takes no part in
/// equality, and the store keeps the name it first saw for a key.
struct MarkPage: Equatable, Hashable, Sendable {
    var key: String
    var name: String

    static func == (lhs: MarkPage, rhs: MarkPage) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct Mark: Equatable, Identifiable, Sendable {
    var number: Int
    var page: MarkPage
    var note: String
    var label: String
    var locator: MarkLocator
    var found: Bool = true
    var call: String

    var id: Int { number }
}

/// One `viewer_mark` call's marks, kept so the chat's Mark row can name
/// them and "Show again" can open their page.
struct MarkCall: Equatable, Sendable {
    var id: String
    var toolUseId: String?
    var marks: [Mark]
}

/// The marks the agent has drawn, kept with their page (v0.26.5): a page's
/// marks are that page's in every chat and session, numbered from 1 on
/// each page, and written to `marks.json` in the app's home so they are
/// there after a restart. A page's marks can be hidden without being lost.
@MainActor
final class MarkStore: ObservableObject {
    nonisolated static let capability = "viewer.marks.v1"
    nonisolated static let noteLimit = 60
    nonisolated static let perCall = 9
    nonisolated static let fileName = "marks.json"

    enum ChipForm { case full, short, count }

    /// Marks by page key.
    @Published private(set) var marks: [String: [Mark]] = [:]
    /// The keys of the pages whose marks are hidden.
    @Published private(set) var hidden: Set<String> = []
    /// Call records by chat, for the Mark rows of this run of the app.
    private var calls: [Int: [MarkCall]] = [:]
    /// The page the viewer shows, as the viewer's agent last read it; the
    /// chip and its list are about this page alone.
    @Published var current: MarkPage?
    /// Where the marks are kept; `nil` keeps them in memory only.
    private var file: URL?

    /// A note over the limit is cut to one character fewer, plus "…".
    nonisolated static func cutNote(_ note: String) -> String {
        guard note.count > noteLimit else { return note }
        return String(note.prefix(noteLimit - 1)) + "…"
    }

    private func highest(_ page: MarkPage) -> Int {
        (marks[page.key] ?? []).map(\.number).max() ?? 0
    }

    /// Adds the call's marks to `page` and shows the page's marks: new
    /// marks on a page whose marks were hidden would otherwise not be seen.
    @discardableResult
    func add(chat: Int, page: MarkPage, items: [(label: String, note: String, locator: MarkLocator)],
             call: String, toolUseId: String?, replace: Bool) -> [Mark] {
        if replace { drop(page) }
        // A known page keeps the name it was first listed under.
        let page = marks[page.key]?.first?.page ?? page
        var next = highest(page)
        var added: [Mark] = []
        for item in items.prefix(Self.perCall) {
            next += 1
            added.append(Mark(number: next, page: page, note: Self.cutNote(item.note), label: item.label,
                              locator: item.locator, found: true, call: call))
        }
        marks[page.key, default: []].append(contentsOf: added)
        if hidden.contains(page.key) { hidden.remove(page.key) }
        calls[chat, default: []].append(MarkCall(id: call, toolUseId: toolUseId, marks: added))
        save()
        return added
    }

    /// Removes the page's marks for good; returns how many. The call
    /// records lose them too, so no "Show again" brings them back.
    @discardableResult
    func clear(page: MarkPage) -> Int {
        let count = drop(page)
        if count > 0 { save() }
        return count
    }

    /// The page's marks leave the store and every call's record (so no row
    /// offers "Show again" for them); returns how many. Nothing is written.
    @discardableResult
    private func drop(_ page: MarkPage) -> Int {
        let count = marks[page.key]?.count ?? 0
        guard count > 0 else { return 0 }
        marks[page.key] = nil
        hidden.remove(page.key)
        for chat in calls.keys {
            calls[chat] = calls[chat]?.map { record in
                var record = record
                record.marks.removeAll { $0.page == page }
                return record
            }
        }
        return count
    }

    func marks(on page: MarkPage) -> [Mark] {
        (marks[page.key] ?? []).sorted { $0.number < $1.number }
    }

    /// Every mark, by page key and then number.
    var all: [Mark] { marks.keys.sorted().flatMap { (marks[$0] ?? []).sorted { $0.number < $1.number } } }

    func isHidden(_ page: MarkPage) -> Bool { hidden.contains(page.key) }

    /// Hide or show the page's marks; they stay as they are either way.
    func setHidden(_ flag: Bool, page: MarkPage) {
        guard marks[page.key] != nil, hidden.contains(page.key) != flag else { return }
        if flag { hidden.insert(page.key) } else { hidden.remove(page.key) }
        save()
    }

    /// Records which marks the page script found. Assigns nothing when no
    /// flag changes: the page redraws on every change and calls this after.
    func setFound(page: MarkPage, found: [Int: Bool]) {
        guard var list = marks[page.key] else { return }
        var changed = false
        for index in list.indices {
            if let flag = found[list[index].number], list[index].found != flag {
                list[index].found = flag
                changed = true
            }
        }
        if changed { marks[page.key] = list }
    }

    /// The chip's words for `page`: its own marks only.
    func chipText(page: MarkPage?, form: ChipForm) -> String {
        let count = page.map { marks[$0.key]?.count ?? 0 } ?? 0
        guard count > 0 else { return "" }
        switch form {
        case .count: return "\(count)"
        case .short, .full: return "\(count) mark\(count == 1 ? "" : "s")"
        }
    }

    /// The "Marks:" block the agent's look carries for the page it looks
    /// at; `nil` with no marks there.
    func lookText(current: MarkPage?) -> String? {
        guard let current else { return nil }
        let all = marks(on: current)
        guard !all.isEmpty else { return nil }
        var lines = [isHidden(current) ? "Marks (hidden by the person, not drawn on the page now):" : "Marks:"]
        for mark in all {
            var line = "- \(mark.number) · \(mark.label)"
            if !mark.note.isEmpty { line += " — \(mark.note)" }
            if !mark.found, !isHidden(current) { line += " — not on the page now" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func call(chat: Int, toolUseId: String) -> MarkCall? {
        calls[chat]?.last { $0.toolUseId == toolUseId }
    }

    /// "Show again" on a Mark row: the call's page shows its marks, and
    /// the first of the call's marks still there is returned to go to.
    /// Cleared marks do not come back.
    func showAgain(chat: Int, toolUseId: String) -> Mark? {
        guard let record = call(chat: chat, toolUseId: toolUseId), let page = record.marks.first?.page else { return nil }
        guard let first = marks(on: page).first(where: { $0.call == record.id }) else { return nil }
        setHidden(false, page: page)
        return first
    }

    // MARK: kept on disk

    private struct Saved: Codable {
        var version = 1
        var pages: [SavedPage]
    }

    private struct SavedPage: Codable {
        var key: String
        var name: String
        var hidden: Bool
        var marks: [SavedMark]
    }

    private struct SavedMark: Codable {
        var number: Int
        var note: String
        var label: String
        var locator: MarkLocator
        var call: String
    }

    /// Whether a page's marks are written to disk: a file's are, and so are
    /// those of a page this Mac serves to itself (a prototype on
    /// `localhost`), when its address has no query and no sign-in. Any
    /// other web address can carry a sign-in or a one-time token, so its
    /// marks stay in memory until the app quits, as all marks did before
    /// v0.26.5.
    nonisolated static func isKept(_ key: String) -> Bool {
        if key.hasPrefix("/") { return true }
        guard let parts = URLComponents(string: key), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? ""),
              parts.query == nil, parts.user == nil, parts.password == nil
        else { return false }
        return true
    }

    /// Read the marks kept in `home` and keep later changes there. A
    /// missing file starts empty. A file that is there and cannot be read
    /// (damaged, or written by a later version) is left exactly as it is:
    /// this run keeps its marks in memory and writes nothing.
    func keep(in home: URL) {
        let file = home.appendingPathComponent(Self.fileName)
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1
        else {
            self.file = nil
            return
        }
        var marks: [String: [Mark]] = [:]
        var hidden: Set<String> = []
        for page in saved.pages where !page.marks.isEmpty {
            let owner = MarkPage(key: page.key, name: page.name)
            marks[page.key] = page.marks.map {
                Mark(number: $0.number, page: owner, note: $0.note, label: $0.label, locator: $0.locator, found: true, call: $0.call)
            }
            if page.hidden { hidden.insert(page.key) }
        }
        self.marks = marks
        self.hidden = hidden
    }

    private func save() {
        guard let file else { return }
        let pages = marks.keys.filter(Self.isKept).sorted().compactMap { key -> SavedPage? in
            guard let list = marks[key], let first = list.first else { return nil }
            return SavedPage(key: key, name: first.page.name, hidden: hidden.contains(key), marks: list.map {
                SavedMark(number: $0.number, note: $0.note, label: $0.label, locator: $0.locator, call: $0.call)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Saved(pages: pages)) else { return }
        // Created 0600 by `open` itself (the mode can only lose bits to the
        // umask), written, then moved into place.
        let fresh = file.deletingLastPathComponent().appendingPathComponent(Self.fileName + ".new")
        unlink(fresh.path)
        let descriptor = open(fresh.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { return }  // The marks stay in memory; the next change tries again.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(fresh.path)
            return
        }
        if rename(fresh.path, file.path) != 0 { unlink(fresh.path) }
    }
}
