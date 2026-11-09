import XCTest
@testable import Portico

final class SolidColourTests: XCTestCase {
    func testPaletteIsTheSpecs() {
        let spec: [Theme.Token: (String, String)] = [
            .window: ("#FFFFFF", "#161618"), .sidebar: ("#EFEFF2", "#1C1C1F"),
            .panel: ("#F5F5F7", "#1B1B1D"), .surface: ("#EEEEF1", "#242427"),
            .control: ("#FFFFFF", "#2D2D31"), .border: ("#CACAD0", "#45454B"),
            .borderSubtle: ("#DDDDE2", "#2C2C30"), .borderStrong: ("#B2B2BA", "#68686F"),
            .text: ("#1C1C1E", "#F5F5F7"),
            .text2: ("#5E5E64", "#B6B6BC"), .text3: ("#6C6C72", "#8A8A91"),
            .selected: ("#E0E0E5", "#34343A"),
            .agentAvatar: ("#2F7A6B", "#3E8E7E"),
            .dangerStrong: ("#B3261E", "#C4362E"),
            .accent: ("#3B6BE0", "#6B8FF2"), .accentSoft: ("#EBF0FC", "#26304A"),
            .onAccent: ("#FFFFFF", "#FFFFFF"),
            .wait: ("#B86E00", "#F0B24A"), .waitSoft: ("#FFF3DE", "#3B2E16"),
            .onWait: ("#FFFFFF", "#1C1C1E"),
            .working: ("#2DA44E", "#4CC86A"), .deny: ("#C93C37", "#F0706A"),
            .idle: ("#B5B5BB", "#6A6A70"), .stopped: ("#8E8E93", "#8E8E93"),
            .meterTrack: ("#E4E4E7", "#3A3A3E"), .meterFill: ("#A3A3A8", "#A3A3A9"),
            .hoverTint: ("#0000000D", "#FFFFFF12"), .pressTint: ("#0000001A", "#FFFFFF21"),
            .scrim: ("#00000040", "#00000040"), .shadowStrong: ("#0000004D", "#0000004D"),
            .shadowSoft: ("#0000002E", "#0000002E"), .knob: ("#FFFFFF", "#FFFFFF"),
            .pointerShadow: ("#000000", "#000000"),
            .tipFill: ("#2B2B2E", "#2B2B2E"), .tipText: ("#E6E6E8", "#E6E6E8"),
            .tipStroke: ("#FFFFFF1F", "#FFFFFF1F"), .tipShadow: ("#00000066", "#00000066"),
            .tipText2: ("#B6B6BC", "#B6B6BC"), .tipText3: ("#8A8A91", "#8A8A91"),
            .shadow: ("#00000022", "#00000066"),
            .windowClose: ("#FF5F57", "#FF5F57"), .windowMinimize: ("#FEBC2E", "#FEBC2E"),
            .windowZoom: ("#28C840", "#28C840"),
            .logo1: ("#4F7DF3", "#4F7DF3"), .logo2: ("#E07A3F", "#E07A3F"), .logo3: ("#2F9E8F", "#2F9E8F"),
            .logo4: ("#8A6BD1", "#8A6BD1"), .logo5: ("#C9A227", "#C9A227"), .logo6: ("#D1567A", "#D1567A"),
            .logo7: ("#3F6FD8", "#3F6FD8"), .logo8: ("#5D6874", "#5D6874"), .logo9: ("#3F8CD1", "#3F8CD1"),
            .logo10: ("#7A8A3F", "#7A8A3F"),
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

    /// v0.23 (spec §12.5): the comments toggle and the Edit toggle fill with
    /// the solid `accentSoft` when on, never a translucent accent.
    func testCommentsAndEditTogglesAreSolid() throws {
        for name in ["Views/Viewer/EditorPane.swift", "Views/Viewer/ViewerComments.swift"] {
            let url = ListFontSweepTests.sources.appendingPathComponent(name)
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            XCTAssertFalse(text.contains(".opacity("), "\(name) uses .opacity(")
        }
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

    /// v0.23 §13.2: the Delete confirmation is a darker red with white text at 4.5:1 or more.
    func testDeleteButtonContrast() {
        for hex in [Theme.hex(.dangerStrong).light, Theme.hex(.dangerStrong).dark] {
            XCTAssertGreaterThanOrEqual(Self.contrast("#FFFFFF", hex), 4.5, hex)
        }
    }

    /// v0.26 (PORT-25): no white, black or hex literal outside `Theme.swift`.
    func testNoLiteralColourOutsideTheme() throws {
        let pattern = try NSRegularExpression(
            pattern: ##"Color\.(white|black)\b|NSColor\.(white|black)\b|NSColor\(white:|[(:,]\s*\.(white|black)\b|"#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?""##)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: ListFontSweepTests.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            if url.path.hasSuffix("Views/Theme.swift") { continue }
            scanned += 1
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                offenders.append("\(url.lastPathComponent): \((text as NSString).substring(with: match.range))")
            }
        }
        XCTAssertGreaterThan(scanned, 20)
        XCTAssertEqual(offenders, [])
    }

    func testPenNamesAreKebabCase() {
        XCTAssertEqual(Theme.penName(.borderSubtle), "border-subtle")
        XCTAssertEqual(Theme.penName(.text2), "text-2")
        XCTAssertEqual(Theme.penName(.logo10), "logo-10")
        XCTAssertEqual(Theme.penName(.onAccent), "on-accent")
        XCTAssertEqual(Theme.penName(.window), "window")
    }

    func testLogoOrdersAreTodays() {
        XCTAssertEqual(Theme.mcpLogoFills.map { Theme.hex($0).light },
            ["#4F7DF3", "#E07A3F", "#2F9E8F", "#8A6BD1", "#C9A227", "#D1567A", "#3F6FD8", "#5D6874"])
        XCTAssertEqual(Theme.pluginLogoFills.map { Theme.hex($0).light },
            ["#D1567A", "#3F8CD1", "#7A8A3F", "#4F7DF3", "#E07A3F", "#2F9E8F", "#8A6BD1", "#C9A227"])
    }

    func testCommentsThemeReadsTheTokens() {
        let css = CommentsTheme.css()
        XCTAssertTrue(css.contains("--pc-wait: #B86E00"))
        XCTAssertTrue(css.contains("--pc-on-wait: #1C1C1E"))
    }

    /// v0.26 review: the marker tip's second and third lines have tokens of their own
    /// (the tip is the same dark bubble in both appearances).
    func testTheTipsSecondaryLinesAreTokens() {
        XCTAssertEqual(Theme.penName(.tipText2), "tip-text-2")
        XCTAssertEqual(Theme.hex(.tipText2).light, Theme.hex(.text2).dark)
        XCTAssertEqual(Theme.hex(.tipText3).light, Theme.hex(.text3).dark)
        XCTAssertEqual(MarkerTip.replyColour, Theme.tipText2)
        XCTAssertEqual(MarkerTip.footerColour, Theme.tipText3)
    }
}
