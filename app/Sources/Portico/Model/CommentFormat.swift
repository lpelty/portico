import Foundation

// MARK: - CommentFormat (v0.23)

/// Comment format v1: comments stored inline in a Markdown file
/// (`protocol/COMMENTS.md`). Anchors `<!--c:ID-->` … `<!--/c:ID-->` go around
/// the commented text; the thread is an HTML comment block
/// `<!--co:ID by:… at:… status:… quote:"…"` … `-->` after the top-level block
/// that holds the anchor.
///
/// The same operations as the gateway's `comments.py`, tested against the
/// same fixtures. Every range is in **UTF-16 offsets**, the unit the page and
/// the editor speak. Every edit is a splice, so a write that changes nothing
/// leaves the bytes as they were.
enum CommentFormat {
    enum Status: String, Equatable, Sendable { case open, resolved }

    struct Reply: Equatable, Sendable {
        var author: String
        var at: String?
        var text: String
    }

    struct Field: Equatable, Sendable {
        var key: String
        var range: Range<Int>
    }

    struct Thread: Equatable, Sendable {
        var id: String
        var by: String
        var at: String
        var status: Status
        var quote: String
        var replies: [Reply]
        /// Raw `+EMOJI names` lines, kept as read.
        var reactions: [String]
        /// The block, from its line start through its closing line's break.
        var block: Range<Int>
        /// The text between the markers; nil for a thread whose anchor is gone.
        var anchor: Range<Int>?
        var fields: [Field]
        /// Where the closing `-->` starts.
        var close: Int
        var isOrphan: Bool { anchor == nil }
    }

    struct Parsed: Equatable, Sendable {
        var threads: [Thread]
        var orphanAnchors: [String]
    }

    enum Refusal: Error, Equatable, Sendable {
        case notFound
        case occurs(Int)
        case crossesBlocks
        case insideIgnored
    }

    enum EditError: Error, Equatable {
        case unknownThread(String)
    }

    static let idCharacters = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    // MARK: units

    fileprivate typealias U = [UInt16]
    fileprivate static func u(_ s: String) -> U { Array(s.utf16) }
    fileprivate static func s(_ u: ArraySlice<UInt16>) -> String { String(decoding: u, as: UTF16.self) }
    fileprivate static let nl: UInt16 = 10, cr: UInt16 = 13, sp: UInt16 = 32, tab: UInt16 = 9
    fileprivate static let lt: UInt16 = 60, gt: UInt16 = 62, dash: UInt16 = 45, colon: UInt16 = 58
    fileprivate static let quoteMark: UInt16 = 34, backslash: UInt16 = 92, backtick: UInt16 = 96, tilde: UInt16 = 126

    fileprivate static func has(_ t: U, _ p: U, at i: Int) -> Bool {
        guard i >= 0, i + p.count <= t.count else { return false }
        for k in 0..<p.count where t[i + k] != p[k] { return false }
        return true
    }

    fileprivate static func find(_ t: U, _ p: U, from: Int, to: Int? = nil) -> Int? {
        let end = (to ?? t.count) - p.count
        guard !p.isEmpty, from <= end else { return nil }
        var i = max(from, 0)
        while i <= end {
            if t[i] == p[0], has(t, p, at: i) { return i }
            i += 1
        }
        return nil
    }

