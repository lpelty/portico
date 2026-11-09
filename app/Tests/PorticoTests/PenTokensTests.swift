import Foundation
import XCTest

@testable import Portico

/// v0.26 (PORT-25, rulings 15 and 16): `Theme`'s tokens and the colour
/// variables in `design/portico.pen` are one table: every token has a Pen
/// variable of its kebab-case name with the same light and dark values, and
/// every Pen colour variable is a token. A Pen variable with one value
/// (not a light/dark list) means both modes.
final class PenTokensTests: XCTestCase {
    static var penFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PorticoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("design/portico.pen")
    }

    /// "#RRGGBB" → "#RRGGBBFF", uppercase.
    static func normalised(_ hex: String) -> String {
        let up = hex.uppercased()
        return up.count == 7 ? up + "FF" : up
    }

    /// Pen's colour variables as (light, dark), normalised.
    static func penColours() throws -> [String: (light: String, dark: String)] {
        let data = try Data(contentsOf: penFile)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try XCTUnwrap(root["variables"] as? [String: Any])
        var out: [String: (light: String, dark: String)] = [:]
        for (name, raw) in variables {
            guard let variable = raw as? [String: Any], variable["type"] as? String == "color" else { continue }
            if let one = variable["value"] as? String {
                out[name] = (normalised(one), normalised(one))
            } else if let list = variable["value"] as? [[String: Any]] {
                var light = "", dark = ""
                for entry in list {
                    let mode = (entry["theme"] as? [String: Any])?["mode"] as? String
                    let value = normalised(entry["value"] as? String ?? "")
                    if mode == "dark" { dark = value } else { light = value }
                }
                out[name] = (light, dark.isEmpty ? light : dark)
            }
        }
        return out
    }

    func testThemeEqualsThePenVariables() throws {
        let pen = try Self.penColours()
        var missingInPen: [String] = [], missingInTheme: [String] = [], different: [String] = []
        for token in Theme.Token.allCases {
            let name = Theme.penName(token)
            let want = (Self.normalised(Theme.hex(token).light), Self.normalised(Theme.hex(token).dark))
            guard let got = pen[name] else { missingInPen.append(name); continue }
            if got.light != want.0 || got.dark != want.1 {
                different.append("\(name): Pen \(got.light)/\(got.dark), Theme \(want.0)/\(want.1)")
            }
        }
        let names = Set(Theme.Token.allCases.map(Theme.penName))
        for name in pen.keys where !names.contains(name) { missingInTheme.append(name) }
        XCTAssertEqual(missingInPen.sorted(), [])
        XCTAssertEqual(missingInTheme.sorted(), [])
        XCTAssertEqual(different.sorted(), [])
    }

    /// The reader itself, on the file as it is: it finds Pen's light/dark
    /// lists and single values, and the tokens Pen already has match.
    func testThePenReaderReadsTheFile() throws {
        let pen = try Self.penColours()
        XCTAssertEqual(pen["window"]?.light, "#FFFFFFFF")
        XCTAssertEqual(pen["window"]?.dark, "#161618FF")
        XCTAssertEqual(pen["on-accent"]?.dark, "#FFFFFFFF")
        XCTAssertNil(pen["font"])
        XCTAssertEqual(Self.normalised("#00000022"), "#00000022")
    }
}
