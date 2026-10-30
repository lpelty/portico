import Foundation

// MARK: - FrontMatter (v0.11, item 68)

/// A Markdown file's YAML front matter: the block between a `---` on the
/// file's first line and the next `---` (or `...`). The viewer draws it as
/// a quiet Properties block, foldable to one line ("Properties · 4 —
/// draft, Oct 28, 3 tags"), and hands only the body to the renderer; it
/// used to reach the renderer whole, and the closing `---` turned the last
/// line into a setext heading.
///
/// Reads the YAML people write by hand in notes, not all of YAML: `key:
/// value`, quoted strings, `[a, b]` lists and `- item` lists, comments. A
/// nested map reads as one line of its own `key: value` pairs. Pure, so it
/// is tested without a web view.
struct FrontMatter: Equatable, Sendable {
    struct Property: Equatable, Sendable {
        var key: String
        var value: Value
    }

    enum Value: Equatable, Sendable {
        case text(String)
        /// `2026-10-28`, or with a time after it; kept as written.
        case date(String)
        case list([String])
    }

    var properties: [Property]

    // MARK: finding it

    /// The front matter and the rest of the file, or `nil` and the file
    /// untouched when it does not open with a closed block.
    static func split(_ source: String) -> (frontMatter: FrontMatter?, body: String) {
        var text = Substring(source)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        func bare(_ line: Substring) -> Substring {
            var line = line
            while let last = line.last, last == "\r" || last == " " || last == "\t" { line = line.dropLast() }
            return line
        }
        // Swift reads "\r\n" as one Character: a line ends at either. Each
        // line keeps where the next begins, so the body is the file's own
        // text from there, line endings as written.
        var lines: [(text: Substring, next: Substring.Index)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex { $0 == "\n" || $0 == "\r\n" } ?? text.endIndex
            let next = end == text.endIndex ? end : text.index(after: end)
            lines.append((text[start..<end], next))
            start = next
            if lines.count == 1, bare(lines[0].text) != "---" { break }
            if lines.count > 1, ["---", "..."].contains(bare(lines[lines.count - 1].text)) { break }
        }
        guard let first = lines.first, bare(first.text) == "---", lines.count > 1,
            let close = lines.last, ["---", "..."].contains(bare(close.text))
        else { return (nil, source) }
        let block = lines.dropFirst().dropLast().map { String(bare($0.text)) }
        return (FrontMatter(properties: parse(block)), String(text[close.next...]))
    }

    // MARK: reading

