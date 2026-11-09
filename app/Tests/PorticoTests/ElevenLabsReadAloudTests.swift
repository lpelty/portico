import XCTest
@testable import Portico

/// Records what it was asked to play; finishes when told; throws on demand.
@MainActor
final class FakePlayer: AudioPlaying {
    var onFinish: ((Int) -> Void)?
    private(set) var plays: [(data: Data, token: Int)] = []
    private(set) var stops = 0
    var failsToPlay = false

    func play(_ mp3: Data, token: Int) throws {
        if failsToPlay { throw AudioPlaybackError.unplayable }
        plays.append((mp3, token))
    }

    func stop() { stops += 1 }

    func finishLast() { if let last = plays.last { onFinish?(last.token) } }
}

/// v0.26 (PORT-23): Read aloud with ElevenLabs, chunk by chunk, against a
/// local stub; every failure reads with the Mac voice and says why.
@MainActor
final class ElevenLabsReadAloudTests: XCTestCase {
    private var settings: Settings!
    private var synth: FakeSynthesizer!
    private var player: FakePlayer!
    private var stub: StubHTTPServer!
    private var store: MemorySecretStore!
    private var account: ElevenLabsAccount!
    private var reader: ReadAloud!
    private let path = "/v1/text-to-speech/voice-1"

    override func setUp() async throws {
        let name = "ElevenLabsReadAloudTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: name)!)
        settings.deploymentReadAloud = true
        settings.elevenLabsAvailable = true
        settings.voiceSource = .elevenLabs
        settings.elevenLabsVoiceID = "voice-1"
        synth = FakeSynthesizer()
        player = FakePlayer()
        stub = try StubHTTPServer()
        store = MemorySecretStore("test-key-not-real")
        let url = stub.baseURL
        account = ElevenLabsAccount(store: store) { ElevenLabsClient(baseURL: url, key: $0) }
        reader = ReadAloud(
            settings: settings, synthesizer: synth, escape: EscapeKey(),
            installedVoices: { [VoiceOption(id: "voice.a", name: "A", language: "en-US")] },
            player: player, account: account)
    }

    override func tearDown() async throws {
        reader.stop()
        stub.stop()
    }

    private func wait(_ seconds: Double = 0.3, until done: () -> Bool = { false }) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until, !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func audio(_ byte: UInt8) -> StubHTTPServer.Response {
        StubHTTPServer.Response(status: 200, headers: ["Content-Type": "audio/mpeg"], body: Data([byte, byte, byte]))
    }

    /// Three paragraphs that don't fit together under the forced limit.
    private let reply = "First paragraph here.\n\nSecond paragraph here.\n\nThird paragraph here."

