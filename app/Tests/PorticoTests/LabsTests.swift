import XCTest
@testable import Portico

/// v0.25 §2 (PORT-5): Settings › Labs, its rows, and Read aloud's move there from Voice.
@MainActor
final class LabsTests: XCTestCase {
    private func item(
        key: String = "voice.read_aloud", title: String = "Read aloud", tag: LabItem.Tag = .preview,
        source: String = "config.toml", home: String? = nil
    ) -> LabItem {
        LabItem(key: key, title: title, detail: "d", tag: tag, source: source, home: home)
    }

    private func hello(labs: [LabItem]?) -> HelloServer {
        var hello = HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.25.0", epoch: "e",
            brand: Brand(name: "Front", agentName: "Agent"), actions: [], roots: [], commands: [], capabilities: [])
        hello.labs = labs
        return hello
    }

    private func settings(flag: Bool) -> Settings {
        let name = "LabsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if flag { defaults.set(true, forKey: "voice.readAloudAvailable") }
        return Settings(defaults: defaults)
    }

    func testLabsTabIsLastAndOnlyWithItems() {
        XCTAssertEqual(SettingsTab.visible(labs: false).last, .appearance)
        XCTAssertFalse(SettingsTab.visible(labs: false).contains(.labs))
        XCTAssertEqual(SettingsTab.visible(labs: true).last, .labs)
        XCTAssertEqual(SettingsTab.labs.title, "Labs")
        XCTAssertEqual(SettingsTab.labs.systemImage, "flask")
    }

    func testLabNotes() {
        XCTAssertEqual(
            LabPresentation.note(item(source: "config.local.toml", home: "voice")),
            "Turned on in config.local.toml · Moves to Voice when released")
        XCTAssertEqual(
            LabPresentation.note(item(tag: .local, source: "plugin:digest")),
            "Added by this Mac's plug-in “digest” · Not part of the app")
        XCTAssertEqual(LabPresentation.note(.readAloudFlag), "Turned on for this Mac · Moves to Voice when released")
        XCTAssertEqual(LabPresentation.note(item(source: "config.toml", home: "nowhere")), "Turned on in config.toml",
                       "an unknown home appends nothing")
        XCTAssertEqual(LabPresentation.note(item(source: "config.toml")), "Turned on in config.toml")
    }

    func testAppFlagAddsReadAloudOnlyWhenTheGatewaySentNone() {
        let model = AppModel(settings: settings(flag: true))
        model.apply(.hello(hello(labs: nil)))
        XCTAssertEqual(model.labItems.map(\.source), ["this Mac"])
        XCTAssertEqual(model.labItems.first?.key, "voice.read_aloud")
        model.apply(.hello(hello(labs: [item(source: "config.local.toml", home: "voice")])))
        XCTAssertEqual(model.labItems.map(\.source), ["config.local.toml"], "the gateway's item wins (ruling 5)")
    }

    func testNoItemsWithoutTheFlagOrTheGateway() {
        let model = AppModel(settings: settings(flag: false))
        model.apply(.hello(hello(labs: nil)))
        XCTAssertEqual(model.labItems, [])
        model.apply(.hello(hello(labs: [item(key: "digest", tag: .local, source: "plugin:digest")])))
        XCTAssertEqual(model.labItems.map(\.key), ["digest"])
    }

    func testAnOlderGatewaysReadAloudStillShowsInLabs() {
        // A v0.24 gateway sends `voice.read_aloud` but no `labs`: the switch would otherwise vanish.
        let model = AppModel(settings: settings(flag: false))
        var older = hello(labs: nil)
        older.voice = HelloVoice(readAloud: true)
        model.apply(.hello(older))
        XCTAssertEqual(model.labItems.map(\.key), ["voice.read_aloud"])
        XCTAssertEqual(model.labItems.first?.source, "config.toml")
    }

    func testLabsTabFallsBackWhenItsItemsGo() {
        let model = AppModel(settings: settings(flag: false))
        model.apply(.hello(hello(labs: [item()])))
        model.settingsTab = .labs
        model.apply(.hello(hello(labs: nil)))
        XCTAssertEqual(model.settingsTab, .general)
    }

    func testLabsTabStaysWhileItHasItems() {
        let model = AppModel(settings: settings(flag: false))
        model.apply(.hello(hello(labs: [item()])))
        model.settingsTab = .labs
        model.apply(.hello(hello(labs: [item()])))
        XCTAssertEqual(model.settingsTab, .labs)
    }

    func testVoiceTabHasNoListenSection() throws {
        let source = try String(contentsOf: Self.sourceFile("Views/VoiceSettingsTab.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("\"Listen\""), "the Listen section moved to Labs")
        XCTAssertFalse(source.contains("Read aloud on replies"))
        let labs = try String(contentsOf: Self.sourceFile("Views/Settings/LabsSettingsTab.swift"), encoding: .utf8)
        XCTAssertTrue(labs.contains("ReadAloudControls"))
    }

    func testReadAloudSwitchSubtitle() {
        XCTAssertEqual(ReadAloudControls.switchHelp, "A Play button on each reply; replies are read as they arrive while it's on.")
    }

    func testLabsHeaderText() {
        XCTAssertEqual(
            LabsSettingsTab.header,
            "Features being tried out on this Mac. They may change or go away. Everything in the other tabs is what everyone gets.")
    }

    func testLabItemDecodesTheGatewaysShape() throws {
        let json = #"{"key":"digest.daily","title":"Daily","detail":"A summary","tag":"local","source":"plugin:digest"}"#
        let decoded = try JSONDecoder().decode(LabItem.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, LabItem(key: "digest.daily", title: "Daily", detail: "A summary", tag: .local, source: "plugin:digest", home: nil))
    }

    private static func sourceFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Portico/\(relative)")
    }

    // MARK: - v0.26 (PORT-23, ruling 5): ElevenLabs voices fold into Read aloud's block

    func testElevenLabsItemIsFoldedIntoReadAloudsNote() {
        let model = AppModel(settings: settings(flag: false))
        let readAloud = item(source: "config.local.toml", home: "voice")
        let eleven = item(key: "voice.elevenlabs", title: "ElevenLabs voices", source: "config.local.toml", home: "voice")
        model.apply(.hello(hello(labs: [readAloud, eleven])))
        XCTAssertEqual(model.labItems.map(\.key), ["voice.read_aloud"])
        XCTAssertEqual(model.elevenLabsItem, eleven)
        XCTAssertEqual(
            LabPresentation.note(readAloud, elevenLabs: eleven),
            "Turned on in config.local.toml · ElevenLabs voices turned on in config.local.toml · Moves to Voice when released")
        XCTAssertEqual(LabPresentation.note(readAloud), "Turned on in config.local.toml · Moves to Voice when released")
    }

    func testHelloSetsElevenLabsAvailable() {
        let model = AppModel(settings: settings(flag: false))
        XCTAssertFalse(model.settings.elevenLabsAvailable)
        model.apply(.hello(hello(labs: [item(source: "config.toml", home: "voice"),
                                        item(key: LabItem.elevenLabsKey, source: "config.toml")])))
        XCTAssertTrue(model.settings.elevenLabsAvailable)
        model.apply(.hello(hello(labs: [item(source: "config.toml", home: "voice")])))
        XCTAssertFalse(model.settings.elevenLabsAvailable)
    }

    func testAnElevenLabsItemAloneShowsNoLabsTab() {
        let model = AppModel(settings: settings(flag: false))
        model.apply(.hello(hello(labs: [item(key: LabItem.elevenLabsKey, source: "config.toml")])))
        XCTAssertEqual(model.labItems, [])
        XCTAssertFalse(SettingsTab.visible(labs: !model.labItems.isEmpty).contains(.labs))
        XCTAssertFalse(model.settings.elevenLabsAvailable, "ElevenLabs needs Read aloud")
    }
}
