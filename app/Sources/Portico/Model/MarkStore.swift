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

/// One `viewer_mark` call's marks, kept so "Show again" can put them back.
struct MarkCall: Equatable, Sendable {
    var id: String
    var toolUseId: String?
    var marks: [Mark]
}

/// The marks the agent has drawn, per chat (v0.14 §3.3-3.5). Numbers run
/// across pages within a chat and restart at 1 after a clear.
@MainActor
final class MarkStore: ObservableObject {
    nonisolated static let capability = "viewer.marks.v1"
    nonisolated static let noteLimit = 60
    nonisolated static let perCall = 9

    enum ChipForm { case full, short, count }

    @Published private(set) var marks: [Int: [Mark]] = [:]
    private var calls: [Int: [MarkCall]] = [:]

    /// A note over the limit is cut to one character fewer, plus "…".
    nonisolated static func cutNote(_ note: String) -> String {
        guard note.count > noteLimit else { return note }
        return String(note.prefix(noteLimit - 1)) + "…"
    }

    private func highest(_ chat: Int) -> Int {
        (marks[chat] ?? []).map(\.number).max() ?? 0
    }

    @discardableResult
    func add(chat: Int, page: MarkPage, items: [(label: String, note: String, locator: MarkLocator)],
             call: String, toolUseId: String?, replace: Bool) -> [Mark] {
        if replace { marks[chat] = nil }
        // A known page keeps the name it was first listed under.
        let page = (marks[chat] ?? []).first { $0.page == page }?.page ?? page
        var next = highest(chat)
        var added: [Mark] = []
        for item in items.prefix(Self.perCall) {
            next += 1
            added.append(Mark(number: next, page: page, note: Self.cutNote(item.note), label: item.label,
                              locator: item.locator, found: true, call: call))
        }
        marks[chat, default: []].append(contentsOf: added)
        calls[chat, default: []].append(MarkCall(id: call, toolUseId: toolUseId, marks: added))
        return added
    }

    /// Removes every mark in the chat; returns how many.
    @discardableResult
    func clear(chat: Int) -> Int {
        let count = marks[chat]?.count ?? 0
        if count > 0 { marks[chat] = nil }
        return count
    }

    func marks(chat: Int, on page: MarkPage) -> [Mark] {
        (marks[chat] ?? []).filter { $0.page == page }
    }

    /// Records which marks the page script found. Assigns nothing when no
    /// flag changes: the page redraws on every change and calls this after.
    func setFound(chat: Int, page: MarkPage, found: [Int: Bool]) {
        guard var list = marks[chat] else { return }
        var changed = false
        for index in list.indices where list[index].page == page {
            if let flag = found[list[index].number], list[index].found != flag {
                list[index].found = flag
                changed = true
            }
        }
        if changed { marks[chat] = list }
    }

    /// Pages with marks, the current page first, the rest by lowest number.
    func groups(chat: Int, current: MarkPage?) -> [(page: MarkPage, marks: [Mark])] {
        let sorted = (marks[chat] ?? []).sorted { $0.number < $1.number }
        var order: [MarkPage] = []
        for mark in sorted where !order.contains(mark.page) { order.append(mark.page) }
        if let current, let index = order.firstIndex(of: current) {
            order.remove(at: index)
            order.insert(current, at: 0)
        }
        return order.map { page in (page: page, marks: sorted.filter { $0.page == page }) }
    }

    func chipText(chat: Int, form: ChipForm) -> String {
        let list = marks[chat] ?? []
        guard !list.isEmpty else { return "" }
        let count = list.count
        let pages = Set(list.map(\.page)).count
        let noun = "\(count) mark\(count == 1 ? "" : "s")"
        switch form {
        case .count: return "\(count)"
        case .short: return noun
        case .full: return pages > 1 ? "\(noun) · \(pages) pages" : noun
        }
    }

    /// The "Marks:" block the agent's look carries; `nil` with no marks.
    func lookText(chat: Int, current: MarkPage?) -> String? {
        let all = groups(chat: chat, current: current).flatMap(\.marks)
        guard !all.isEmpty else { return nil }
        var lines = ["Marks:"]
        for mark in all {
            var line = "- \(mark.number) · \(mark.label)"
            if !mark.note.isEmpty { line += " — \(mark.note)" }
            line += " (\(mark.page == current ? "this page" : mark.page.name))"
            if !mark.found { line += " — not on the page now" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func call(chat: Int, toolUseId: String) -> MarkCall? {
        calls[chat]?.last { $0.toolUseId == toolUseId }
    }

    /// The call's marks as they now stand. When they were cleared they come
    /// back with their old numbers if all are free, else renumbered after
    /// the current highest, in their original order.
    func showAgain(chat: Int, toolUseId: String) -> [Mark] {
        guard let index = calls[chat]?.lastIndex(where: { $0.toolUseId == toolUseId }),
              let record = calls[chat]?[index] else { return [] }
        let present = (marks[chat] ?? []).filter { $0.call == record.id }
        if !present.isEmpty { return present.sorted { $0.number < $1.number } }
        let taken = Set((marks[chat] ?? []).map(\.number))
        var restored = record.marks.sorted { $0.number < $1.number }
        if restored.contains(where: { taken.contains($0.number) }) {
            var next = highest(chat)
            for i in restored.indices { next += 1; restored[i].number = next }
        }
        for i in restored.indices { restored[i].found = true }
        marks[chat, default: []].append(contentsOf: restored)
        calls[chat]?[index].marks = restored
        return restored
    }

    /// A session ending (a renew) takes its marks and call records with it.
    func endSession(chat: Int) {
        if marks[chat] != nil { marks[chat] = nil }
        calls[chat] = nil
    }
}
