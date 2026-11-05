import Foundation

// v0.22: what a space's page and front matter can ask of the app (spec
// §2, §3, §5, §6). Pure parts, tested on their own: the `space-action:`
// link, the notification's words, the menu a fixed space keeps, and the
// refreshing state with its five-minute end.

/// v0.22 (S1): a `space-action:<action>?item=<item>` link in a space's
/// page, an `<a href>` in HTML or an ordinary link in Markdown.
enum SpaceActionLink {
    static let scheme = "space-action"
    /// The longest an action or an item may be.
    static let maxLength = 128

    struct Request: Equatable, Sendable {
        let action: String
        let item: String?
    }

    enum Parsed: Equatable, Sendable {
        /// Not this scheme: the pane handles it as before.
        case notSpaceAction
        /// This scheme, but not a link the app runs; why, for the log.
        case invalid(String)
        case action(Request)
    }

    /// `action` and `item` match `[A-Za-z0-9._:-]{1,128}`. Read from the
    /// link as written: a percent-escape is not in the set, so it refuses
    /// the link rather than being decoded into something that is.
    static func parse(_ url: URL) -> Parsed {
        guard url.scheme?.lowercased() == scheme else { return .notSpaceAction }
        let text = url.absoluteString
        let rest = String(text.dropFirst(scheme.count + 1))
        if rest.contains("#") { return .invalid("a fragment") }
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let action = parts[0]
        guard isValidPart(action) else { return .invalid("action \"\(action.prefix(40))\"") }
        guard parts.count == 2 else { return .action(Request(action: action, item: nil)) }
        let query = parts[1]
        guard query.hasPrefix("item=") else { return .invalid("only item= may follow the action") }
        let item = String(query.dropFirst("item=".count))
        guard isValidPart(item) else { return .invalid("item \"\(item.prefix(40))\"") }
        return .action(Request(action: action, item: item))
    }

    static func isValidPart(_ text: String) -> Bool {
        guard (1...maxLength).contains(text.count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", ":", "-": true
            default: false
            }
        }
    }
}

/// v0.22 (S5): the spaces reading as refreshing. A refresh begins it; it
/// ends when a `spaces.list` shows that space's `updated` changed (or the
/// space gone), when the refresh fails, or five minutes after it began.
struct SpaceRefreshing: Equatable {
    static let timeout: TimeInterval = 5 * 60

    private struct Entry: Equatable {
        let since: Date
        let baseline: String
    }

    private var entries: [String: Entry] = [:]

    /// The spaces refreshing, whether or not their five minutes are up.
    var ids: Set<String> { Set(entries.keys) }

    /// `updated`: the space's `updated` as the app knew it when it asked.
    mutating func begin(_ id: String, updated: String, at date: Date) {
        entries[id] = Entry(since: date, baseline: updated)
    }

    mutating func end(_ id: String) {
        entries[id] = nil
    }

    /// A new list: a space whose `updated` moved, or that is gone, is done.
    mutating func apply(_ list: [SpaceInfo]) {
        let updated = Dictionary(list.map { ($0.id, $0.updated) }, uniquingKeysWith: { first, _ in first })
        for (id, entry) in entries where updated[id] != entry.baseline {
            entries[id] = nil
        }
    }

    /// Drop those whose five minutes are up.
    mutating func expire(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.since) < Self.timeout }
    }

    func isRefreshing(_ id: String, now: Date) -> Bool {
        guard let entry = entries[id] else { return false }
        return now.timeIntervalSince(entry.since) < Self.timeout
    }
}

extension SpacesPresentation {
    /// The space-updated notification's body and where its click scrolls.
    struct Notification: Equatable {
        let body: String
        let target: String?
    }

    /// v0.22 (S2): the page's `notice` words it; an empty (or blank) one
    /// means no notification for this update; without the key, "Updated —
    /// <time>" as before. `nil` when nothing is to be posted.
    static func notification(for space: SpaceInfo) -> Notification? {
        let target = space.noticeTarget.flatMap { $0.isEmpty ? nil : $0 }
        if let notice = space.notice {
            let trimmed = notice.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Notification(body: trimmed, target: target)
        }
        guard let updated = space.updatedDate else { return nil }
        return Notification(body: notificationBody(updated), target: target)
    }

    /// What a space row's context menu offers.
    enum MenuAction: Hashable {
        case rename, remove
    }

    /// v0.22 (S4): a fixed space (`removable: false`) offers neither.
    static func menuActions(for space: SpaceInfo) -> [MenuAction] {
        space.removable ? [.rename, .remove] : []
    }

    /// v0.22 (S5): the open space's header while it refreshes.
    static let refreshingText = "Refreshing…"

    /// The note beside the open space's title.
    enum HeaderNote: Equatable {
        case updated(String)
        case refreshing
        /// The last refresh or action failed: the gateway's words.
        case error(String)
    }

    /// Refreshing first, then a failure, else "Updated <time>".
    static func headerNote(refreshing: Bool, error: String?, updated: Date?, now: Date = Date()) -> HeaderNote {
        if refreshing { return .refreshing }
        if let error, !error.isEmpty { return .error(error) }
        return .updated(updatedText(updated, now: now))
    }
}
