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
}
