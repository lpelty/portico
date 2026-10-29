import Foundation
import SwiftUI
import XCTest

@testable import Portico

/// The viewer's text, code and tables (v0.5, X1): the CSV/TSV parser, the
/// column widths, reading a capped slice of a file, the extensions that
/// map to `text`, and the presentation's missing and unsupported states.
/// No window.
final class ViewerFilesTests: XCTestCase {

    // MARK: - helpers

    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portico-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func file(_ path: String, media: Media) -> ArtifactPresentation {
        ArtifactPresentation(artifact: Artifact(
            id: "a-1", kind: .file, location: path, media: media,
            title: "", source: .tool, open: false))
    }

    // MARK: - parsing

    func testQuotedCommasQuotesAndNewlinesParse() throws {
        let csv = "region,owner,amount\r\n\"West, North\",\"Dana \"\"D\"\" Ruiz\",\"$48,000\"\r\nEast,\"Priya\nline two\",112500\r\n"
        let table = try XCTUnwrap(DelimitedTable.parse(csv, separator: ","))
        XCTAssertEqual(table.header, ["region", "owner", "amount"])
        XCTAssertEqual(table.rows, [
            ["West, North", "Dana \"D\" Ruiz", "$48,000"],
            ["East", "Priya\nline two", "112500"],
        ])
        XCTAssertEqual(table.numeric, [false, false, true], "a column of numbers, one with $ and a comma, aligns right")
        XCTAssertFalse(table.rowLimitHit)
    }

    func testTSVSplitsOnTabsAndCommasStayInCells() throws {
        let tsv = "\u{FEFF}name\tnote\nalpha\tone, two\nbeta\t\n"
        let table = try XCTUnwrap(DelimitedTable.parse(tsv, separator: "\t"))
        XCTAssertEqual(table.header, ["name", "note"], "the byte-order mark is not part of the first header")
        XCTAssertEqual(table.rows, [["alpha", "one, two"], ["beta", ""]])
    }

    func testEdgesThatStillParse() throws {
        // No final line break; blank lines are skipped; an empty quoted
        // field is a field; a quote inside an unquoted field is a character.
        let csv = "a,b\n\n1,\"\"\n5\" screen,2"
        let table = try XCTUnwrap(DelimitedTable.parse(csv, separator: ","))
        XCTAssertEqual(table.rows, [["1", ""], ["5\" screen", "2"]])
        XCTAssertEqual(table.numeric, [false, true])

        let headerOnly = try XCTUnwrap(DelimitedTable.parse("a,b\n", separator: ","))
        XCTAssertEqual(headerOnly.rows, [])
        XCTAssertEqual(headerOnly.numeric, [false, false], "no values, so not numeric")
    }

    func testWhatIsNotATableFallsBackToText() {
        XCTAssertNil(DelimitedTable.parse("a,b\n1,2,3\n", separator: ","), "a row longer than the header")
        XCTAssertNil(DelimitedTable.parse("a,b,c\n1,2\n", separator: ","), "a row shorter than the header")
        XCTAssertNil(DelimitedTable.parse("a,b\n\"open,2\n", separator: ","), "a quote that never closes")
        XCTAssertNil(DelimitedTable.parse("a,b\n\"x\"y,2\n", separator: ","), "text after a closing quote")
        XCTAssertNil(DelimitedTable.parse("", separator: ","), "nothing at all")
        XCTAssertNil(DelimitedTable.parse("\n\n", separator: ","), "only blank lines")
    }

    func testNumbers() {
        for cell in ["42", "-3.5", "1,200", "$48,000", "€9.99", "12%", "(250)", " 7 ", "1e6", ".5", "+4"] {
            XCTAssertTrue(DelimitedTable.isNumber(cell), cell)
        }
        for cell in ["", "abc", "1.2.3", "2026-10-29", "N/A", "$", "12 apples", "inf", "nan"] {
            XCTAssertFalse(DelimitedTable.isNumber(cell), cell)
        }
    }

    func testRowLimitStopsAndSaysThereAreMore() throws {
        let csv = "n\n" + (1...10).map(String.init).joined(separator: "\n") + "\n"
        let cut = try XCTUnwrap(DelimitedTable.parse(csv, separator: ",", rowLimit: 4))
        XCTAssertEqual(cut.rows.count, 4)
        XCTAssertTrue(cut.rowLimitHit)

        let exact = try XCTUnwrap(DelimitedTable.parse(csv, separator: ",", rowLimit: 10))
        XCTAssertEqual(exact.rows.count, 10)
        XCTAssertFalse(exact.rowLimitHit, "a trailing line break is not another row")
    }

