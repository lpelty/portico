import Foundation

// MARK: - Slash-command completion, v0.11 (item 66, frame AG4)

/// What the composer's slash list shows for what is typed: Portico's own
/// commands first, then the agent's commands and skills (from
/// `chat.commands`), each filtered and ranked. Pure, so the ranking, the
/// footer and the keys are tested without a view.
///
/// The list is open while the text is `/` followed by a name being typed
/// (no blank yet) and something matches. Ranking, in each group: names
/// that start with the query (or whose part after a `plugin:` prefix
/// does), then names that contain it, then descriptions that contain it;
/// alphabetical within each. With nothing typed after the `/`, Portico's
/// own keep their order and the agent's are alphabetical.
struct SlashCompletion: Equatable, Sendable {
    enum Group: Equatable, Sendable { case portico, agent }

    /// One row: a command's name (no `/`), its one-line description, its group.
    struct Item: Equatable, Identifiable, Sendable {
        var name: String
        var description: String
        var group: Group

        var id: String { "\(group == .portico ? "p" : "a")/\(name)" }
        /// What picking it puts in the composer: `/name ` (v0.11 item 66).
        var completion: String { "/\(name) " }
    }

    /// Portico's own, as the gateway and the session card know them:
    /// `/log` logs the session without ending it, `/new` starts the next.
    static let porticoCommands: [AgentCommand] = [
        AgentCommand(name: "log", description: "Log this session"),
        AgentCommand(name: "new", description: "Start a new session"),
    ]

    /// The rows the list shows before it scrolls (the footer's "N more").
    static let visibleRows = 7

    static let keyHints = "↑↓ move · ↵ or Tab pick · esc close"

    /// What was typed after the `/`.
    let query: String
    let portico: [Item]
    let agent: [Item]
    /// Every command there is, Portico's and the agent's, matched or not.
    let total: Int

    /// Both groups in the order shown; the selection indexes this.
    var items: [Item] { portico + agent }

    /// The list for `text`, or `nil` when it is closed: the text is not a
    /// `/` and a name being typed, or nothing matches. The agent's commands
    /// that share a name with Portico's (or each other) are dropped: Portico
    /// answers `/log` and `/new` itself.
    init?(text: String, agentCommands: [AgentCommand]) {
        guard let query = Self.query(in: text) else { return nil }
        let porticoNames = Set(Self.porticoCommands.map(\.name))
        var seen = Set<String>()
        let theirs = agentCommands.filter { !porticoNames.contains($0.name) && seen.insert($0.name).inserted }
        let ours = Self.rank(Self.porticoCommands, query: query, keepOrder: true)
        let agent = Self.rank(theirs, query: query, keepOrder: false)
        guard !ours.isEmpty || !agent.isEmpty else { return nil }
        self.query = query
        self.portico = ours.map { Item(name: $0.name, description: $0.description, group: .portico) }
        self.agent = agent.map { Item(name: $0.name, description: $0.description, group: .agent) }
        self.total = Self.porticoCommands.count + theirs.count
    }

    /// The name being typed after a `/` at the very start, or `nil` when
    /// the text is anything else (a blank or a new line ends the name).
    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(rest)
    }

    /// `commands` that match `query`, best first (see the type's comment).
    static func rank(_ commands: [AgentCommand], query: String, keepOrder: Bool) -> [AgentCommand] {
        let q = query.lowercased()
        func tier(_ c: AgentCommand) -> Int? {
            if q.isEmpty { return 0 }
            let name = c.name.lowercased()
            let tail = name.split(separator: ":").last.map(String.init) ?? name
            if name.hasPrefix(q) || tail.hasPrefix(q) { return 0 }
            if name.contains(q) { return 1 }
            if c.description.lowercased().contains(q) { return 2 }
            return nil
        }
        let ranked = commands.enumerated().compactMap { offset, c in tier(c).map { (tier: $0, offset: offset, command: c) } }
        return ranked.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if keepOrder { return a.offset < b.offset }
            let order = a.command.name.localizedCaseInsensitiveCompare(b.command.name)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.command)
    }

    /// The footer's left side (AG4): with nothing typed and more rows than
    /// fit, how many are below; otherwise how many match of how many there are.
    var footer: String {
        let count = items.count
        if query.isEmpty && count > Self.visibleRows {
            return "↓ \(count - Self.visibleRows) more — scroll, or keep typing"
        }
        return "\(count) of \(total)"
    }

    // MARK: keys

    enum Key: Equatable, Sendable { case up, down, tab, enter, escape }

    enum Outcome: Equatable, Sendable {
        /// The selection moves to this row.
        case select(Int)
        /// Put `item.completion` in the composer; `send` too when it was
        /// Enter on one of Portico's own (Enter on `/log` logs, as typing
        /// `/log` and Enter always has).
        case pick(Item, send: Bool)
        case close
    }

    /// What `key` does with `selection` the current row. ↑ and ↓ stop at
    /// the ends; Enter and Tab pick; Esc closes.
    func handle(_ key: Key, selection: Int) -> Outcome {
        let rows = items
        let current = min(max(selection, 0), rows.count - 1)
        switch key {
        case .up: return .select(max(current - 1, 0))
        case .down: return .select(min(current + 1, rows.count - 1))
        case .tab: return .pick(rows[current], send: false)
        case .enter: return .pick(rows[current], send: rows[current].group == .portico)
        case .escape: return .close
        }
    }
}
