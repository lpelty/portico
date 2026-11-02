import AppKit
import XCTest
@testable import Portico

/// v0.15 §3 (AN3): one text scale for the whole app — the setting and its
/// steps, the reading column, the AppKit text, the viewer's Markdown, and
/// the View menu's keys.
@MainActor
final class TextScaleTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "portico-textscale-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: the setting

    func testTheStepsAndTheDefault() {
        XCTAssertEqual(Settings.textScaleSteps, [0.85, 1.0, 1.15, 1.3, 1.5])
        XCTAssertEqual(Settings(defaults: defaults).textScale, 1.0)
    }

    func testBiggerSmallerAndActualSizeStepAndStopAtTheEnds() {
        let settings = Settings(defaults: defaults)
        settings.biggerText()
        XCTAssertEqual(settings.textScale, 1.15)
        settings.textScale = 1.5
        settings.biggerText()
        XCTAssertEqual(settings.textScale, 1.5, "the largest step is the last")
        settings.textScale = 0.85
        settings.smallerText()
        XCTAssertEqual(settings.textScale, 0.85, "the smallest step is the first")
        settings.actualSize()
        XCTAssertEqual(settings.textScale, 1.0)
    }

    func testAStoredValueBetweenStepsLoadsAsTheNearestStep() {
        defaults.set(1.2, forKey: Settings.Key.textScale)
        XCTAssertEqual(Settings(defaults: defaults).textScale, 1.15)
    }

    func testTheScaleIsRememberedAcrossLaunches() {
        let settings = Settings(defaults: defaults)
        settings.biggerText()
        settings.biggerText()
        XCTAssertEqual(Settings(defaults: defaults).textScale, 1.3)
    }

    func testTheStepperReadsAPercentage() {
        XCTAssertEqual(Settings.percentLabel(1.15), "115%")
        XCTAssertEqual(Settings.percentLabel(0.85), "85%")
        XCTAssertEqual(Settings.percentLabel(1.0), "100%")
    }

    func testTheAppearanceChoicesKeepTheirValuesAndReadAsTheDesign() {
        XCTAssertEqual(Settings.Appearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(Settings.Appearance.allCases.map(\.label), ["Match the system", "Light", "Dark"])
    }

    func testTheAppearanceTabSaysWhatTheDesignSays() {
        XCTAssertEqual(AppearanceSettingsPresentation.textSizeLabel, "Text size")
        XCTAssertEqual(AppearanceSettingsPresentation.textSizeNote,
                       "Conversation, sidebar and documents. Web pages in the viewer keep their own size.")
        XCTAssertEqual(AppearanceSettingsPresentation.shortcutNote, "⌘+ and ⌘− change it anywhere in Portico.")
    }

    // MARK: what scales

    func testTheReadingColumnScalesWithTheText() {
        XCTAssertEqual(ConversationColumn.maxWidth(scale: 1), 768)
        XCTAssertEqual(ConversationColumn.maxWidth(scale: 1.5), 1152)
        XCTAssertEqual(ConversationColumn.width(available: 2000, sideInset: 32, scale: 1.5), 1152)
        XCTAssertEqual(ConversationColumn.outerWidth(sideInset: 32, scale: 1.5), 1216)
    }

    func testTheHelperScalesAppKitFonts() {
        XCTAssertEqual(Theme.nsFont(12, scale: 1.3).pointSize, 15.6, accuracy: 0.001)
        XCTAssertEqual(Theme.nsFont(12, scale: 1, weight: .semibold).pointSize, 12)
    }

    func testMarkdownBodyFontAtAScale() throws {
        let text = MarkdownAttributed.prose(MarkdownParser.parse("Plain words."), scale: 1.3)
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 19.5, accuracy: 0.001)
        let code = MarkdownAttributed.code("let x = 1", scale: 1.5)
        let codeFont = try XCTUnwrap(code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(codeFont.pointSize, 21, accuracy: 0.001)
    }

    func testTableColumnsWidenWithTheText() {
        let header = ["Name", "Owner"]
        let rows = [["Acme quarterly review", "Priya"]]
        let normal = DelimitedTable.columnWidths(header: header, rows: rows)
        let bigger = DelimitedTable.columnWidths(header: header, rows: rows, scale: 1.5)
        XCTAssertGreaterThan(bigger[0], normal[0])
    }

    func testTheStatusStripMeasuresAtTheScale() {
        XCTAssertGreaterThan(StatusStripPresentation.textWidth("Services running", scale: 1.5),
                             StatusStripPresentation.textWidth("Services running"))
    }

    // MARK: the viewer

    func testTheViewersMarkdownPageCarriesTheScale() throws {
        let page = try MarkdownPage.html(source: "# Notes", title: "notes.md", scale: 1.15)
        XCTAssertTrue(page.contains("calc(15px * 1.15)"), "the Markdown page's body is scaled")
        let plain = try MarkdownPage.html(source: "# Notes", title: "notes.md")
        XCTAssertFalse(plain.contains("calc(15px"), "at 100% the page is as it was")
    }

    func testAnHTMLFileAndASiteAreNotScaled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portico-textscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = folder.appendingPathComponent("page.html")
        try "<p>Acme</p>".write(to: html, atomically: true, encoding: .utf8)
        let markdown = folder.appendingPathComponent("notes.md")
        try "# Notes".write(to: markdown, atomically: true, encoding: .utf8)

        XCTAssertNil(WebPane.renderedPage(for: .html(html), scale: 1.15), "an HTML file is served as written")
        XCTAssertNil(WebPane.renderedPage(for: .url(URL(string: "https://example.com")!), scale: 1.15))
        let page = try XCTUnwrap(WebPane.renderedPage(for: .markdown(markdown), scale: 1.15))
        XCTAssertTrue(page.contains("calc(15px * 1.15)"))
    }

    // MARK: the View menu

    func testActualSizeHasNoKeyAndWorkKeepsCommandZero() throws {
        let source = try String(contentsOf: Self.appSource, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        let actual = try XCTUnwrap(lines.firstIndex { $0.contains("Button(\"Actual Size\")") }, "the View menu has Actual Size")
        let next = lines[(actual + 1)...].firstIndex { $0.contains("Button(") } ?? lines.count
        XCTAssertFalse(lines[actual..<next].joined().contains("keyboardShortcut"), "Actual Size has no shortcut")

        let zeros = lines.indices.filter { lines[$0].contains("keyboardShortcut(\"0\"") }
        XCTAssertEqual(zeros.count, 1, "only one item binds ⌘0")
        let work = try XCTUnwrap(lines.firstIndex { $0.contains("Button(\"Work\")") })
        XCTAssertEqual(zeros.first, work + 1, "and it is Work")

        XCTAssertTrue(source.contains("Button(\"Bigger Text\")"))
        XCTAssertTrue(source.contains("Button(\"Smaller Text\")"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"+\", modifiers: .command)"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"-\", modifiers: .command)"))
    }

    func testCommandEqualsIsBiggerTextToo() {
        XCTAssertTrue(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: .command))
        XCTAssertTrue(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: [.command, .capsLock]))
        XCTAssertTrue(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: [.command, .numericPad, .function]))
        XCTAssertFalse(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: [.command, .shift, .capsLock]))
        XCTAssertFalse(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: [.command, .option]))
        XCTAssertFalse(TextScaleKeys.isBiggerAlternate(characters: "=", modifiers: []))
        XCTAssertFalse(TextScaleKeys.isBiggerAlternate(characters: "0", modifiers: .command))
    }

    private static var appSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Portico/PorticoApp.swift")
    }
}
