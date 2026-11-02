import Foundation
import XCTest

/// v0.15 §3.4: every text size goes through the scale. A raw system font in
/// a view is a piece of text that would not follow the person's text size;
/// text uses `.scaledFont`, a symbol `Theme.iconFont`. Semantic styles
/// (`.caption`, `.headline` ...) are just as raw: they are fixed sizes too.
final class TextScaleSweepTests: XCTestCase {
    func test_no_raw_system_font_sizes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Portico")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let styles = "caption2?|headline|body|footnote|title[23]?|callout|subheadline|largeTitle"
        let patterns = try [
            #"\.font\(\s*\.system\("#,
            #"\.font\(\s*\.(\#(styles))\b"#,
            #"Font\.system\("#,
        ].map { try NSRegularExpression(pattern: $0) }
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            if url.path.hasSuffix("Views/Theme.swift") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let whole = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: whole) {
                    let line = text.prefix(match.range.location).filter { $0 == "\n" }.count + 1
                    offenders.append("\(url.lastPathComponent):\(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan must actually find the sources")
        XCTAssertEqual(offenders.count, 0, "\(offenders.count) raw fonts: \(offenders.prefix(30))")
    }
}
