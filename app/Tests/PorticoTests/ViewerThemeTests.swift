import XCTest
@testable import Portico

/// v0.26 (PORT-25, ruling 13): the viewer's palette is `Theme`'s tokens,
/// injected at render; the stylesheets keep no colour of their own.
final class ViewerThemeTests: XCTestCase {
    func testViewerVariablesComeFromTheTokens() {
        let css = ViewerTheme.css()
        XCTAssertTrue(css.contains("--bg: #FFFFFF"))
        XCTAssertTrue(css.contains("--bg: #161618"))  // dark: window, no longer #1e1e1e
        XCTAssertTrue(css.contains("--link: #3B6BE0"))
        XCTAssertTrue(css.contains("--fm-done: #4CC86A"))
        for name in ["--fg", "--fg-muted", "--bg", "--rule", "--code-bg", "--link", "--quote", "--fm-key",
                     "--fm-value", "--fm-tag", "--fm-wait", "--fm-done", "--fm-stopped", "--fm-neutral"] {
            XCTAssertEqual(css.components(separatedBy: "\(name): ").count - 1, 2, name)
        }
    }

    func testTheBrandAccentIsTheLink() {
        XCTAssertTrue(ViewerTheme.css(accent: "#AA3300").contains("--link: #AA3300"))
    }

    func testTheCommentsThemeHasOnAccentAndDeny() {
        let css = CommentsTheme.css()
        XCTAssertTrue(css.contains("--pc-on-accent: #FFFFFF"))
        XCTAssertTrue(css.contains("--pc-deny: #C93C37"))
    }

    func testNoHexLeftInTheViewerStylesheets() throws {
        let hex = try NSRegularExpression(pattern: #"#[0-9A-Fa-f]{3,8}\b"#)
        for name in ["viewer", "viewer-comments"] {
            let url = try XCTUnwrap(AppResources.url(forResource: name, withExtension: "css"))
            let text = try String(contentsOf: url, encoding: .utf8)
            let found = hex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }
            XCTAssertEqual(found, [], name)
        }
    }

    func testThePageCarriesThePalette() throws {
        let html = try MarkdownPage.html(source: "# Hi", title: "t")
        XCTAssertTrue(html.contains("--bg: #161618"))
        XCTAssertTrue(try EditorPage.html().contains("--bg: #161618"))
    }
}