    /// Larry's ask: a table wide and long both ways parses, every row kept,
    /// and the widths come from a sample, clamped, one per column.
    func testWideAndLongTable() throws {
        let columns = 34
        let rowCount = 20_000
        var lines = [(0..<columns).map { "column_\($0)" }.joined(separator: ",")]
        lines.reserveCapacity(rowCount + 1)
        for row in 0..<rowCount {
            lines.append((0..<columns).map { column in
                switch column {
                case 0: "\(row)"
                case 1: "\"Name \(row), the \(row % 7)th\""
                case 2: String(repeating: "wide ", count: 200)  // far past the maximum
                case 3: "x"  // narrower than the minimum
                default: "\(row * column).\(column)"
                }
            }.joined(separator: ","))
        }
        let csv = lines.joined(separator: "\n") + "\n"

        let table = try XCTUnwrap(DelimitedTable.parse(csv, separator: ","))
        XCTAssertEqual(table.columnCount, columns)
        XCTAssertEqual(table.rows.count, rowCount, "every row, no 1,000-row page")
        XCTAssertFalse(table.rowLimitHit)
        XCTAssertEqual(table.rows[rowCount - 1][1], "Name \(rowCount - 1), the \((rowCount - 1) % 7)th")
        XCTAssertEqual(table.numeric[0], true)
        XCTAssertEqual(table.numeric[1], false)
        XCTAssertEqual(table.numeric[33], true)

        let widths = DelimitedTable.columnWidths(header: table.header, rows: table.rows)
        XCTAssertEqual(widths.count, columns)
        XCTAssertEqual(widths[2], DelimitedTable.maxColumnWidth, "a very wide column is clamped; its cells truncate")
        XCTAssertTrue(widths.allSatisfy { $0 >= DelimitedTable.minColumnWidth && $0 <= DelimitedTable.maxColumnWidth })
        XCTAssertGreaterThan(widths[1], widths[0], "the quoted names are wider than the row numbers")

        // Only the sample is measured: a long cell past it changes nothing.
        var rows = Array(table.rows.prefix(300))
        rows[250][0] = String(repeating: "9", count: 80)
        XCTAssertEqual(DelimitedTable.columnWidths(header: table.header, rows: rows)[0], widths[0])
        rows[10][0] = String(repeating: "9", count: 80)
        XCTAssertGreaterThan(DelimitedTable.columnWidths(header: table.header, rows: rows)[0], widths[0])
    }

    func testColumnWidthClampsShortColumnsToTheMinimum() {
        let widths = DelimitedTable.columnWidths(header: ["a"], rows: [["1"], ["2"]])
        XCTAssertEqual(widths, [DelimitedTable.minColumnWidth])
    }

    // MARK: - loading files

    func testLoadATableOrFallBackToText() throws {
        let good = try tempFile("q3.csv", "region,amount\n\"West, North\",\"$48,000\"\nEast,9800\n")
        guard case .table(let table, let widths, let note) = TableLoad.load(good, separator: ",") else {
            return XCTFail("q3.csv should be a table")
        }
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(table.numeric, [false, true])
        XCTAssertNil(note)

        let ragged = try tempFile("notes.csv", "not really, a table\njust some prose\n")
        guard case .text(let read) = TableLoad.load(ragged, separator: ",") else {
            return XCTFail("a ragged CSV should show as text")
        }
        XCTAssertEqual(read.text, "not really, a table\njust some prose\n")

        let many = try tempFile("many.csv", "n\n" + (1...50).map(String.init).joined(separator: "\n"))
        guard case .table(let cut, _, let cutNote) = TableLoad.load(many, separator: ",", rowLimit: 20) else {
            return XCTFail("should be a table")
        }
        XCTAssertEqual(cut.rows.count, 20)
        XCTAssertEqual(cutNote, "Showing the first 20 rows; the file has more. Open it externally for the rest.")
    }