    private func forceSmallLimit() async throws {
        stub.route("/v1/models", .json(200, #"[{"model_id":"eleven_v4_turbo","can_do_text_to_speech":true,"maximum_text_length_per_request":25}]"#))
        await account.loadModels()
        XCTAssertEqual(account.models.first?.limit, 25)
    }

    func testAReplyIsSpokenInChunksInOrder() async throws {
        try await forceSmallLimit()
        stub.route(path, audio(1), audio(2), audio(3))
        reader.read(reply, key: "r1")
        XCTAssertEqual(reader.reading, "r1")
        for expected in 1...3 {
            await wait(2) { player.plays.count == expected }
            XCTAssertEqual(player.plays.count, expected)
            player.finishLast()
        }
        await wait(0.5) { reader.reading == nil }
        XCTAssertNil(reader.reading)
        XCTAssertEqual(player.plays.map { $0.data.first }, [1, 2, 3])
        let texts = stub.requests.filter { $0.path == path }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body) as? [String: String])?["text"]
        }
        XCTAssertEqual(texts, ["First paragraph here.", "Second paragraph here.", "Third paragraph here."])
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertNil(reader.note(for: "r1"))
    }

    func testStopStopsEveryChunk() async throws {
        try await forceSmallLimit()
        stub.route(path, audio(1), audio(2), audio(3))
        reader.read(reply, key: "r1")
        await wait(2) { player.plays.count == 1 }
        reader.stop()
        XCTAssertNil(reader.reading)
        XCTAssertGreaterThan(player.stops, 0)
        player.finishLast()
        await wait(0.5)
        XCTAssertEqual(player.plays.count, 1, "nothing after Stop")
        XCTAssertTrue(synth.spoken.isEmpty)
    }

    func testStopDuringTheRequestPlaysNothingLater() async throws {
        var slow = audio(1)
        slow.delay = 0.3
        stub.route(path, slow)
        reader.read("Hello there.", key: "r1")
        await wait(0.05)
        reader.stop()
        await wait(0.5)
        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertTrue(synth.spoken.isEmpty)
        XCTAssertNil(reader.note(for: "r1"))
    }

    func testNoKeyFallsBackWithANote() async throws {
        try store.remove()
        reader.read("Hello there.", key: "r1")
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.noKey.note)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testNoVoiceFallsBackWithANote() {
        settings.elevenLabsVoiceID = nil
        reader.read("Hello there.", key: "r1")
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.noVoice.note)
    }

    func testQuotaFallsBackWithANote() async {
        stub.route(path, .json(401, #"{"detail":{"status":"quota_exceeded"}}"#))
        reader.read("Hello there.", key: "r1")
        await wait(2) { !synth.spoken.isEmpty }
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.quota.note)
        XCTAssertEqual(reader.reading, "r1", "still reading, with the Mac voice")
        synth.finishLast()
        XCTAssertNil(reader.reading)
    }

    func testAFailureMidwayReadsTheRestWithTheMacVoice() async throws {
        try await forceSmallLimit()
        stub.route(path, audio(1), .json(500, "{}"))
        reader.read(reply, key: "r1")
        await wait(2) { player.plays.count == 1 }
        player.finishLast()
        await wait(2) { !synth.spoken.isEmpty }
        XCTAssertEqual(synth.spoken.map(\.text), ["Second paragraph here.\n\nThird paragraph here."])
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.http(500).note)
        XCTAssertEqual(player.plays.count, 1)
    }

    func testA200WithNoAudioFallsBackWithANote() async {
        stub.route(path, StubHTTPServer.Response(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>proxy</html>".utf8)))
        player.failsToPlay = true
        reader.read("Hello there.", key: "r1")
        await wait(2) { !synth.spoken.isEmpty }
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(reader.note(for: "r1"), "Read with this Mac's voice: ElevenLabs sent audio this Mac couldn't play.")
    }

    func testAnEmpty200FallsBackWithANote() async {
        stub.route(path, StubHTTPServer.Response(status: 200))
        reader.read("Hello there.", key: "r1")
        await wait(2) { !synth.spoken.isEmpty }
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.audio.note)
    }

    func testThisMacSourceNeverCallsElevenLabs() async {
        settings.voiceSource = .thisMac
        stub.route(path, audio(1))
        reader.read("Hello there.", key: "r1")
        await wait(0.3)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(player.plays.isEmpty)
        XCTAssertEqual(synth.spoken.map(\.text), ["Hello there."])
        XCTAssertNil(reader.note(for: "r1"))
    }

    func testWithoutTheGatewaysItemTheMacSpeaks() async {
        settings.elevenLabsAvailable = false
        reader.read("Hello there.", key: "r1")
        await wait(0.2)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(synth.spoken.count, 1)
    }

    func testANewReadClearsTheOldNoteOnSuccess() async {
        stub.route(path, .json(429, "{}"), audio(1))
        reader.read("Hello there.", key: "r1")
        await wait(2) { !synth.spoken.isEmpty }
        XCTAssertEqual(reader.note(for: "r1"), ElevenLabsFailure.quota.note)
        synth.finishLast()
        reader.read("Hello there.", key: "r1")
        await wait(2) { !player.plays.isEmpty }
        XCTAssertEqual(player.plays.count, 1)
        XCTAssertNil(reader.note(for: "r1"))
    }
}