    private static func parse(_ lines: [String]) -> [Property] {
        var properties: [Property] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#", first != "-",
                let colon = keyColon(in: line)
            else { continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = stripComment(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            // The indented lines under it: a `- item` list or a nested map.
            var children: [String] = []
            while index < lines.count, lines[index].isEmpty || lines[index].first == " " || lines[index].first == "\t" {
                let child = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
                if !child.isEmpty { children.append(child) }
                index += 1
            }
            properties.append(Property(key: key, value: value(rest, children: children)))
        }
        return properties
    }

    /// The colon that ends the key: the first `: ` or a colon at the end
    /// of the line, outside quotes (`url: https://…` keeps its own).
    private static func keyColon(in line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func value(_ rest: String, children: [String]) -> Value {
        if rest.isEmpty {
            if !children.isEmpty, children.allSatisfy({ $0.hasPrefix("-") }) {
                return .list(children.map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) })
            }
            return .text(children.joined(separator: ", "))
        }
        if rest.hasPrefix("["), rest.hasSuffix("]") {
            let inner = rest.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .list([]) }
            return .list(splitFlow(inner).map { unquote($0.trimmingCharacters(in: .whitespaces)) })
        }
        let text = unquote(rest)
        return isDate(text) ? .date(text) : .text(text)
    }

    /// `a, "b, c", d` as three items.
    private static func splitFlow(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
            } else if c == "\"" || c == "'" {
                quote = c
                current.append(c)
            } else if c == "," {
                items.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        items.append(current)
        return items
    }

    /// A ` #` outside quotes starts a comment; a `#` inside a word does not.
    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#", previous == " " || previous == "\t" {
                return String(text[..<index])
            }
            previous = c
            index = text.index(after: index)
        }
        return text
    }

    /// `"a"` → `a`; `'it''s'` → `it's`.
    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text
        }
        let inner = String(text.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'") : inner.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func isDate(_ text: String) -> Bool {
        text.range(of: #"^\d{4}-\d{2}-\d{2}([ T].*)?$"#, options: .regularExpression) != nil
    }

    // MARK: status

    /// Keys whose value is a state worth a dot.
    static func isStatusKey(_ key: String) -> Bool {
        ["status", "state", "stage", "phase"].contains(key.lowercased())
    }

    /// The colour a status's dot takes.
    enum Tone: String, Equatable, Sendable {
        case wait, done, stopped, neutral
    }

    static func tone(forStatus value: String) -> Tone {
        let word = value.lowercased().trimmingCharacters(in: .whitespaces)
        if ["draft", "wip", "in progress", "in-progress", "doing", "todo", "to do", "pending", "review", "in review", "open", "planned"]
            .contains(word) { return .wait }
        if ["done", "complete", "completed", "final", "published", "approved", "shipped", "active", "live"]
            .contains(word) { return .done }
        if ["archived", "deprecated", "cancelled", "canceled", "abandoned", "blocked", "closed"]
            .contains(word) { return .stopped }
        return .neutral
    }

    // MARK: the folded line

    /// The folded line after "Properties ·": the count, then up to three
    /// values in a few words: a status first, then dates ("Oct 28", with
    /// the year when it is not this one), lists as a count ("3 tags"), and
    /// short strings; a title is left out, the heading below says it.
    func summary(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts: [String] = []
        for property in properties where Self.isStatusKey(property.key) {
            if case .text(let text) = property.value, !text.isEmpty { parts.append(text) }
        }
        for property in properties {
            if case .date(let text) = property.value { parts.append(Self.shortDate(text, now: now, calendar: calendar, locale: locale)) }
        }
        for property in properties {
            if case .list(let items) = property.value, !items.isEmpty {
                parts.append("\(items.count) \(items.count == 1 ? Self.singular(property.key) : property.key)")
            }
        }
        for property in properties where !Self.isStatusKey(property.key) && !["title", "name"].contains(property.key.lowercased()) {
            if case .text(let text) = property.value, !text.isEmpty, text.count <= Self.shortText { parts.append(text) }
        }
        let shown = parts.prefix(3)
        return shown.isEmpty ? "\(properties.count)" : "\(properties.count) — " + shown.joined(separator: ", ")
    }

    /// The longest string the folded line names.
    static let shortText = 20

    /// `2026-10-28` reads `Oct 28` this year, `Oct 28, 2025` another;
    /// anything that does not read as a date is kept as written.
    static func shortDate(_ text: String, now: Date, calendar: Calendar, locale: Locale) -> String {
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(text.prefix(10))) else { return text }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let out = DateFormatter()
        out.calendar = calendar
        out.timeZone = calendar.timeZone
        out.locale = locale
        out.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return out.string(from: date)
    }

    /// `tags` → `tag`, `aliases` → `alias`; a key that is not plural stays.
    static func singular(_ key: String) -> String {
        if key.hasSuffix("ses") { return String(key.dropLast(2)) }
        if key.hasSuffix("s"), key.count > 1 { return String(key.dropLast()) }
        return key
    }

    // MARK: the block's HTML

    /// The Properties block for the viewer page: a `<details>`, open, whose
    /// summary line shows the folded words only while it is closed
    /// (viewer.css). Every value is escaped.
    func html(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let e = MarkdownPage.escapeHTML
        var rows = ""
        for property in properties {
            let value: String
            switch property.value {
            case .text(let text) where Self.isStatusKey(property.key) && !text.isEmpty:
                value = "<span class=\"fm-dot fm-\(Self.tone(forStatus: text).rawValue)\"></span>\(e(text))"
            case .text(let text), .date(let text):
                value = e(text)
            case .list(let items):
                value = items.map { "<span class=\"fm-tag\">\(e($0))</span>" }.joined()
            }
            rows += "<div class=\"fm-row\"><span class=\"fm-key\">\(e(property.key))</span>"
                + "<span class=\"fm-value\">\(value)</span></div>"
        }
        return "<details class=\"fm\" open><summary>"
            + "<span class=\"fm-chevron\"></span><span class=\"fm-label\">Properties</span>"
            + "<span class=\"fm-summary\">· \(e(summary(now: now, calendar: calendar, locale: locale)))</span>"
            + "</summary><div class=\"fm-rows\">\(rows)</div></details>"
    }
}