    func testReadCapsLargeFilesAndKeepsWholeCharacters() throws {
        // "é" is two bytes in UTF-8: a cut after 3 bytes lands inside one.
        let url = try tempFile("big.txt", "aéé\nbb\n")
        let cut = try XCTUnwrap(TextFileRead.read(url, limit: 4))
        XCTAssertEqual(cut.text, "aé")
        XCTAssertTrue(cut.truncated)
        XCTAssertEqual(cut.totalBytes, 9)

        let lines = try XCTUnwrap(TextFileRead.read(url, limit: 7, wholeLines: true))
        XCTAssertEqual(lines.text, "aéé\n", "a table read drops the partial last line")

        let whole = try XCTUnwrap(TextFileRead.read(url, limit: TextFileRead.textLimit))
        XCTAssertEqual(whole.text, "aéé\nbb\n")
        XCTAssertFalse(whole.truncated)

        XCTAssertNil(TextFileRead.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"), limit: 10))
    }

    // MARK: - review fixes (v0.5)

    func testACutReadEndsAtAnUnclosedQuoteAndKeepsTheRecordsBeforeIt() throws {
        // A cell spanning lines, cut after its first line by the size limit.
        let csv = "name,note\nalpha,one\nbeta,\"first line\nsecond line\"\ngamma,three\n"
        XCTAssertNil(DelimitedTable.parse("name,note\nalpha,one\nbeta,\"first line\n", separator: ","), "a whole file with an open quote is still not a table")
        let partial = try XCTUnwrap(DelimitedTable.parse("name,note\nalpha,one\nbeta,\"first line\n", separator: ",", partial: true))
        XCTAssertEqual(partial.rows, [["alpha", "one"]])

        // Through the loader: 40 bytes lands inside beta's quoted cell.
        let url = try tempFile("notes.csv", csv)
        guard case .table(let table, _, let note) = TableLoad.load(url, separator: ",", byteLimit: 40) else {
            return XCTFail("a cut CSV should still be a table")
        }
        XCTAssertEqual(table.rows, [["alpha", "one"]])
        XCTAssertEqual(note?.hasPrefix("Showing 1 rows from the first 40 bytes of "), true, note ?? "")
    }

    func testACancelledParseGivesUp() async throws {
        let csv = "n\n" + (1...20_000).map(String.init).joined(separator: "\n")
        let task = Task.detached { () -> DelimitedTable? in
            while !Task.isCancelled { await Task.yield() }
            return DelimitedTable.parse(csv, separator: ",")
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNotNil(DelimitedTable.parse(csv, separator: ","), "uncancelled, the same text parses")
    }

    func testOffMainWorkIsCancelledWithItsCaller() async {
        let saw = Task {
            await offMain { () -> Bool in
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if Task.isCancelled { return true }
                    usleep(1_000)
                }
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        saw.cancel()
        let cancelled = await saw.value
        XCTAssertTrue(cancelled, "the detached work saw its caller's cancellation")
    }

    func testVeryWideTablesDrawTheFirstColumnsAndSaySo() throws {
        let count = 250
        let header = (1...count).map { "c\($0)" }.joined(separator: ",")
        let row = (1...count).map(String.init).joined(separator: ",")
        let url = try tempFile("wide.csv", header + "\n" + row + "\n")
        guard case .table(let table, let widths, let note) = TableLoad.load(url, separator: ",") else {
            return XCTFail("should be a table")
        }
        XCTAssertEqual(table.columnCount, count)
        XCTAssertEqual(widths.count, DelimitedTable.maxDrawnColumns)
        XCTAssertEqual(note, "Showing the first 200 of 250 columns. Open it externally for the rest.")
    }

    func testVeryLongLinesAreBrokenForDisplay() {
        let short = "one\r\ntwo\n"
        XCTAssertEqual(TextFileRead.hardBreak(short).text, short, "nothing long: the text is untouched")
        XCTAssertFalse(TextFileRead.hardBreak(short).broke)

        let long = String(repeating: "é", count: 25_000)
        let shown = TextFileRead.hardBreak("head\n" + long + "\ntail", limit: 10_000)
        XCTAssertTrue(shown.broke)
        let lines = shown.text.split(separator: "\n", omittingEmptySubsequences: false).map(\.count)
        XCTAssertEqual(lines, [4, 10_000, 10_000, 5_000, 4])

        let read = TextFileRead(text: "", totalBytes: 0, truncated: false)
        XCTAssertNil(TextBody.note(read: read, broke: false))
        XCTAssertEqual(TextBody.note(read: read, broke: true), "Lines longer than 10,000 characters are broken to fit.")
    }

    @MainActor
    func testARewrittenFileGetsANewIdentity() throws {
        let url = try tempFile("notes.txt", "first")
        let shown = ArtifactPresentation(artifact: DocumentView.artifact(for: url.path))
        let before = shown.contentIdentity
        XCTAssertEqual(shown.contentIdentity, before, "unchanged on disk: the same")
        try "second version".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        XCTAssertNotEqual(shown.contentIdentity, before, "a change on disk reloads the pane")
        XCTAssertTrue(before.hasPrefix(AppModel.localArtifactPrefix + url.path))
    }

    func testTheTableExtensionsAreTextExtensions() {
        XCTAssertEqual(DelimitedTable.separator(forExtension: "TSV"), "\t")
        XCTAssertNil(DelimitedTable.separator(forExtension: "tab"), "not a text extension, so it never reaches the table")
        for ext in ["csv", "tsv"] {
            XCTAssertTrue(Media.textExtensions.contains(ext), ext)
        }
    }

    /// 20,000 rows by 30 columns lay out in an ordinary window's worth of
    /// space quickly: the rows must draw lazily (a stack that built them all
    /// would take minutes) with the header pinned in the same scroll view.
    @MainActor
    func testABigTableLaysOutLazily() throws {
        let columns = 30, rowCount = 20_000
        let header = (1...columns).map { "Column \($0)" }
        let rows = (0..<rowCount).map { r in (0..<columns).map { "r\(r)c\($0)" } }
        let table = DelimitedTable(header: header, rows: rows, rowLimitHit: false, numeric: Array(repeating: false, count: columns))
        let widths = Array(repeating: CGFloat(120), count: columns)
        let started = Date()
        let host = NSHostingView(rootView: TableBody(table: table, widths: widths, note: nil))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "laid out lazily")
    }

    // MARK: - media and presentation

    func testTextAndCodeExtensionsAreText() {
        for name in ["config.toml", "app.py", "q3.csv", "q3.TSV", "build.log", "a.json", "s.yml", "x.swift", "q.sql"] {
            XCTAssertEqual(Media.of(path: "/tmp/\(name)"), .text, name)
        }
        for name in ["proposal.docx", "book.xlsx", "Makefile", "a.tar.gz"] {
            XCTAssertEqual(Media.of(path: "/tmp/\(name)"), .other, name)
        }
    }

    @MainActor
    func testPresentationPicksTheTableAndUpgradesAnOlderGatewaysOther() {
        XCTAssertEqual(file("/tmp/q3.csv", media: .text).tableSeparator, ",")
        XCTAssertEqual(file("/tmp/q3.tsv", media: .text).tableSeparator, "\t")
        XCTAssertNil(file("/tmp/config.toml", media: .text).tableSeparator)
        XCTAssertEqual(file("/tmp/q3.csv", media: .text).systemImage, "tablecells")

        // A pre-0.5 gateway calls app.py `other`; the app still shows it as text.
        XCTAssertEqual(file("/tmp/app.py", media: .other).media, .text)
        XCTAssertEqual(file("/tmp/x.docx", media: .other).media, .other)
        XCTAssertEqual(file("/tmp/r.md", media: .markdown).media, .markdown)
    }

    @MainActor
    func testMissingFileIsMissingForEveryKind() throws {
        let gone = "/tmp/portico-gone-\(UUID().uuidString)/test.csv"
        for media: Media in [.markdown, .image, .html, .pdf, .text, .other] {
            XCTAssertTrue(file(gone, media: media).isMissing, media.rawValue)
        }
        let here = try tempFile("q3.csv", "a\n1\n")
        XCTAssertFalse(file(here.path, media: .text).isMissing)
        let url = ArtifactPresentation(artifact: Artifact(
            id: "u", kind: .url, location: "http://localhost:3000/", media: .url, title: "", source: .text, open: true))
        XCTAssertFalse(url.isMissing, "a URL is never 'not on disk'")
    }

    @MainActor
    func testUnsupportedKindWords() {
        XCTAssertEqual(ArtifactPresentation.kindPhrase(forExtension: "zip"), "ZIP archives")
        XCTAssertEqual(ArtifactPresentation.kindPhrase(forExtension: "DOCX"), "Word documents")
        XCTAssertEqual(ArtifactPresentation.kindPhrase(forExtension: "zzqx"), "ZZQX files")
        XCTAssertEqual(ArtifactPresentation.kindPhrase(forExtension: ""), "this kind of file")
        let label = file("/tmp/x.docx", media: .other).openLabel
        XCTAssertTrue(label == "Open externally" || label.hasPrefix("Open in "), label)
    }
}
