import AppKit
import SwiftUI
import XCTest
@testable import Portico

/// v0.19 §3 and §5: every Settings tab drawn the MCP servers way, every
/// control with a hover state, and Gateway's connection behind Advanced.
final class SettingsKitTests: XCTestCase {
    /// The tab sources: SettingsView, VoiceSettingsTab and Views/Settings,
    /// less the kit itself (the one place the controls are drawn).
    private func tabSources() throws -> [URL] {
        let views = ListFontSweepTests.sources.appendingPathComponent("Views")
        let settings = views.appendingPathComponent("Settings")
        let listed = try FileManager.default.contentsOfDirectory(at: settings, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsKit.swift" }
        return [views.appendingPathComponent("SettingsView.swift"), views.appendingPathComponent("VoiceSettingsTab.swift")] + listed
    }

    func testNoSettingsTabUsesForm() throws {
        let banned = [
            "Form {", ".formStyle(", ".toggleStyle(.checkbox)", ".toggleStyle(.switch)",
            ".pickerStyle(.radioGroup)", ".pickerStyle(.segmented)",
            // A plain button has no hover: `.hover`, `.hoverText` or `SettingsButtonStyle` instead.
            ".buttonStyle(.plain)", ".buttonStyle(.borderless", ".buttonStyle(.bordered", ".buttonStyle(.link",
            ".toggleStyle(.button)",
        ]
        // A `Toggle` in a tab is a default one, in any form (`Toggle(`, `Toggle {`,
        // `Toggle(isOn:)`): the kit's switch and checkbox instead.
        let toggle = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])Toggle\s*[({]"#)
        let files = try tabSources()
        XCTAssertGreaterThanOrEqual(files.count, 4)
        var offenders: [String] = []
        for url in files {
            let text = ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
            for word in banned where text.contains(word) { offenders.append("\(url.lastPathComponent): \(word)") }
            if toggle.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append("\(url.lastPathComponent): Toggle(")
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testTheToggleSweepCatchesEveryForm() throws {
        let toggle = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])Toggle\s*[({]"#)
        for text in ["Toggle(\"a\", isOn: $b)", "Toggle(isOn: $b) { Text(\"a\") }", "Toggle { Text(\"a\") }"] {
            XCTAssertNotNil(toggle.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), text)
        }
        let kit = "SettingsSwitch(\"a\", isOn: $b)"
        XCTAssertNil(toggle.firstMatch(in: kit, range: NSRange(kit.startIndex..., in: kit)))
    }

    func testTheSweepWouldCatchAForm() {
        let text = ListFontSweepTests.withoutComments("Form {\n Toggle(\"a\", isOn: $b)\n}.formStyle(.grouped) // Form {")
        XCTAssertTrue(text.contains("Form {"))
        XCTAssertTrue(text.contains(".formStyle("))
    }

    func testAdvancedOpensForACustomConnection() {
        XCTAssertTrue(GatewaySettingsPresentation.advancedOpen(stored: false, address: "ws://x", tokenFile: ""))
        XCTAssertTrue(GatewaySettingsPresentation.advancedOpen(stored: false, address: "", tokenFile: "/t"))
        XCTAssertFalse(GatewaySettingsPresentation.advancedOpen(stored: false, address: "", tokenFile: ""))
        XCTAssertTrue(GatewaySettingsPresentation.advancedOpen(stored: true, address: "", tokenFile: ""))
        XCTAssertEqual(GatewaySettingsPresentation.customConnectionNote, "Custom connection in use")
        XCTAssertEqual(GatewaySettingsPresentation.advancedTitle, "Advanced")
    }

    @MainActor
    func testAdvancedIsClosedByDefaultAndRemembered() {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Settings(defaults: defaults).gatewayAdvancedOpen)
        Settings(defaults: defaults).gatewayAdvancedOpen = true
        XCTAssertTrue(Settings(defaults: defaults).gatewayAdvancedOpen)
    }

    /// A close while a custom connection is set is ignored (the stored
    /// state is kept); without one, a click stores what it asks for.
    func testAdvancedIgnoresACloseWhileCustom() {
        XCTAssertNil(GatewaySettingsPresentation.storedAfterToggle(open: false, address: "ws://x", tokenFile: ""))
        XCTAssertNil(GatewaySettingsPresentation.storedAfterToggle(open: false, address: "", tokenFile: "/t"))
        XCTAssertEqual(GatewaySettingsPresentation.storedAfterToggle(open: true, address: "ws://x", tokenFile: ""), true)
        XCTAssertEqual(GatewaySettingsPresentation.storedAfterToggle(open: false, address: "", tokenFile: ""), false)
        XCTAssertEqual(GatewaySettingsPresentation.storedAfterToggle(open: true, address: "", tokenFile: ""), true)
        XCTAssertEqual(GatewaySettingsPresentation.lockedOpenTip, "Clear the custom connection to close")
    }

    /// Every switch and checkbox has a name, the toggle trait and On/Off;
    /// a radio button or segment its own words, selected when chosen.
    func testControlsSayWhatTheyAre() {
        let on = SettingsControlAccessibility.toggle("Voice input", isOn: true)
        XCTAssertEqual(on.label, "Voice input")
        XCTAssertEqual(on.traits, .isToggle)
        XCTAssertEqual(on.value, "On")
        XCTAssertEqual(SettingsControlAccessibility.toggle("Voice input", isOn: false).value, "Off")
        let chosen = SettingsControlAccessibility.option("Fast", chosen: true)
        XCTAssertEqual(chosen.label, "Fast")
        XCTAssertEqual(chosen.traits, .isSelected)
        XCTAssertNil(chosen.value)
        XCTAssertEqual(SettingsControlAccessibility.option("Slow", chosen: false).traits, [])
    }

    func testHoverTintOnControls() {
        XCTAssertEqual(SettingsControlState.background(hovering: true, pressed: false), Theme.hoverTint)
        XCTAssertEqual(SettingsControlState.background(hovering: true, pressed: true), Theme.pressTint)
        XCTAssertEqual(SettingsControlState.background(hovering: false, pressed: true), Theme.pressTint)
        XCTAssertEqual(SettingsControlState.background(hovering: false, pressed: false), Color.clear)
        XCTAssertEqual(SettingsControlState.background(hovering: true, pressed: true, enabled: false), Color.clear)
    }

    /// The kit's controls draw in a window: a checkbox, a switch, a radio
    /// group and a section with a disclosure all lay out at a real size.
    @MainActor
    func testKitControlsHost() {
        let view = VStack {
            SettingsSection("Title", footnote: "Note") {
                SettingsRow("Row", help: "Help") { SettingsSwitch("Row", isOn: .constant(true)) }
                SettingsCheckbox("Box", help: "Help", isOn: .constant(false))
                SettingsRow("Radio") {
                    SettingsRadioGroup(selection: .constant(1), options: [(1, "One"), (2, "Two")], label: "Radio")
                }
                SettingsRow("Segments") {
                    SettingsSegmented(selection: .constant(1), options: [(1, "One"), (2, "Two")], label: "Segments")
                }
            }
            SettingsDisclosure("Advanced", isOpen: .constant(true), lockedOpen: "Locked") { Text("Inside").scaledFont(12) }
        }
        .environmentObject(Settings(defaults: UserDefaults(suiteName: "portico.tests.kit.\(UUID().uuidString)")!))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
        XCTAssertGreaterThan(host.fittingSize.width, 100)
    }
}
