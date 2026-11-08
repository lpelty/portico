import AppKit
import SwiftUI
import XCTest
@testable import Portico

/// v0.26 (PORT-23, ZG1): Read aloud's Voice source, API key, Voice and Model.
/// The key lives in a store (in memory here), never in user defaults.
@MainActor
final class ElevenLabsSettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "ElevenLabsSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testElevenLabsSettingsPersistAndDefault() {
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.voiceSource, .thisMac)
        XCTAssertNil(settings.elevenLabsVoiceID)
        XCTAssertNil(settings.elevenLabsVoiceName)
        XCTAssertEqual(settings.elevenLabsModel, "eleven_v4_turbo")
        XCTAssertFalse(settings.speaksWithElevenLabs)
        settings.voiceSource = .elevenLabs
        settings.elevenLabsVoiceID = "21m00Tcm4TlvDq8ikWAM"
        settings.elevenLabsVoiceName = "Rachel"
        settings.elevenLabsModel = "eleven_flash_v2_5"
        let again = Settings(defaults: defaults)
        XCTAssertEqual(again.voiceSource, .elevenLabs)
        XCTAssertEqual(again.elevenLabsVoiceID, "21m00Tcm4TlvDq8ikWAM")
        XCTAssertEqual(again.elevenLabsVoiceName, "Rachel")
        XCTAssertEqual(again.elevenLabsModel, "eleven_flash_v2_5")
        XCTAssertFalse(again.speaksWithElevenLabs, "only when the gateway turned it on")
        again.elevenLabsAvailable = true
        XCTAssertTrue(again.speaksWithElevenLabs)
        XCTAssertEqual(VoiceSource.allCases.map(\.label), ["This Mac", "ElevenLabs"])
    }

    func testTheKeyIsNeverInUserDefaults() throws {
        _ = Settings(defaults: defaults)
        let account = ElevenLabsAccount(store: MemorySecretStore())
        XCTAssertFalse(account.hasKey)
        try account.saveKey("  test-key-not-real \n")
        XCTAssertTrue(account.hasKey)
        XCTAssertEqual(account.key, "test-key-not-real")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { "\($0)".contains("test-key-not-real") })
        XCTAssertFalse(UserDefaults.standard.dictionaryRepresentation().values.contains { "\($0)".contains("test-key-not-real") })
        try account.removeKey()
        XCTAssertFalse(account.hasKey)
        XCTAssertNil(account.key)
    }

    func testAnEmptyKeyIsRefused() {
        let account = ElevenLabsAccount(store: MemorySecretStore())
        XCTAssertThrowsError(try account.saveKey("  \n ")) { XCTAssertEqual($0 as? SecretStoreError, .empty) }
        XCTAssertFalse(account.hasKey)
    }

    func testOfflineModelsAreTheDocumentedOnes() {
        XCTAssertEqual(ElevenLabsAccount(store: MemorySecretStore()).models.map(\.id), ElevenLabsModels.offline)
    }

    func testLiveModelsReplaceTheOfflineList() async throws {
        let stub = try StubHTTPServer()
        defer { stub.stop() }
        stub.route("/v1/models", .json(200, #"[{"model_id":"eleven_v4_turbo","name":"v4 Turbo","can_do_text_to_speech":true,"maximum_text_length_per_request":6000}]"#))
        let url = stub.baseURL
        let account = ElevenLabsAccount(store: MemorySecretStore("test-key-not-real")) { ElevenLabsClient(baseURL: url, key: $0) }
        await account.loadModels()
        XCTAssertEqual(account.models.map(\.id), ["eleven_v4_turbo"])
        XCTAssertEqual(account.models.first?.limit, 6000)
        XCTAssertEqual(stub.requests.first?.headers["xi-api-key"], "test-key-not-real")
        // A failure keeps the list there is.
        stub.route("/v1/models", .json(500, "{}"))
        let offline = ElevenLabsAccount(store: MemorySecretStore("test-key-not-real")) { ElevenLabsClient(baseURL: url, key: $0) }
        await offline.loadModels()
        XCTAssertEqual(offline.models.map(\.id), ElevenLabsModels.offline)
    }

    func testVoicesWithoutAKeySayWhy() async {
        let account = ElevenLabsAccount(store: MemorySecretStore())
        do {
            _ = try await account.voices()
            XCTFail("no key")
        } catch {
            XCTAssertEqual(error, .noKey)
            XCTAssertEqual(error.reason, "No ElevenLabs API key is saved.")
        }
    }

    func testSourceControlOnlyWhenElevenLabsIsOn() {
        XCTAssertEqual(ReadAloudControls.rows(elevenLabsAvailable: false, source: .elevenLabs),
                       [.readAloud, .macVoice, .speed, .sample])
        XCTAssertEqual(ReadAloudControls.rows(elevenLabsAvailable: true, source: .thisMac),
                       [.readAloud, .voiceSource, .macVoice, .speed, .sample])
        XCTAssertEqual(ReadAloudControls.footnote(elevenLabsAvailable: false, source: .elevenLabs),
                       ReadAloudControls.thisMacFootnote)
    }

    func testElevenLabsRowsAndFootnote() {
        let rows = ReadAloudControls.rows(elevenLabsAvailable: true, source: .elevenLabs)
        XCTAssertEqual(rows, [.readAloud, .voiceSource, .apiKey, .elevenLabsVoice, .model])
        XCTAssertFalse(rows.contains(.sample), "no Play sample with ElevenLabs (ruling 8)")
        XCTAssertEqual(
            ReadAloudControls.footnote(elevenLabsAvailable: true, source: .elevenLabs),
            "Replies are sent to ElevenLabs to be spoken, and count against your ElevenLabs plan. If ElevenLabs can't speak a reply, it's read with this Mac's voice and a note says why.")
        XCTAssertEqual(ElevenLabsKeyRow.subtitle, "Kept in this Mac's Keychain. Never in a config file, and never seen by the agent.")
    }

    func testTheVoiceFieldShowsTheNameWhenNotEditing() {
        XCTAssertEqual(ElevenLabsVoiceRow.shown(id: "21m", name: "Rachel", editing: false), "Rachel · 21m")
        XCTAssertEqual(ElevenLabsVoiceRow.shown(id: "21m", name: "Rachel", editing: true), "21m")
        XCTAssertEqual(ElevenLabsVoiceRow.shown(id: "21m", name: nil, editing: false), "21m")
        XCTAssertEqual(ElevenLabsVoiceRow.shown(id: nil, name: nil, editing: false), "")
    }

    /// Hosted: Read aloud's block with ElevenLabs lays out (both key states).
    func testTheElevenLabsBlockHosts() throws {
        let settings = Settings(defaults: defaults)
        settings.deploymentReadAloud = true
        settings.elevenLabsAvailable = true
        settings.voiceSource = .elevenLabs
        for key in [nil, "test-key-not-real"] {
            let account = ElevenLabsAccount(store: MemorySecretStore(key))
            let reader = ReadAloud(settings: settings, synthesizer: FakeSynthesizer(), account: account)
            let host = NSHostingView(rootView: ReadAloudControls()
                .environmentObject(settings).environmentObject(reader))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 150)
        }
    }
}
