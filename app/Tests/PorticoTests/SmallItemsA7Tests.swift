import Foundation
import XCTest

@testable import Portico

/// v0.12 Task A7: conversation text at 15 pt (code 14), the Gateway row's
/// hover controls, and CHANGED THIS SESSION surviving the Files filter.
@MainActor
final class SmallItemsA7Tests: XCTestCase {

    func test_body_font_15_code_14() throws {
        XCTAssertEqual(MarkdownText.bodySize, 15)
        let prose = MarkdownAttributed.prose(MarkdownParser.parse("Plain words."))
        let plain = try XCTUnwrap(prose.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(plain.pointSize, 15)
        let code = MarkdownAttributed.code("let x = 1")
        let mono = try XCTUnwrap(code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(mono.pointSize, 14)
    }

    func test_changed_rows_visible_while_filtering() {
        let changed = [
            ChangedFile(path: "/w/notes/plan.md", at: nil),
            ChangedFile(path: "/w/src/main.swift", at: nil),
        ]
        XCTAssertEqual(ChangedFiles.matching(changed, filter: "PLAN").map(\.path), ["/w/notes/plan.md"])
        XCTAssertEqual(ChangedFiles.matching(changed, filter: "  ").count, 2, "no filter: all")
        XCTAssertTrue(ChangedFiles.matching(changed, filter: "zzz").isEmpty)
    }

    func test_gateway_row_has_stop_restart() {
        let up = ServicesPresentation.gatewayRow(.running(port: 54675), connection: .connected)
        XCTAssertEqual(ServicesPresentation.hoverControls(up), [.stop, .restart])
        let other = ServiceRow(id: "memory", name: "Memory", state: .up, detail: "up")
        XCTAssertTrue(ServicesPresentation.hoverControls(other).isEmpty)
    }
}
