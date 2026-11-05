import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// v0.15 §5.7 (Larry's hand check, 11-02): popovers keep the system glass
/// but put a tint of the window's background behind their content, about 60%
/// opaque, and their secondary text uses `text2`, not the faint `text3`.
final class PopoverSurfaceTests: XCTestCase {
    private static var sources: URL { ListFontSweepTests.sources }

    private func source(_ path: String) throws -> [Character] {
        Array(ListFontSweepTests.withoutComments(
            try String(contentsOf: Self.sources.appendingPathComponent(path), encoding: .utf8)))
    }

    func test_every_popover_puts_the_surface_behind_its_content() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var popovers = 0
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let chars = Array(ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8)))
            let text = String(chars)
            var search = text.startIndex
            while let found = text.range(of: ".popover(", range: search..<text.endIndex) {
                search = found.upperBound
                popovers += 1
                let open = text.distance(from: text.startIndex, to: found.upperBound) - 1
                let line = chars[..<open].filter { $0 == "\n" }.count + 1
                guard let close = ListFontSweepTests.closing(chars, from: open) else {
                    offenders.append("\(url.lastPathComponent):\(line) (unparsed)")
                    continue
                }
                var brace = close + 1
                while brace < chars.count, chars[brace].isWhitespace { brace += 1 }
                guard brace < chars.count, chars[brace] == "{",
                      let end = ListFontSweepTests.closing(chars, from: brace, open: "{", close: "}")
                else {
                    offenders.append("\(url.lastPathComponent):\(line) (no content closure)")
                    continue
                }
                if !String(chars[brace...end]).contains(".popoverSurface()") {
                    offenders.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(popovers, 9, "the scan must find the app's popovers")
        XCTAssertEqual(offenders, [], "popovers without .popoverSurface(): \(offenders)")
    }

    /// The views drawn only inside popovers: no text in the faint `text3`
    /// (a symbol may keep it; the rule is about reading text).
    func test_popover_views_use_text2_for_secondary_text() throws {
        let views: [(file: String, opener: String)] = [
            ("Views/SpaceSwitcher.swift", "private struct SpaceMenu: View {"),
            ("Views/Sidebar/HistoryPopover.swift", "struct HistoryPopover: View {"),
            ("Views/Sidebar/SessionSidebar.swift", "struct EarlierRow: View {"),
            ("Views/Viewer/MarksChip.swift", "struct MarksList: View {"),
            ("Views/StatusStrip.swift", "struct ModelMenu: View {"),
            ("Views/StatusStrip.swift", "struct ModelChoiceRow: View {"),
            ("Views/StatusStrip.swift", "struct ServicesMenu: View {"),
            ("Views/Viewer/SessionFileList.swift", "struct ArtifactMenu: View {"),
            ("Views/Conversation/AgentViews.swift", "struct AgentStepsView: View {"),
            ("Views/Conversation/ModeChip.swift", "private var menu: some View {"),
        ]
        var offenders: [String] = []
        for view in views {
            let chars = try source(view.file)
            let text = String(chars)
            let found = try XCTUnwrap(text.range(of: view.opener), "\(view.opener) not found in \(view.file)")
            let open = text.distance(from: text.startIndex, to: found.upperBound) - 1
            let close = try XCTUnwrap(ListFontSweepTests.closing(chars, from: open, open: "{", close: "}"))
            let body = String(chars[open...close]).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in body.enumerated() where line.contains("Theme.text3") {
                // A symbol: `Image(...)` or an icon font within the few lines before.
                let context = body[max(0, index - 3)...index].joined(separator: "\n")
                let symbol = [context.range(of: "Image(systemName", options: .backwards),
                              context.range(of: "iconFont", options: .backwards)]
                    .compactMap { $0?.upperBound }.max()
                if let symbol, !context[symbol...].contains("Text(") { continue }
                offenders.append("\(view.opener) +\(index): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "text3 text inside popovers: \(offenders)")
    }

    func test_views_shared_with_the_conversation_read_brighter_in_a_popover() {
        XCTAssertEqual(Theme.faintText(inPopover: true), Theme.text2)
        XCTAssertEqual(Theme.faintText(inPopover: false), Theme.text3)
    }
}