    fileprivate static func isIDUnit(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
    fileprivate static func isBlank(_ t: U, _ r: Range<Int>) -> Bool {
        r.allSatisfy { isSpaceUnit(t[$0]) }
    }
    fileprivate static func isSpaceUnit(_ c: UInt16) -> Bool {
        guard let sc = Unicode.Scalar(c) else { return false }
        return sc.properties.isWhitespace
    }

    // MARK: lines

    fileprivate struct Line { var start: Int; var end: Int; var full: Int }

    fileprivate static func lines(_ t: U) -> [Line] {
        var out: [Line] = []
        var i = 0
        while i < t.count {
            guard let j = t[i...].firstIndex(of: nl) else {
                out.append(Line(start: i, end: t.count, full: t.count))
                break
            }
            let end = j > i && t[j - 1] == cr ? j - 1 : j
            out.append(Line(start: i, end: end, full: j + 1))
            i = j + 1
        }
        return out
    }

    static func lineEnding(_ text: String) -> String {
        let t = u(text)
        if let j = t.firstIndex(of: nl), j > 0, t[j - 1] == cr { return "\r\n" }
        return "\n"
    }

    fileprivate static func bare(_ t: U, _ l: Line) -> U {
        var e = l.end
        while e > l.start, t[e - 1] == sp || t[e - 1] == tab { e -= 1 }
        return Array(t[l.start..<e])
    }

    // MARK: regions

    fileprivate struct Block { var start: Int; var end: Int; var close: Int; var id: String }

    fileprivate struct Segment { var kind: String; var first: Int; var last: Int }

    fileprivate struct Regions {
        var lines: [Line]
        var frontMatter: Range<Int>?
        var ignored: [Range<Int>]
        var blocks: [Block]
        var segs: [Segment]
    }

    // MARK: block starts (CommonMark, as far as comments need it)

    fileprivate static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    nonisolated(unsafe) fileprivate static let topFenceRE = rx(#"^ {0,3}(`{3,}|~{3,})"#)
    nonisolated(unsafe) fileprivate static let headingRE = rx(#"^ {0,3}#{1,6}(?:[ \t]|$)"#)
    nonisolated(unsafe) fileprivate static let hrRE = rx(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    nonisolated(unsafe) fileprivate static let setextRE = rx(#"^ {0,3}(?:=+|-+)[ \t]*$"#)
    nonisolated(unsafe) fileprivate static let quoteRE = rx(#"^ {0,3}>"#)
    nonisolated(unsafe) fileprivate static let htmlRE = rx(#"^ {0,3}<(?:[A-Za-z/?]|!)"#)
    nonisolated(unsafe) fileprivate static let anchorLineRE = rx(#"^ {0,3}<!--/?c:[a-z0-9]{5,8}-->"#)
    nonisolated(unsafe) fileprivate static let bulletRE = rx(#"^ {0,3}[-*+][ \t]+\S"#)
    nonisolated(unsafe) fileprivate static let orderedOneRE = rx(#"^ {0,3}1[.)][ \t]+\S"#)
    nonisolated(unsafe) fileprivate static let listRE = rx(#"^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)"#)
    nonisolated(unsafe) fileprivate static let refdefRE = rx(#"^ {0,3}\[[^\]]+\]:[ \t]*\S"#)
    nonisolated(unsafe) fileprivate static let indentedRE = rx(#"^(?: {4}| {0,3}\t)"#)
    nonisolated(unsafe) fileprivate static let blockStartRE = rx(#"^[ \t]*<!--co:[a-z0-9]{5,8}(?=[ \t\r\n\f\u000B]|-->|$)"#)
    nonisolated(unsafe) fileprivate static let autolinkRE = rx(#"<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>@]+)>"#)
    nonisolated(unsafe) fileprivate static let tagRE = rx(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#)

    /// The first match of `re` in `string`, anchored at UTF-16 offset `at` (whole string when nil).
    fileprivate static func match(_ re: NSRegularExpression, _ string: String) -> Bool {
        re.firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil
    }

    fileprivate static func lineText(_ t: U, _ l: Line) -> String { s(t[l.start..<l.end]) }

    fileprivate static func interrupts(_ line: String, inQuote: Bool = false) -> Bool {
        if match(blockStartRE, line) { return true }
        if match(topFenceRE, line) || match(headingRE, line) || match(hrRE, line) { return true }
        if !inQuote, match(quoteRE, line) { return true }
        if match(htmlRE, line), !match(anchorLineRE, line) { return true }
        return match(bulletRE, line) || match(orderedOneRE, line)
    }

    fileprivate static func blankLine(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{0C}" || $0 == "\u{0B}" }
    }

    /// Top-level blocks (para, list, quote, heading, hr, fence, icode, html, thread, fm).
    fileprivate static func segments(_ t: U, _ ls: [Line], _ blocks: [Block], _ fm: Range<Int>?) -> [Segment] {
        var segs: [Segment] = []
        let n = ls.count
        let texts = ls.map { lineText(t, $0) }
        var byStart: [Int: Block] = [:]
        for b in blocks { byStart[b.start] = b }
        func lead(_ x: String) -> Bool { x.hasPrefix(" ") || x.hasPrefix("\t") }
        var i = 0
        if let fm {
            var j = 0
            while ls[j].full < fm.upperBound { j += 1 }
            segs.append(Segment(kind: "fm", first: 0, last: j))
            i = j + 1
        }
        while i < n {
            let line = texts[i]
            if blankLine(line) { i += 1; continue }
            if let b = byStart[ls[i].start] {
                var j = i
                while ls[j].full < b.end { j += 1 }
                segs.append(Segment(kind: "thread", first: i, last: j))
                i = j + 1
                continue
            }
            if let m = topFenceRE.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
                let fence = (line as NSString).substring(with: m.range(at: 1))
                var j = i + 1
                while j < n {
                    let x = texts[j]
                    if let mm = topFenceRE.firstMatch(in: x, range: NSRange(location: 0, length: x.utf16.count)) {
                        let f = (x as NSString).substring(with: mm.range(at: 1))
                        let rest = (x as NSString).substring(from: mm.range.location + mm.range.length)
                        if f.first == fence.first, f.count >= fence.count, blankLine(rest) { break }
                    }
                    j += 1
                }
                j = min(j, n - 1)
                segs.append(Segment(kind: "fence", first: i, last: j))
                i = j + 1
                continue
            }
            if match(indentedRE, line) {
                var j = i
                while j + 1 < n, match(indentedRE, texts[j + 1]) || blankLine(texts[j + 1]) { j += 1 }
                while blankLine(texts[j]) { j -= 1 }
                segs.append(Segment(kind: "icode", first: i, last: j))
                i = j + 1
                continue
            }
            if match(headingRE, line) { segs.append(Segment(kind: "heading", first: i, last: i)); i += 1; continue }
            if match(hrRE, line) { segs.append(Segment(kind: "hr", first: i, last: i)); i += 1; continue }
            if match(htmlRE, line), !match(anchorLineRE, line) {
                var j = i
                if line.drop(while: { $0 == " " }).hasPrefix("<!--") {
                    while j < n, !texts[j].contains("-->") { j += 1 }
                    j = min(j, n - 1)
                } else {
                    while j + 1 < n, !blankLine(texts[j + 1]) { j += 1 }
                }
                segs.append(Segment(kind: "html", first: i, last: j))
                i = j + 1
                continue
            }
            if match(quoteRE, line) {
                var j = i
                while j + 1 < n, !blankLine(texts[j + 1]),
                    match(quoteRE, texts[j + 1]) || !interrupts(texts[j + 1], inQuote: true)
                {
                    j += 1
                }
                segs.append(Segment(kind: "quote", first: i, last: j))
                i = j + 1
                continue
            }
            if match(listRE, line) {
                var j = i
                while true {
                    if j + 1 < n, !blankLine(texts[j + 1]) {
                        let next = texts[j + 1]
                        if lead(next) || match(listRE, next) || !interrupts(next) {
                            if match(blockStartRE, next) { break }
                            j += 1
                            continue
                        }
                        break
                    }
                    var k = j + 1
                    while k < n, blankLine(texts[k]) { k += 1 }
                    if k > j + 1, k < n, !match(blockStartRE, texts[k]), lead(texts[k]) || match(listRE, texts[k]) {
                        j = k
                        continue
                    }
                    break
                }
                segs.append(Segment(kind: "list", first: i, last: j))
                i = j + 1
                continue
            }
            var j = i
            while j + 1 < n {
                let next = texts[j + 1]
                if blankLine(next) { break }
                if match(setextRE, next) { j += 1; break }
                if interrupts(next) { break }
                j += 1
            }
            segs.append(Segment(kind: "para", first: i, last: j))
            i = j + 1
        }
        return segs
    }

    fileprivate static func frontMatter(_ t: U, _ ls: [Line]) -> Range<Int>? {
        guard let first = ls.first, bare(t, first) == u("---") else { return nil }
        for l in ls.dropFirst() {
            let b = bare(t, l)
            if b == u("---") || b == u("...") { return 0..<l.full }
        }
        return nil
    }

    /// `^[ \t>]*(`{3,}|~{3,})`: the fence's char and length, and where it ends.
    fileprivate static func fence(_ t: U, _ l: Line) -> (UInt16, Int, Int)? {
        var i = l.start
        while i < l.end, t[i] == sp || t[i] == tab || t[i] == gt { i += 1 }
        guard i < l.end, t[i] == backtick || t[i] == tilde else { return nil }
        let c = t[i]
        var j = i
        while j < l.end, t[j] == c { j += 1 }
        return j - i >= 3 ? (c, j - i, j) : nil
    }

    fileprivate static func fences(_ t: U, _ ls: [Line], skipUntil: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var openAt: Int? = nil
        var open: (UInt16, Int) = (0, 0)
        for l in ls where l.full > skipUntil {
            let f = fence(t, l)
            if openAt == nil {
                if let f { openAt = l.start; open = (f.0, f.1) }
            } else if let f, f.0 == open.0, f.1 >= open.1, isBlank(t, f.2..<l.end) {
                out.append(openAt!..<l.full)
                openAt = nil
            }
        }
        if let openAt { out.append(openAt..<t.count) }
        return out
    }

    fileprivate static func inside(_ spans: [Range<Int>], _ pos: Int) -> Bool {
        spans.contains { $0.contains(pos) }
    }

    /// `[ \t]*<!--co:ID` followed by whitespace or `-->`; the ID and where the match ends.
    fileprivate static func blockStart(_ t: U, _ l: Line) -> (String, Int)? {
        var i = l.start
        while i < l.end, t[i] == sp || t[i] == tab { i += 1 }
        let head = u("<!--co:")
        guard has(t, head, at: i), i + head.count <= l.end else { return nil }
        var j = i + head.count
        let idStart = j
        while j < l.end, isIDUnit(t[j]) { j += 1 }
        let n = j - idStart
        guard n >= 5, n <= 8 else { return nil }
        guard j == l.end || asciiSpace(t[j]) || has(t, u("-->"), at: j) else { return nil }
        return (s(t[idStart..<j]), j)
    }

    fileprivate static func blockSpans(_ t: U, _ ls: [Line], _ ignored: [Range<Int>]) -> [Block] {
        var out: [Block] = []
        var k = 0
        while k < ls.count {
            let l = ls[k]
            if let (id, after) = blockStart(t, l), !inside(ignored, l.start) {
                guard let close = find(t, u("-->"), from: after) else { k += 1; continue }
                var j = k
                while ls[j].full <= close { j += 1 }
                out.append(Block(start: l.start, end: ls[j].full, close: close, id: id))
                k = j + 1
                continue
            }
            k += 1
        }
        return out
    }

    fileprivate static func holdsParagraphBreak(_ t: U, _ r: Range<Int>) -> Bool {
        // `\n[ \t>]*\r?\n`
        var i = r.lowerBound
        while i < r.upperBound {
            if t[i] == nl {
                var j = i + 1
                while j < r.upperBound, t[j] == sp || t[j] == tab || t[j] == gt { j += 1 }
                if j < r.upperBound, t[j] == cr { j += 1 }
                if j < r.upperBound, t[j] == nl { return true }
            }
            i += 1
        }
        return false
    }

    fileprivate static func codeSpans(_ t: U, _ segments: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for seg in segments {
            var i = seg.lowerBound
            let b = seg.upperBound
            while i < b {
                guard let j = t[i..<b].firstIndex(of: backtick) else { break }
                var n = j
                while n < b, t[n] == backtick { n += 1 }
                let run = n - j
                var k = n
                var found: Int? = nil
                while k < b {
                    guard let kk = t[k..<b].firstIndex(of: backtick) else { break }
                    var e = kk
                    while e < b, t[e] == backtick { e += 1 }
                    if e - kk == run { found = e; break }
                    k = e
                }
                if let found, !holdsParagraphBreak(t, j..<found) {
                    out.append(j..<found)
                    i = found
                } else {
                    i = n
                }
            }
        }
        return out
    }

    fileprivate static func regions(_ t: U) -> Regions {
        let ls = lines(t)
        let fm = frontMatter(t, ls)
        let coarse = (fm.map { [$0] } ?? []) + fences(t, ls, skipUntil: fm?.upperBound ?? 0)
        let blocks = blockSpans(t, ls, coarse)
        let segs = segments(t, ls, blocks, fm)
        let icode = segs.filter { $0.kind == "icode" }.map { ls[$0.first].start..<ls[$0.last].full }
        let coarseAll = (coarse + icode).sorted { $0.lowerBound < $1.lowerBound }
        let walls = (coarseAll + blocks.map { $0.start..<$0.end }).sorted { $0.lowerBound < $1.lowerBound }
        var segments: [Range<Int>] = []
        var pos = 0
        for w in walls {
            if w.lowerBound > pos { segments.append(pos..<w.lowerBound) }
            pos = max(pos, w.upperBound)
        }
        if pos < t.count { segments.append(pos..<t.count) }
        let ignored = (coarseAll + codeSpans(t, segments)).sorted { $0.lowerBound < $1.lowerBound }
        return Regions(lines: ls, frontMatter: fm, ignored: ignored, blocks: blocks, segs: segs)
    }

    /// Front matter, ``` and ~~~ fences, indented code blocks, and inline code spans.
    static func ignoredRegions(_ text: String) -> [Range<Int>] { regions(u(text)).ignored }

    // MARK: markers

    fileprivate struct Marker { var id: String; var range: Range<Int>; var closing: Bool }

    fileprivate static func markers(_ t: U) -> [Marker] {
        var out: [Marker] = []
        let head = u("<!--")
        var i = 0
        while let j = find(t, head, from: i) {
            var k = j + 4
            var closing = false
            if k < t.count, t[k] == 47 { closing = true; k += 1 }  // "/"
            if k + 1 < t.count, t[k] == 99, t[k + 1] == colon {  // "c:"
                let idStart = k + 2
                var e = idStart
                while e < t.count, isIDUnit(t[e]) { e += 1 }
                let n = e - idStart
                if n >= 5, n <= 8, has(t, u("-->"), at: e) {
                    out.append(Marker(id: s(t[idStart..<e]), range: j..<(e + 3), closing: closing))
                    i = e + 3
                    continue
                }
            }
            i = j + 1
        }
        return out
    }

    fileprivate static func liveMarkers(_ t: U, _ r: Regions) -> [Marker] {
        let walls = r.ignored + r.blocks.map { $0.start..<$0.end }
        return markers(t).filter { !inside(walls, $0.range.lowerBound) }
    }

    fileprivate static func stripMarkers(_ t: U, _ range: Range<Int>) -> String {
        var out: U = []
        var i = range.lowerBound
        let ms = markers(Array(t[range])).map { ($0.range.lowerBound + range.lowerBound)..<($0.range.upperBound + range.lowerBound) }
        var mi = 0
        while i < range.upperBound {
            if mi < ms.count, ms[mi].lowerBound == i { i = ms[mi].upperBound; mi += 1; continue }
            out.append(t[i])
            i += 1
        }
        return s(out[...])
    }

    /// The markers that are comment markup (outside code and thread blocks): UTF-16 range, id, closing.
    static func liveMarkers(_ text: String) -> [(range: Range<Int>, id: String, closing: Bool)] {
        let t = u(text)
        return liveMarkers(t, regions(t)).map { ($0.range, $0.id, $0.closing) }
    }

    static func stripMarkers(_ text: String) -> String {
        let t = u(text)
        return stripMarkers(t, 0..<t.count)
    }

    // MARK: header and thread lines

    /// A header value inside double quotes: newlines as spaces, then `\` → `\\`, `"` → `\"`, `-->` → `--\>`.
    static func escapeQuoted(_ v: String) -> String {
        v.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "-->", with: "--\\>")
    }

    static func unescapeQuoted(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let cs = Array(text.unicodeScalars)
        var i = 0
        while i < cs.count {
            if cs[i] == "\\", i + 1 < cs.count, cs[i + 1] == "\\" || cs[i + 1] == "\"" || cs[i + 1] == ">" {
                out.append(cs[i + 1])
                i += 2
            } else {
                out.append(cs[i])
                i += 1
            }
        }
        return String(out)
    }

    nonisolated(unsafe) fileprivate static let bodyArrowRE = rx(#"--(\\*)>"#)
    nonisolated(unsafe) fileprivate static let bodyArrowBackRE = rx(#"--\\(\\*)>"#)

    /// A reply's text: one more backslash between `--` and `>`, so it never closes the block.
    static func escapeBody(_ v: String) -> String {
        bodyArrowRE.stringByReplacingMatches(
            in: v, range: NSRange(location: 0, length: v.utf16.count), withTemplate: "--$1\\\\>")
    }

    static func unescapeBody(_ v: String) -> String {
        bodyArrowBackRE.stringByReplacingMatches(
            in: v, range: NSRange(location: 0, length: v.utf16.count), withTemplate: "--$1>")
    }

    fileprivate static func isKeyStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    fileprivate static func headerFields(_ t: U, _ a: Int, _ b: Int) -> [(Field, String)] {
        var out: [(Field, String)] = []
        var i = a
        while i < b {
            while i < b, t[i] == sp || t[i] == tab { i += 1 }
            if i >= b { break }
            var k = i
            if isKeyStart(t[k]) {
                k += 1
                while k < b, isWordUnit(t[k]) || t[k] == dash { k += 1 }
            }
            guard k > i, k < b, t[k] == colon else {
                while i < b, t[i] != sp, t[i] != tab { i += 1 }
                continue
            }
            let key = s(t[i..<k])
            i = k + 1
            if i < b, t[i] == quoteMark {
                var j = i + 1
                while j < b, t[j] != quoteMark { j += t[j] == backslash && j + 1 < b ? 2 : 1 }
                let vs = i + 1, ve = min(j, b)
                out.append((Field(key: key, range: vs..<ve), unescapeQuoted(s(t[vs..<ve]))))
                i = j + 1
            } else {
                var j = i
                while j < b, t[j] != sp, t[j] != tab { j += 1 }
                out.append((Field(key: key, range: i..<j), unescapeQuoted(s(t[i..<j]))))
                i = j
            }
        }
        return out
    }

    /// `^(.*?)(?:\s\(([^)]*)\))?:\s?(.*)$` — name, time, text.
    fileprivate static func replyMatch(_ line: String) -> (String, String?, String)? {
        let cs = Array(line.unicodeScalars)
        func str(_ r: Range<Int>) -> String { String(String.UnicodeScalarView(cs[r])) }
        func rest(_ from: Int) -> String {
            var f = from
            if f < cs.count, cs[f].properties.isWhitespace { f += 1 }
            return str(f..<cs.count)
        }
        var k = 0
        while k < cs.count {
            if cs[k].properties.isWhitespace, k + 1 < cs.count, cs[k + 1] == "(" {
                if let j = cs[(k + 2)...].firstIndex(of: ")"), j + 1 < cs.count, cs[j + 1] == ":" {
                    return (str(0..<k), str((k + 2)..<j), rest(j + 2))
                }
            }
            if cs[k] == ":" { return (str(0..<k), nil, rest(k + 1)) }
            k += 1
        }
        return nil
    }

    fileprivate static func isBlankString(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    fileprivate static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    fileprivate static func threadLines(_ raw: [String]) -> ([Reply], [String]) {
        var replies: [Reply] = []
        var reactions: [String] = []
        for line in raw {
            if line.hasPrefix("\\") {
                if !replies.isEmpty { replies[replies.count - 1].text += "\n" + unescapeBody(String(line.dropFirst())) }
                continue
            }
            if blankLine(line) { continue }
            if line.hasPrefix("+") { reactions.append(line); continue }
            if let m = replyMatch(line), !trimmed(m.0).isEmpty {
                replies.append(Reply(author: trimmed(m.0), at: m.1, text: unescapeBody(m.2)))
            } else if !replies.isEmpty {
                replies[replies.count - 1].text += "\n" + unescapeBody(line)
            }
        }
        return (replies, reactions)
    }

    // MARK: parse

    static func parse(_ text: String) -> Parsed { parse(u(text)) }

    fileprivate static func parse(_ t: U) -> Parsed {
        let r = regions(t)
        let ms = liveMarkers(t, r)
        var threads: [Thread] = []
        var seen = Set<String>()
        for b in r.blocks {
            seen.insert(b.id)
            var headerEnd = t[b.start...].firstIndex(of: nl) ?? b.end
            if headerEnd >= b.close { headerEnd = b.end }
            var hb = min(b.close, headerEnd)
            if hb > b.start, t[hb - 1] == cr { hb -= 1 }
            let headFrom = find(t, u("<!--co:"), from: b.start)! + 7 + b.id.utf16.count
            let fields = headerFields(t, headFrom, hb)
            var values: [String: String] = [:]
            for (f, v) in fields where values[f.key] == nil { values[f.key] = v }
            var raw: [String] = []
            if b.close > hb {
                let body = s(t[hb..<b.close])
                raw = body.components(separatedBy: "\n").dropFirst().map {
                    $0.hasSuffix("\r") ? String($0.dropLast()) : $0
                }
            }
            let (replies, reactions) = threadLines(raw)
            var anchor: Range<Int>? = nil
            if let o = ms.first(where: { $0.id == b.id && !$0.closing }),
                let c = ms.first(where: { $0.id == b.id && $0.closing && $0.range.lowerBound >= o.range.upperBound })
            {
                anchor = o.range.upperBound..<c.range.lowerBound
            }
            threads.append(
                Thread(
                    id: b.id, by: values["by"] ?? "", at: values["at"] ?? "",
                    status: values["status"] == "resolved" ? .resolved : .open,
                    quote: values["quote"] ?? "", replies: replies, reactions: reactions,
                    block: b.start..<b.end, anchor: anchor, fields: fields.map(\.0), close: b.close))
        }
        var orphans: [String] = []
        for m in ms.filter({ !$0.closing }) + ms.filter({ $0.closing })
        where !seen.contains(m.id) && !orphans.contains(m.id) {
            orphans.append(m.id)
        }
        return Parsed(threads: threads, orphanAnchors: orphans)
    }

    /// The anchored text, with any comment markers inside it removed; nil for an orphan thread.
    static func anchoredText(_ text: String, _ thread: Thread) -> String? {
        guard let a = thread.anchor else { return nil }
        return stripMarkers(u(text), a)
    }

    /// The anchored source as a reader sees it, for a header's `quote`.
    static func quoteText(_ source: String) -> String {
        let cs = Array(stripMarkers(source).unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < cs.count {
            var j = i
            if cs[j] == "\r", j + 1 < cs.count, cs[j + 1] == "\n" { j += 1 }
            if cs[j] == "\n" {
                j += 1
                while j < cs.count, cs[j] == " " || cs[j] == "\t" { j += 1 }
                while j < cs.count, cs[j] == ">" {
                    j += 1
                    if j < cs.count, cs[j] == " " || cs[j] == "\t" { j += 1 }
                }
                out.append(" ")
                i = j
                continue
            }
            out.append(cs[i])
            i += 1
        }
        return String(out)
    }

    // MARK: words

    fileprivate static func isWordScalar(_ sc: Unicode.Scalar) -> Bool {
        sc == "_" || sc.properties.isAlphabetic || sc.properties.numericType != nil
    }

    fileprivate static func isWordUnit(_ c: UInt16) -> Bool {
        guard let sc = Unicode.Scalar(c) else { return false }
        return isWordScalar(sc)
    }

    fileprivate static func scalar(_ t: U, _ i: Int) -> Unicode.Scalar? {
        let c = t[i]
        if UTF16.isLeadSurrogate(c), i + 1 < t.count, UTF16.isTrailSurrogate(t[i + 1]) {
            return Unicode.Scalar(UTF16.decode(UTF16.EncodedScalar([c, t[i + 1]])).value)
        }
        if UTF16.isTrailSurrogate(c), i > 0, UTF16.isLeadSurrogate(t[i - 1]) {
            return Unicode.Scalar(UTF16.decode(UTF16.EncodedScalar([t[i - 1], c])).value)
        }
        return Unicode.Scalar(c)
    }

    fileprivate static func isWord(_ t: U, _ i: Int) -> Bool {
        guard i >= 0, i < t.count, let sc = scalar(t, i) else { return false }
        if isWordScalar(sc) { return true }
        if sc == "'" || sc == "\u{2019}" {
            return i > 0 && i + 1 < t.count && (scalar(t, i - 1).map(isWordScalar) ?? false)
                && (scalar(t, i + 1).map(isWordScalar) ?? false)
        }
        return false
    }

    fileprivate static func snap(_ t: U, _ r: Range<Int>) -> Range<Int> {
        var a = r.lowerBound, b = r.upperBound
        while a > 0, isWord(t, a - 1), isWord(t, a) { a -= 1 }
        while b < t.count, isWord(t, b), isWord(t, b - 1) { b += 1 }
        return a..<b
    }

    /// Widen each end outward to a word boundary; never narrows, never crosses a marker.
    static func snapToWords(_ text: String, _ range: Range<Int>) -> Range<Int> { snap(u(text), range) }

    // MARK: blocks

    /// Where a new thread block goes for an anchor at `offset`: after the top-level block.
    static func blockEnd(_ text: String, offset: Int) -> Int { blockEnd(u(text), offset: offset) }

    fileprivate static func blockEnd(_ t: U, offset: Int) -> Int {
        let r = regions(t)
        let ls = r.lines
        guard !ls.isEmpty else { return t.count }
        let k = ls.indices.first { offset < ls[$0].full } ?? ls.count - 1
        let last = r.segs.first { $0.first <= k && k <= $0.last }?.last ?? k
        var pos = ls[last].full
        while let next = r.blocks.first(where: { $0.start == pos }) { pos = next.end }
        return pos
    }

    // MARK: finding a quote

    fileprivate struct Visible {
        var chars: U = []
        var src: [Int] = []
        var ignored: [Bool] = []
        var breaks: [Bool] = []

        mutating func space(_ i: Int, _ ig: Bool, _ brk: Bool) {
            if chars.last == CommentFormat.sp {
                if brk { breaks[breaks.count - 1] = true }
                return
            }
            chars.append(CommentFormat.sp); src.append(i); ignored.append(ig); breaks.append(brk)
        }
    }

    fileprivate static func asciiSpace(_ c: UInt16) -> Bool { c == 32 || (c >= 9 && c <= 13) }

    fileprivate static func anchoredMatch(_ re: NSRegularExpression, _ ns: NSString, _ i: Int, _ b: Int) -> NSRange? {
        let m = re.firstMatch(in: ns as String, options: [.anchored], range: NSRange(location: i, length: b - i))
        return m?.range
    }

    /// The `]` matching the `[` at `i`, within one paragraph.
    fileprivate static func bracketEnd(_ t: U, _ i: Int, _ b: Int) -> Int? {
        var depth = 0
        var j = i
        while j < b {
            let c = t[j]
            if c == backslash { j += 2; continue }
            if c == 91 { depth += 1 }  // [
            else if c == 93 {  // ]
                depth -= 1
                if depth == 0 { return j }
            } else if c == nl, paragraphBreakAhead(t, j + 1, quote: true) { return nil }
            j += 1
        }
        return nil
    }

    fileprivate static func paragraphBreakAhead(_ t: U, _ k: Int, quote: Bool) -> Bool {
        var j = k
        let limit = min(t.count, k + 40)
        while j < limit, t[j] == sp || t[j] == tab || (quote && t[j] == gt) { j += 1 }
        if j < limit, t[j] == cr { j += 1 }
        return j < limit && t[j] == nl
    }

    /// The end of `(dest "title")` or `[ref]` right after a link's text, else nil.
    fileprivate static func linkTail(_ t: U, _ i: Int, _ b: Int) -> Int? {
        guard i < b else { return nil }
        if t[i] == 40 {  // (
            var depth = 0
            var j = i
            while j < b {
                let c = t[j]
                if c == backslash { j += 2; continue }
                if c == 40 { depth += 1 }
                else if c == 41 {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                } else if c == nl, paragraphBreakAhead(t, j + 1, quote: false) { return nil }
                j += 1
            }
            return nil
        }
        if t[i] == 91, let j = t[(i + 1)..<b].firstIndex(of: 93), !t[i..<j].contains(nl) { return j + 1 }
        return nil
    }

    /// Link destinations and brackets, whole images, HTML tags and comments, autolink brackets.
    fileprivate static func inlineWalls(_ t: U, _ ns: NSString, _ a: Int, _ b: Int, _ out: inout [Range<Int>]) {
        var i = a
        while i < b {
            let c = t[i]
            if c == backslash { i += 2; continue }
            if c == lt {
                if let m = anchoredMatch(autolinkRE, ns, i, b) {
                    out.append(i..<(i + 1)); out.append((m.upperBound - 1)..<m.upperBound)
                    i = m.upperBound
                    continue
                }
                if let m = markerAt(t, i), m.range.upperBound <= b { i = m.range.upperBound; continue }
                if has(t, u("<!--"), at: i) {
                    let e = find(t, u("-->"), from: i + 4, to: b).map { $0 + 3 } ?? b
                    out.append(i..<e)
                    i = e
                    continue
                }
                if let m = anchoredMatch(tagRE, ns, i, b) {
                    out.append(i..<m.upperBound)
                    i = m.upperBound
                    continue
                }
            }
            if c == 33, i + 1 < b, t[i + 1] == 91, let close = bracketEnd(t, i + 1, b) {  // ![
                let e = linkTail(t, close + 1, b) ?? (close + 1)
                out.append(i..<e)
                i = e
                continue
            }
            if c == 91, let close = bracketEnd(t, i, b), let e = linkTail(t, close + 1, b) {
                out.append(i..<(i + 1)); out.append(close..<e)
                inlineWalls(t, ns, i + 1, close, &out)
                i = e
                continue
            }
            i += 1
        }
    }

    fileprivate static func markerAt(_ t: U, _ i: Int) -> Marker? {
        guard has(t, u("<!--"), at: i) else { return nil }
        return markers(Array(t[i..<min(t.count, i + 20)])).first { $0.range.lowerBound == 0 }
            .map { Marker(id: $0.id, range: (i + $0.range.lowerBound)..<(i + $0.range.upperBound), closing: $0.closing) }
    }

    /// The text as a reader sees it: markers zero-width, quote prefixes as whitespace,
    /// whitespace runs as one space; code searchable but flagged; thread blocks, link
    /// destinations and brackets, images, HTML tags and comments, autolink brackets and
    /// link reference definitions are walls nothing matches across.
    fileprivate static func visible(_ t: U) -> Visible {
        let r = regions(t)
        let ns = s(t[...]) as NSString
        var walls = r.blocks.map { $0.start..<$0.end }
        let hidden = (r.ignored + walls).sorted { $0.lowerBound < $1.lowerBound }
        for l in r.lines where !inside(hidden, l.start) && match(refdefRE, lineText(t, l)) {
            walls.append(l.start..<l.end)
        }
        var segments: [Range<Int>] = []
        var pos = 0
        for w in (hidden + walls).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if w.lowerBound > pos { segments.append(pos..<w.lowerBound) }
            pos = max(pos, w.upperBound)
        }
        if pos < t.count { segments.append(pos..<t.count) }
        for seg in segments { inlineWalls(t, ns, seg.lowerBound, seg.upperBound, &walls) }
        var wallAt: [Int: Int] = [:]
        for w in walls where (wallAt[w.lowerBound] ?? -1) < w.upperBound { wallAt[w.lowerBound] = w.upperBound }
        let ms = markers(t).map(\.range)
        let segEnds = Set(r.segs.map { r.lines[$0.last].end })
        var v = Visible()
        var prefixEnds: [Int: Int] = [:]
        for l in r.lines {
            var i = l.start
            while i < l.end, t[i] == sp || t[i] == tab { i += 1 }
            guard i < l.end, t[i] == gt else { continue }
            while i < l.end, t[i] == gt {
                i += 1
                if i < l.end, t[i] == sp || t[i] == tab { i += 1 }
            }
            prefixEnds[l.start] = i
        }
        var i = 0
        var mi = 0
        while i < t.count {
            if let w = wallAt[i] {
                v.chars.append(0); v.src.append(i); v.ignored.append(false); v.breaks.append(false)
                i = max(w, i + 1)
                continue
            }
            if let stop = prefixEnds[i] {
                v.space(i, false, false)
                i = stop
                continue
            }
            while mi < ms.count, ms[mi].upperBound <= i { mi += 1 }
            if mi < ms.count, ms[mi].lowerBound == i { i = ms[mi].upperBound; continue }
            let c = t[i]
            if asciiSpace(c) {
                var brk = false
                if c == nl || (c == cr && i + 1 < t.count && t[i + 1] == nl) {
                    brk = segEnds.contains(i)
                    if c == nl {
                        let k = i + 1
                        let e = t[k...].firstIndex(of: nl) ?? t.count
                        let rest = t[k..<e].allSatisfy { $0 == sp || $0 == tab || $0 == cr || $0 == gt }
                        if rest, e < t.count { brk = true }
                    }
                }
                v.space(i, inside(r.ignored, i), brk)
                i += 1
                continue
            }
            v.chars.append(c); v.src.append(i); v.ignored.append(inside(r.ignored, i)); v.breaks.append(false)
            i += 1
        }
        return v
    }

    fileprivate static func normalise(_ q: String) -> U {
        var out: U = []
        for c in u(q) {
            if asciiSpace(c) {
                if out.last != sp { out.append(sp) }
            } else {
                out.append(c)
            }
        }
        while out.first == sp { out.removeFirst() }
        while out.last == sp { out.removeLast() }
        return out
    }

    /// The `occurrence`-th (1-based) match of `quote`, snapped to words, or why it can't be anchored.
    static func findQuote(_ text: String, _ quote: String, occurrence: Int = 1) -> Result<Range<Int>, Refusal> {
        let t = u(text)
        let v = visible(t)
        return matches(t, v, normalise(quote), occurrence: occurrence, within: nil)
    }

    fileprivate static func matches(_ t: U, _ v: Visible, _ q: U, occurrence: Int, within: Range<Int>?)
        -> Result<Range<Int>, Refusal>
    {
        guard !q.isEmpty else { return .failure(.notFound) }
        var good: [Range<Int>] = []
        var inCode = false, crosses = false
        var i = find(v.chars, q, from: 0)
        while let a = i {
            let b = a + q.count
            let span = v.src[a]..<(v.src[b - 1] + 1)
            if let within, !(within.contains(span.lowerBound) && span.upperBound <= within.upperBound) {
                // outside the block asked about
            } else if v.ignored[a..<b].contains(true) {
                inCode = true
            } else if v.breaks[a..<b].contains(true) {
                crosses = true
            } else {
                good.append(span)
            }
            i = find(v.chars, q, from: b)
        }
        if occurrence >= 1, occurrence <= good.count { return .success(snap(t, good[occurrence - 1])) }
        if !good.isEmpty { return .failure(.occurs(good.count)) }
        if inCode { return .failure(.insideIgnored) }
        if crosses { return .failure(.crossesBlocks) }
        return .failure(.notFound)
    }

    /// Like `findQuote`, but only matches whose source lies inside `range`
    /// (a rendered block's source lines); `occurrence` is 1-based.
    static func findQuote(_ text: String, _ quote: String, occurrence: Int, within range: Range<Int>)
        -> Result<Range<Int>, Refusal>
    {
        let t = u(text)
        return matches(t, visible(t), normalise(quote), occurrence: occurrence, within: range)
    }

    // MARK: IDs and time

    static func newID(in text: String, using rng: inout some RandomNumberGenerator) -> String {
        var taken = Set<String>()
        let t = u(text)
        var i = 0
        while let j = find(t, u("<!--"), from: i) {
            var k = j + 4
            if k < t.count, t[k] == 47 { k += 1 }
            if k < t.count, t[k] == 99 {
                k += 1
                if k < t.count, t[k] == 111 { k += 1 }
                if k < t.count, t[k] == colon {
                    let st = k + 1
                    var e = st
                    while e < t.count, isIDUnit(t[e]) { e += 1 }
                    if e > st { taken.insert(s(t[st..<e])) }
                }
            }
            i = j + 1
        }
        for _ in 0..<1000 {
            let c = String((0..<5).map { _ in idCharacters.randomElement(using: &rng)! })
            if !taken.contains(c) { return c }
        }
        while true {
            let c = String((0..<8).map { _ in idCharacters.randomElement(using: &rng)! })
            if !taken.contains(c) { return c }
        }
    }

    /// `YYYY-MM-DDTHH:MM:SS.mmmZ`, UTC.
    static func timestamp(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let whole = Date(timeIntervalSince1970: TimeInterval(ms.quotientAndRemainder(dividingBy: 1000).quotient))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        let rem = ((ms % 1000) + 1000) % 1000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
            Int(rem))
    }

    // MARK: edits

    fileprivate struct Edit { var start: Int; var end: Int; var insert: String; var order: Int }

    fileprivate static func splice(_ t: U, _ edits: [Edit]) -> String {
        var out: U = []
        var cur = 0
        for e in edits.sorted(by: { ($0.start, $0.order) < ($1.start, $1.order) }) {
            if e.start > cur { out += t[cur..<e.start] }
            out += u(e.insert)
            cur = max(cur, e.end)
        }
        if cur < t.count { out += t[cur...] }
        return s(out[...])
    }

    fileprivate static func orphanEdits(_ t: U) -> [Edit] {
        let r = regions(t)
        let ids = Set(r.blocks.map(\.id))
        return liveMarkers(t, r).filter { !ids.contains($0.id) }.map {
            Edit(start: $0.range.lowerBound, end: $0.range.upperBound, insert: "", order: 1)
        }
    }

    fileprivate static func field(_ v: String, always: Bool = false) -> String {
        if always || v.contains(" ") || v.contains("\t") || v.contains("\"") || v.contains("\\") || v.contains("-->") {
            return "\"" + escapeQuoted(v) + "\""
        }
        return v
    }

    fileprivate static func replyLines(author: String, at: String, body: String) -> [String] {
        let parts = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out = ["\(author) (\(at)): " + escapeBody(parts[0])]
        for raw in parts.dropFirst() {
            var line = escapeBody(raw)
            // A leading backslash keeps a line that would read as a reply, a reaction, an
            // escaped line or a blank line as this reply's text (read back without it).
            if blankLine(line) || line.hasPrefix("\\") || line.hasPrefix("+")
                || (replyMatch(line).map { !trimmed($0.0).isEmpty } ?? false)
            {
                line = "\\" + line
            }
            out.append(line)
        }
        return out
    }

    fileprivate static func thread(_ t: U, _ id: String) throws -> Thread {
        guard let th = parse(t).threads.first(where: { $0.id == id }) else { throw EditError.unknownThread(id) }
        return th
    }

    static func addThread(_ text: String, range: Range<Int>, id: String, author: String, at: String, body: String)
        -> String
    {
        let t = u(text)
        let eol = lineEnding(text)
        let quote = quoteText(s(t[range]))
        let block = (["<!--co:\(id) by:\(field(author)) at:\(field(at)) status:open quote:\(field(quote, always: true))"]
            + replyLines(author: author, at: at, body: body) + ["-->"]).joined(separator: eol)
        let p = blockEnd(t, offset: range.lowerBound)
        let insert = p == t.count && t.last != nl ? eol + block : block + eol
        var edits = orphanEdits(t)
        edits += [
            Edit(start: p, end: p, insert: insert, order: 2),
            Edit(start: range.upperBound, end: range.upperBound, insert: "<!--/c:\(id)-->", order: 0),
            Edit(start: range.lowerBound, end: range.lowerBound, insert: "<!--c:\(id)-->", order: 3),
        ]
        return splice(t, edits)
    }

    static func addReply(_ text: String, threadID: String, author: String, at: String, body: String) throws -> String {
        let t = u(text)
        let th = try thread(t, threadID)
        let eol = lineEnding(text)
        let lines = replyLines(author: author, at: at, body: body).joined(separator: eol)
        let ls = (t[..<th.close].lastIndex(of: nl) ?? -1) + 1
        let edit =
            isBlank(t, ls..<th.close)
            ? Edit(start: ls, end: ls, insert: lines + eol, order: 0)
            : Edit(start: th.close, end: th.close, insert: eol + lines + eol, order: 0)
        return splice(t, orphanEdits(t) + [edit])
    }

    static func setStatus(_ text: String, threadID: String, _ status: Status) throws -> String {
        let t = u(text)
        let th = try thread(t, threadID)
        let edit: Edit
        if let f = th.fields.first(where: { $0.key == "status" }) {
            // The first status field is the one read; left as written when it already says so.
            let current = unescapeQuoted(s(t[f.range]))
            edit = Edit(start: f.range.lowerBound, end: f.range.upperBound,
                        insert: current == status.rawValue ? s(t[f.range]) : status.rawValue, order: 0)
        } else if status == .open {
            return splice(t, orphanEdits(t))  // no status field reads as open already
        } else {
            var pos = th.block.lowerBound + 7 + th.id.utf16.count
            if let at = th.fields.first(where: { $0.key == "at" }) {
                pos = at.range.upperBound + (at.range.upperBound < t.count && t[at.range.upperBound] == quoteMark ? 1 : 0)
            }
            edit = Edit(start: pos, end: pos, insert: " status:\(status.rawValue)", order: 0)
        }
        return splice(t, orphanEdits(t) + [edit])
    }
}
