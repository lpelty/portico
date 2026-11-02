import Foundation
import XCTest

/// v0.15 §3.4: every text size goes through the scale. A raw
/// `.font(.system(size:` in a view is a piece of text that would not follow
/// the person's text size; text uses `.scaledFont`, a symbol `Theme.iconFont`.
final class TextScaleSweepTests: XCTestCase {
    func test_no_raw_system_font_sizes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Portico")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let pattern = try NSRegularExpression(pattern: #"\.font\(\.system\(size:"#)
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            if url.path.hasSuffix("Views/Theme.swift") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                offenders.append("\(url.lastPathComponent):\(n + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan must actually find the sources")
        XCTAssertEqual(offenders.count, 0, "\(offenders.count) raw sizes: \(offenders.prefix(20))")
    }
}
