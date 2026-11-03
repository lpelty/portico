import AppKit
import Foundation
import XCTest
@testable import Portico

/// v0.17 §4.2–4.3: tooltips at 0.8 s, every icon-only button names itself,
/// and file panels drop from the window as sheets.
final class SmallItemsV017Tests: XCTestCase {
    // MARK: - tooltip delay

    private func freshSuite() -> (UserDefaults, String) {
        let name = "portico.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return (suite, name)
    }

    func test_tooltip_delay_registers_800_ms_without_persisting() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        TooltipDelay.register(in: suite)
        XCTAssertEqual(suite.integer(forKey: "NSInitialToolTipDelay"), 800)
        XCTAssertEqual(TooltipDelay.milliseconds, 800)
        XCTAssertNil(suite.persistentDomain(forName: name)?["NSInitialToolTipDelay"], "a registered default, never written")
    }

    func test_a_value_the_person_already_set_wins() {
        let (suite, name) = freshSuite()
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(1500, forKey: "NSInitialToolTipDelay")
        TooltipDelay.register(in: suite)
        XCTAssertEqual(suite.integer(forKey: "NSInitialToolTipDelay"), 1500)
    }

    // MARK: - file panels

    func test_no_open_panel_runs_modal() throws {
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "FilePanel.swift" {
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            if text.contains(".runModal()") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "open panels go through FilePanel.present: \(offenders)")
    }

    // MARK: - icon-only buttons name themselves

    func test_every_icon_only_button_names_itself() throws {
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            offenders += Self.unnamedIconButtons(in: text).map { "\(url.lastPathComponent):\($0)" }
        }
        XCTAssertGreaterThan(scanned, 20)
        XCTAssertEqual(offenders, [], "icon-only Button with no .tip: \(offenders)")
    }

    // MARK: - v0.18 §4.2: no native tooltip left

    func test_no_native_help_left() throws {
        var offenders: [String] = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "Tip.swift" {
            scanned += 1
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            offenders += Self.nativeHelpLines(in: text).map { "\(url.lastPathComponent):\($0)" }
        }
        XCTAssertGreaterThan(scanned, 20)
        XCTAssertEqual(offenders, [], "`.help(` outside Tip.swift; use `.tip(`: \(offenders)")
    }

    func test_the_native_help_checker() {
        let source = """
            Image(systemName: "x")
                .help("Close")
            Button("a") {}.help(text)
            RowActionButton(help: Self.help(control))
            ServiceRowView.help(.restart)
            Button("b") {}.tip("Fine")
            """
        XCTAssertEqual(Self.nativeHelpLines(in: source), [2, 3])
    }

    /// The lines with a `.help(` modifier (not a `Type.help(...)` call).
    static func nativeHelpLines(in text: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])\.help\("#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let start = Range(match.range, in: text)!.lowerBound
            return text[..<start].filter { $0 == "\n" }.count + 1
        }
    }

    func test_the_checker_catches_an_unnamed_icon_button() {
        let source = """
            Button { go() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            Button { go() } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .tip("Settings")
            Button(action: go) { Image(systemName: "plus") }
            Button(action: go) { Image(systemName: "plus") }.tip("Add")
            Button("Title") { go() }
            Button { go() } label: {
                HStack { Image(systemName: "x"); Text("Close") }
            }
            Button { go() } label: { Label("Open", systemImage: "folder") }
            """
        XCTAssertEqual(Self.unnamedIconButtons(in: source), [1, 10])
    }

    /// The line numbers of `Button`s whose label draws only an `Image` and
    /// whose modifier chain has no `.tip(` (v0.18: Portico's own tooltip).
    static func unnamedIconButtons(in text: String) -> [Int] {
        let chars = Array(text)
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])Button\s*(\(|\{)"#)
        var lines: [Int] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let open = text.distance(from: text.startIndex, to: range.upperBound) - 1
            var index = open
            var label: String?
            if chars[open] == "(" {
                guard let close = ListFontSweepTests.closing(chars, from: open) else { continue }
                let args = String(chars[(open + 1)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                // A title string, or a `label:` argument, is checked on its own terms.
                if args.hasPrefix("\"") { continue }
                index = close
                label = Self.trailingLabel(chars, after: &index)
            } else {
                guard let close = ListFontSweepTests.closing(chars, from: open, open: "{", close: "}") else { continue }
                index = close
                label = Self.labelClosure(chars, after: &index)
            }
            guard let body = label, body.contains("Image("), !body.contains("Text("), !body.contains("Label(") else { continue }
            if !Self.chainHasTip(chars, after: index) {
                lines.append(chars[..<start].filter { $0 == "\n" }.count + 1)
            }
        }
        return lines
    }

    /// `Button(action) { label }`: the trailing closure is the label.
    private static func trailingLabel(_ chars: [Character], after index: inout Int) -> String? {
        var next = index + 1
        while next < chars.count, chars[next] == " " { next += 1 }
        guard next < chars.count, chars[next] == "{",
              let close = ListFontSweepTests.closing(chars, from: next, open: "{", close: "}") else { return nil }
        index = close
        return String(chars[(next + 1)..<close])
    }

    /// `Button { action } label: { label }`.
    private static func labelClosure(_ chars: [Character], after index: inout Int) -> String? {
        var next = index + 1
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        let word = Array("label:")
        guard next + word.count <= chars.count, Array(chars[next..<(next + word.count)]) == word else { return nil }
        next += word.count
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        guard next < chars.count, chars[next] == "{",
              let close = ListFontSweepTests.closing(chars, from: next, open: "{", close: "}") else { return nil }
        index = close
        return String(chars[(next + 1)..<close])
    }

    /// Whether `.tip(` appears among the modifiers that follow `index`.
    private static func chainHasTip(_ chars: [Character], after start: Int) -> Bool {
        var index = start
        while true {
            var next = index + 1
            while next < chars.count, chars[next].isWhitespace { next += 1 }
            guard next < chars.count, chars[next] == "." else { return false }
            var end = next + 1
            while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
            let name = String(chars[(next + 1)..<end])
            if name == "tip" { return true }
            if end < chars.count, chars[end] == "(" {
                guard let close = ListFontSweepTests.closing(chars, from: end) else { return false }
                index = close
            } else {
                index = end - 1
            }
            var brace = index + 1
            while brace < chars.count, chars[brace] == " " { brace += 1 }
            if brace < chars.count, chars[brace] == "{",
               let close = ListFontSweepTests.closing(chars, from: brace, open: "{", close: "}") { index = close }
        }
    }
}
