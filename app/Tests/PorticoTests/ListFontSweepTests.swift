import Foundation
import XCTest

/// v0.15 §3.3, amended 11-02: a `List`'s rows and section headers use the
/// list's own default font when they set none, and that font ignores the
/// text scale (the Files tree's names did not grow). So in every source file
/// that builds a `List`, each `Text(...)` or `Label(...)` view must carry a
/// `.scaledFont(...)` (or, for a symbol's size, `.font(Theme.iconFont(...))`)
/// in its own modifier chain. Any other `.font` (`.body`, `.headline`) is a
/// fixed size and fails.
///
/// A `Text` passed as an argument (`description: Text(...)`) and a button's
/// `label: { ... }` are styled by the view they are given to (the button
/// style sets the size), so they are not checked.
/// The check is per file, not per `List` body, because the rows a list draws
/// are usually separate views in the same file (`FileLine`, `FileRow`).
final class ListFontSweepTests: XCTestCase {
    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Portico")
    }

    func test_every_text_in_a_list_file_sets_its_size() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var listFiles: [String] = []
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = Self.withoutComments(try String(contentsOf: url, encoding: .utf8))
            guard Self.buildsAList(text) else { continue }
            listFiles.append(url.lastPathComponent)
            offenders += Self.unsizedViews(in: text).map { "\(url.lastPathComponent):\($0)" }
        }
        XCTAssertTrue(listFiles.contains("FilesView.swift"), "the scan must find the Files tree: \(listFiles)")
        XCTAssertTrue(listFiles.contains("DocumentView.swift"), "and the document view's lists: \(listFiles)")
        XCTAssertEqual(offenders, [], "Text/Label in a List file with no .scaledFont (or a fixed .font): \(offenders)")
    }

    func test_the_checker_catches_an_unsized_row() {
        let source = """
            List {
                Text("a")
                Text("b").scaledFont(13)
                Label("c", systemImage: "folder")
                    .help("x")
                    .scaledFont(11, weight: .semibold)
                ContentUnavailableView("x", systemImage: "y", description: Text("passed in"))
                Label(name, systemImage: "folder")
                    .help(path)
                Button {
                } label: {
                    Label("styled by the button", systemImage: "x")
                }
                Text("fixed").font(.body)
                Text("fixed too")
                    .font(.headline)
                Label("icon sized", systemImage: "x").font(Theme.iconFont(11))
            }
            """
        XCTAssertTrue(Self.buildsAList(source))
        XCTAssertEqual(Self.unsizedViews(in: source), [2, 8, 14, 15])
        XCTAssertFalse(Self.buildsAList(Self.withoutComments("ScrollView { Text(\"a\") } // List {")))
    }

    // MARK: - the checker

    static func buildsAList(_ text: String) -> Bool {
        text.range(of: #"(?<![A-Za-z])List\s*(\{|\()"#, options: .regularExpression) != nil
    }

    /// Strips `//` comments (a `//` at a line start or after a space), so a
    /// comment that names `List {` or `Text(` does not count.
    static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            if let range = line.range(of: #"(^|\s)//"#, options: .regularExpression) { return line[..<range.lowerBound] }
            return line
        }.joined(separator: "\n")
    }

    /// The line numbers of `Text(`/`Label(` views with no size in their chain.
    static func unsizedViews(in text: String) -> [Int] {
        let chars = Array(text)
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(Text|Label)\("#)
        var lines: [Int] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let start = text.distance(
                from: text.startIndex, to: Range(match.range, in: text)!.lowerBound)
            // An argument (`description: Text(...)`, `f(Text(...))`) is styled by its receiver.
            var back = start - 1
            while back >= 0, chars[back] == " " { back -= 1 }
            if back >= 0, [":", "(", ","].contains(chars[back]) { continue }
            // A button's `label: { Label(...) }` is sized by its button style.
            if Self.isButtonLabel(chars, before: start) { continue }
            let open = start + match.range.length - 1
            guard var index = closing(chars, from: open) else { continue }
            var sized = false
            // The chain: `.name(...)` or `.name` after optional whitespace and newlines.
            while true {
                var next = index + 1
                while next < chars.count, chars[next].isWhitespace { next += 1 }
                guard next < chars.count, chars[next] == "." else { break }
                var end = next + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                let name = String(chars[(next + 1)..<end])
                if end < chars.count, chars[end] == "(" {
                    guard let close = closing(chars, from: end) else { break }
                    let argument = String(chars[(end + 1)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if name == "scaledFont" || (name == "font" && argument.hasPrefix("Theme.iconFont")) { sized = true }
                    index = close
                } else {
                    index = end - 1
                }
                // A trailing closure (`.overlay { ... }`) belongs to the chain too.
                var brace = index + 1
                while brace < chars.count, chars[brace] == " " { brace += 1 }
                if brace < chars.count, chars[brace] == "{", let close = closing(chars, from: brace, open: "{", close: "}") {
                    index = close
                }
            }
            if !sized {
                lines.append(chars[..<start].filter { $0 == "\n" }.count + 1)
            }
        }
        return lines
    }

    /// Whether the view starting at `start` opens a `label: { ... }` closure.
    static func isButtonLabel(_ chars: [Character], before start: Int) -> Bool {
        var back = start - 1
        while back >= 0, chars[back].isWhitespace { back -= 1 }
        guard back >= 0, chars[back] == "{" else { return false }
        back -= 1
        while back >= 0, chars[back].isWhitespace { back -= 1 }
        let word = "label:"
        guard back + 1 >= word.count else { return false }
        return String(chars[(back + 1 - word.count)...back]) == word
    }

    /// The index of the bracket that closes the one at `from`, skipping string literals.
    static func closing(_ chars: [Character], from: Int, open: Character = "(", close: Character = ")") -> Int? {
        var depth = 0
        var inString = false
        var index = from
        while index < chars.count {
            let c = chars[index]
            if inString {
                if c == "\\" { index += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }
}
