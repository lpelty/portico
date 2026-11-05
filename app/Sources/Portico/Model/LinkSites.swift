import Foundation

/// Link chips (v0.19 spec §10): a link in the person's message to a known
/// site shows as the site's name and the start of its path.
enum LinkSites {
    /// Host suffix to name. A deployment adds its own through hello's
    /// `link_sites` (`[links] sites`).
    static let builtIn: [String: String] = [
        "slack.com": "Slack",
        "docs.google.com": "Google Docs",
        "sheets.google.com": "Google Sheets",
        "slides.google.com": "Google Slides",
        "github.com": "GitHub",
        "figma.com": "Figma",
        "notion.so": "Notion",
    ]

    static let pathLimit = 24

    /// The chip for a URL: the site's name, the path cut to 24 characters
    /// with "…". Nil for a host that is neither built in nor in `extra`
    /// (`extra` wins).
    static func chip(for url: URL, extra: [String: String] = [:]) -> (site: String, path: String)? {
        guard let host = url.host?.lowercased() else { return nil }
        let match: (String, String)? = [extra, builtIn.filter { extra[$0.key] == nil }]
            .lazy.flatMap { $0 }
            .filter { host == $0.key.lowercased() || host.hasSuffix("." + $0.key.lowercased()) }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
        guard let (_, site) = match else { return nil }
        var path = url.path
        if path.count > pathLimit { path = String(path.prefix(pathLimit - 1)) + "…" }
        return (site, path)
    }
}

/// Bare URLs in a message's text (v0.19 spec §9): `NSDataDetector` finds
/// them, http and https only, leaving out what is already a link (written
/// as Markdown) or sits in `inline code`.
enum Linkify {
    /// The only schemes a link may have: http, https, mailto. Anything else
    /// (javascript:, file:, ...) is never linked or opened; its text stays plain.
    static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    /// Ranges in the text as shown (Markdown markers gone), each with its URL.
    static func ranges(in text: String) -> [(NSRange, URL)] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return detect(in: text, skipping: [])
        }
        var skip: [NSRange] = []
        var shown = ""
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            // A link whose text is its own address is a bare URL the parser
            // already linked; one with other text was written as Markdown.
            let written = run.link.map { $0.absoluteString != piece && $0.absoluteString.removingPercentEncoding != piece } ?? false
            if written || run.inlinePresentationIntent?.contains(.code) == true {
                skip.append(NSRange(location: (shown as NSString).length, length: (piece as NSString).length))
            }
            shown += piece
        }
        return detect(in: shown, skipping: skip)
    }

    /// Every http(s) URL in text taken as written, outside `skipping`.
    static func detect(in text: String, skipping: [NSRange] = []) -> [(NSRange, URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, range: whole).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !skipping.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { return nil }
            return (match.range, url)
        }
    }
}

/// The person's own text in a bubble (v0.19 §9, §10): a known site's link
/// leaves the text and becomes a chip; any other bare URL stays in the text
/// as a link.
enum BubbleLinks {
    struct Split: Equatable {
        var text: String
        var chips: [URL]
    }

    static func split(_ text: String, extra: [String: String] = [:]) -> Split {
        var chips: [URL] = []
        var kept = text as NSString
        // The person's text is plain: ranges are of the text as written.
        for (range, url) in Linkify.detect(in: text).reversed() where LinkSites.chip(for: url, extra: extra) != nil {
            var cut = range
            // A space on both sides: take one with the URL, so none doubles.
            if range.location > 0, range.location + range.length < kept.length,
               kept.character(at: range.location - 1) == 32, kept.character(at: range.location + range.length) == 32 {
                cut.length += 1
            }
            kept = kept.replacingCharacters(in: cut, with: "") as NSString
            chips.insert(url, at: 0)
        }
        let lines = (kept as String).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return Split(text: text, chips: chips)
    }

    /// The text with its bare URLs as links.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for (range, url) in Linkify.detect(in: text) {
            guard let r = Range(range, in: text), let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out)
            else { continue }
            guard Linkify.allowed(url) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].foregroundColor = Theme.accent
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }
}
