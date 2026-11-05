import Foundation
import XCTest
@testable import Portico

/// v0.19 §9, §10: bare URLs are links; a known site's link is a chip.
final class LinkSitesTests: XCTestCase {
    func testASlackLinkIsAChip() throws {
        let chip = try XCTUnwrap(LinkSites.chip(for: URL(string: "https://acme.slack.com/archives/C0123456")!))
        XCTAssertEqual(chip.site, "Slack")
        XCTAssertEqual(chip.path, "/archives/C0123456")
    }

    func testADocsLinkCutsItsPath() throws {
        let chip = try XCTUnwrap(LinkSites.chip(for: URL(string: "https://docs.google.com/document/d/1aBcDeFgHiJkLmNoPqRsT/edit")!))
        XCTAssertEqual(chip.site, "Google Docs")
        XCTAssertEqual(chip.path.count, 24)
        XCTAssertTrue(chip.path.hasSuffix("…"))
    }

    func testSheetsAndSlidesAreNamedByPath() throws {
        let sheet = try XCTUnwrap(LinkSites.chip(for: URL(string: "https://docs.google.com/spreadsheets/d/1abc/edit")!))
        XCTAssertEqual(sheet.site, "Google Sheets")
        let slides = try XCTUnwrap(LinkSites.chip(for: URL(string: "https://docs.google.com/presentation/d/1abc/edit")!))
        XCTAssertEqual(slides.site, "Google Slides")
        let doc = try XCTUnwrap(LinkSites.chip(for: URL(string: "https://docs.google.com/document/d/1abc/edit")!))
        XCTAssertEqual(doc.site, "Google Docs")
    }

    func testAnUnknownHostIsNoChip() {
        XCTAssertNil(LinkSites.chip(for: URL(string: "https://acme.example/x")!))
        XCTAssertNil(LinkSites.chip(for: URL(string: "https://notslack.com/x")!))
    }

    func testExtraAddsAndOverridesBuiltIn() throws {
        let extra = ["acme.example": "Acme", "github.com": "Code"]
        XCTAssertEqual(LinkSites.chip(for: URL(string: "https://wiki.acme.example/p")!, extra: extra)?.site, "Acme")
        XCTAssertEqual(LinkSites.chip(for: URL(string: "https://github.com/a/b")!, extra: extra)?.site, "Code")
    }

    func testLinkifyFindsABareURLNotAMarkdownLink() {
        let found = Linkify.ranges(in: "see https://acme.example/x and [y](https://b.example)")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.1.absoluteString, "https://acme.example/x")
    }

    func testLinkifySkipsInlineCodeAndOtherSchemes() {
        XCTAssertTrue(Linkify.ranges(in: "run `curl https://acme.example/x` now").isEmpty)
        XCTAssertTrue(Linkify.ranges(in: "mail someone@acme.example or ftp://acme.example/f").isEmpty)
    }

    func testABubbleTakesKnownLinksOutOfItsText() {
        let split = BubbleLinks.split("look at https://acme.slack.com/archives/C01 and https://acme.example/x please")
        XCTAssertEqual(split.chips.map(\.absoluteString), ["https://acme.slack.com/archives/C01"])
        XCTAssertTrue(split.text.contains("https://acme.example/x"))
        XCTAssertFalse(split.text.contains("slack.com"))
    }

    func testABubbleLinksItsBareURLs() {
        let text = BubbleLinks.attributed("go to https://acme.example/x now")
        let linked = text.runs.compactMap(\.link)
        XCTAssertEqual(linked.map(\.absoluteString), ["https://acme.example/x"])
    }

    func testOnlyHttpHttpsAndMailtoMayBeLinked() {
        XCTAssertTrue(Linkify.allowed(URL(string: "https://acme.example/x")!))
        XCTAssertTrue(Linkify.allowed(URL(string: "mailto:a@acme.example")!))
        XCTAssertFalse(Linkify.allowed(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(Linkify.allowed(URL(string: "file:///etc/passwd")!))
    }

    @MainActor
    func testAReplyNeverLinksJavascriptOrFile() {
        let out = MarkdownAttributed.inline("[x](javascript:alert(1)) [y](file:///etc/passwd) [ok](https://acme.example)", color: .labelColor)
        var links: [String] = []
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
        }
        XCTAssertEqual(links, ["https://acme.example"])
        XCTAssertTrue(out.string.contains("x") && out.string.contains("y"))
    }

    func testTrailingPunctuationIsNotPartOfTheLink() {
        for text in ["https://x.example/a.", "(https://x.example/a)", "https://x.example/a,"] {
            let found = Linkify.detect(in: text)
            XCTAssertEqual(found.map(\.1.absoluteString), ["https://x.example/a"], text)
        }
    }

    func testPullingAChipOutLeavesNoDoubleSpace() {
        let split = BubbleLinks.split("see https://acme.slack.com/archives/C01 now")
        XCTAssertEqual(split.text, "see now")
    }

    func testBubbleLinksAreColouredAndUnderlined() {
        let text = BubbleLinks.attributed("go https://acme.example/x")
        let run = text.runs.first { $0.link != nil }
        XCTAssertNotNil(run?.foregroundColor)
        XCTAssertEqual(run?.underlineStyle, .single)
    }
}
