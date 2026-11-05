import XCTest
@testable import Portico

final class SolidColourTests: XCTestCase {
    func testPaletteIsTheSpecs() {
        let spec: [Theme.Token: (String, String)] = [
            .window: ("#FFFFFF", "#161618"), .sidebar: ("#EFEFF2", "#1C1C1F"),
            .panel: ("#F5F5F7", "#1B1B1D"), .surface: ("#EEEEF1", "#242427"),
            .control: ("#FFFFFF", "#2D2D31"), .border: ("#CACAD0", "#45454B"),
            .borderStrong: ("#BDBDC4", "#5C5C63"), .text: ("#1C1C1E", "#F5F5F7"),
            .text2: ("#5E5E64", "#B6B6BC"), .text3: ("#6C6C72", "#8A8A91"),
            .selected: ("#E0E0E5", "#34343A"),
        ]
        XCTAssertEqual(spec.count, Theme.Token.allCases.count)
        for (token, want) in spec {
            XCTAssertEqual(Theme.hex(token).light, want.0, "\(token) light")
            XCTAssertEqual(Theme.hex(token).dark, want.1, "\(token) dark")
        }
    }

    func testContrastMeetsTheTargets() {
        for dark in [false, true] {
            func hex(_ t: Theme.Token) -> String { dark ? Theme.hex(t).dark : Theme.hex(t).light }
            for fg in [Theme.Token.text2, .text3] {
                for bg in [Theme.Token.window, .sidebar, .panel] {
                    let ratio = Self.contrast(hex(fg), hex(bg))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fg) on \(bg) dark=\(dark): \(ratio)")
                }
            }
            let floor = dark ? 1.6 : 1.4
            for bg in [Theme.Token.surface, .panel] {
                let ratio = Self.contrast(hex(.border), hex(bg))
                XCTAssertGreaterThanOrEqual(ratio, floor, "border on \(bg) dark=\(dark): \(ratio)")
            }
            if !dark {
                for bg in [Theme.Token.surface, .panel] {
                    let ratio = Self.contrast(hex(.borderStrong), hex(bg))
                    XCTAssertGreaterThanOrEqual(ratio, 1.6, "borderStrong on \(bg): \(ratio)")
                }
            }
        }
    }

    func testNoTranslucentSurfaces() throws {
        let banned = [".ultraThinMaterial", ".thinMaterial", ".regularMaterial", ".thickMaterial",
                      "NSVisualEffectView", "SidebarListStyle", ".background(.bar)", ".background(.regular",
                      "Theme.borderStrong.opacity("]
        let patterns = try [#"\.\w*Material\b|Material\."#, #"\.listStyle\(\s*\.sidebar"#,
                            #"Theme\.(window|sidebar|panel|surface|control)\.opacity\("#]
            .map { try NSRegularExpression(pattern: $0) }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            for word in banned where text.contains(word) { offenders.append("\(url.lastPathComponent): \(word)") }
            for pattern in patterns where pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append("\(url.lastPathComponent): \(pattern.pattern)")
            }
        }
        XCTAssertGreaterThan(scanned, 20)
        XCTAssertEqual(offenders, [])
    }

    func testPopoverPresentationIsSolidPanel() {
        XCTAssertEqual(PopoverPresentation.background, Theme.panel)
    }

    static func contrast(_ a: String, _ b: String) -> Double {
        func lum(_ hex: String) -> Double {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            let c = [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF].map { channel -> Double in
                let x = Double(channel) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }
        let (l1, l2) = (lum(a), lum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
