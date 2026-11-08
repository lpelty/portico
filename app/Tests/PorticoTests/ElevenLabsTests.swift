import XCTest
@testable import Portico

/// v0.26 (PORT-23): the ElevenLabs client against a local stub. Never the
/// real API, never a real key.
final class ElevenLabsTests: XCTestCase {
    static let key = "test-key-not-real"
    private var stub: StubHTTPServer!

    override func setUpWithError() throws {
        stub = try StubHTTPServer()
        XCTAssertNotEqual(stub.port, 0)
    }

    override func tearDown() { stub.stop() }

    private var client: ElevenLabsClient { ElevenLabsClient(baseURL: stub.baseURL, key: Self.key) }

    private func failure(_ call: () async throws -> Void) async -> ElevenLabsFailure? {
        do { try await call(); return nil } catch { return error as? ElevenLabsFailure }
    }

    func testSpeechRequestIsExactly() async throws {
        stub.route("/v1/text-to-speech/v1d", .audio(3))
        let data = try await client.speech("Hello.", voiceID: "v1d", modelID: "eleven_v4_turbo")
        XCTAssertEqual(data.count, 3)
        let r = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/text-to-speech/v1d")
        XCTAssertEqual(r.query["output_format"], "mp3_44100_128")
        XCTAssertEqual(r.headers["xi-api-key"], Self.key)
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.headers["accept"], "audio/mpeg")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: r.body) as? [String: String],
                       ["text": "Hello.", "model_id": "eleven_v4_turbo"])
    }

    func testFailuresAreClassified() async throws {
        let path = "/v1/text-to-speech/v"
        let cases: [(StubHTTPServer.Response, ElevenLabsFailure)] = [
            (.json(401, #"{"detail":{"status":"quota_exceeded","message":"x"}}"#), .quota),
            (.json(401, #"{"detail":{"status":"invalid_api_key"}}"#), .key),
            (.json(403, "{}"), .key),
            (.json(400, #"{"detail":{"status":"voice_not_found"}}"#), .voice),
            (.json(404, "{}"), .voice),
            (.json(429, "{}"), .quota),
            (.json(422, #"{"detail":[{"loc":["body"],"msg":"bad"}]}"#), .http(422)),
            (.json(500, "oops"), .http(500)),
            (StubHTTPServer.Response(status: 200, headers: ["Content-Type": "audio/mpeg"]), .audio),
        ]
        for (response, want) in cases {
            stub.route(path, response)
            let got = await failure { _ = try await client.speech("Hi", voiceID: "v", modelID: "m") }
            XCTAssertEqual(got, want, "\(response.status)")
        }
        // A closed port: network.
        let closed = try StubHTTPServer()
        let url = closed.baseURL
        closed.stop()
        try await Task.sleep(for: .milliseconds(100))
        let offline = ElevenLabsClient(baseURL: url, key: Self.key)
        let got = await failure { _ = try await offline.speech("Hi", voiceID: "v", modelID: "m") }
        XCTAssertEqual(got, ElevenLabsFailure.network)
    }

    func testTheKeyNeverAppearsInAFailure() async {
        stub.route("/v1/text-to-speech/v", .json(401, #"{"detail":{"status":"invalid_api_key","message":"test-key-not-real"}}"#))
        let got = await failure { _ = try await client.speech("Hi", voiceID: "v", modelID: "m") }
        XCTAssertEqual(got, ElevenLabsFailure.key)
        XCTAssertFalse(String(describing: got).contains(Self.key))
        XCTAssertFalse(String(reflecting: got).contains(Self.key))
        XCTAssertFalse((got?.note ?? "").contains(Self.key))
    }

    func testNotes() {
        XCTAssertEqual(ElevenLabsFailure.noKey.note, "Read with this Mac's voice: no ElevenLabs API key is saved.")
        XCTAssertEqual(ElevenLabsFailure.noVoice.note, "Read with this Mac's voice: no ElevenLabs voice is chosen.")
        XCTAssertEqual(ElevenLabsFailure.key.note, "Read with this Mac's voice: ElevenLabs didn't accept the API key.")
        XCTAssertEqual(ElevenLabsFailure.voice.note, "Read with this Mac's voice: ElevenLabs doesn't know this voice.")
        XCTAssertEqual(ElevenLabsFailure.quota.note, "Read with this Mac's voice: your ElevenLabs plan's limit was reached.")
        XCTAssertEqual(ElevenLabsFailure.network.note, "Read with this Mac's voice: ElevenLabs couldn't be reached.")
        XCTAssertEqual(ElevenLabsFailure.audio.note, "Read with this Mac's voice: ElevenLabs sent audio this Mac couldn't play.")
        XCTAssertEqual(ElevenLabsFailure.http(502).note, "Read with this Mac's voice: ElevenLabs returned an error (HTTP 502).")
        XCTAssertEqual(ElevenLabsFailure.key.reason, "ElevenLabs didn't accept the API key.")
        XCTAssertEqual(ElevenLabsFailure.quota.reason, "Your ElevenLabs plan's limit was reached.")
    }

    func testVoicesFollowPagesAndSortByName() async throws {
        stub.route("/v2/voices",
                   .json(200, #"{"voices":[{"voice_id":"z1","name":"Zoe"},{"voice_id":"a1","name":"Adam"}],"has_more":true,"total_count":3,"next_page_token":"p2"}"#),
                   .json(200, #"{"voices":[{"voice_id":"m1","name":"Maya"}],"has_more":false,"total_count":3,"next_page_token":null}"#))
        let voices = try await client.voices()
        XCTAssertEqual(voices.map(\.name), ["Adam", "Maya", "Zoe"])
        XCTAssertEqual(voices.map(\.id), ["a1", "m1", "z1"])
        let requests = stub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests[0].query["page_size"], "100")
        XCTAssertNil(requests[0].query["next_page_token"])
        XCTAssertEqual(requests[1].query["next_page_token"], "p2")
        XCTAssertEqual(requests[0].headers["xi-api-key"], Self.key)
    }

    func testModelsKeepTextToSpeechAndHideTurbo() async throws {
        stub.route("/v1/models", .json(200, """
            [{"model_id":"eleven_v4_turbo","name":"Eleven v4 Turbo","can_do_text_to_speech":true,"maximum_text_length_per_request":7000},
             {"model_id":"eleven_turbo_v2_5","name":"Turbo v2.5","can_do_text_to_speech":true},
             {"model_id":"eleven_sts","name":"STS","can_do_text_to_speech":false}]
            """))
        let models = try await client.models()
        XCTAssertEqual(models.map(\.id), ["eleven_v4_turbo"])
        XCTAssertEqual(models.first?.limit, 7000)
        XCTAssertEqual(models.first?.name, "Eleven v4 Turbo")
    }

    func testLimits() {
        XCTAssertEqual(ElevenLabsModels.limit(for: "eleven_flash_v2_5", live: []), 40_000)
        XCTAssertEqual(ElevenLabsModels.limit(for: "eleven_v4_turbo", live: []), 5_000)
        XCTAssertEqual(ElevenLabsModels.limit(for: "eleven_v4", live: []), 10_000)
        XCTAssertEqual(ElevenLabsModels.limit(for: "something_new", live: []), 5_000)
        XCTAssertEqual(ElevenLabsModels.limit(for: "eleven_v4", live: [.init(id: "eleven_v4", name: "", limit: 7_000)]), 7_000)
        XCTAssertEqual(ElevenLabsModels.limit(for: "eleven_v3", live: [.init(id: "eleven_v3", name: "", limit: nil)]), 5_000)
        XCTAssertEqual(ElevenLabsModels.defaultID, "eleven_v4_turbo")
        XCTAssertFalse(ElevenLabsModels.offline.contains { ElevenLabsModels.hidden.contains($0) })
    }

    /// The gateway and the protocol never know ElevenLabs (the key stays in the app).
    func testNoElevenLabsInTheGatewayOrProtocolCode() throws {
        for folder in ["Gateway", "Protocol"] {
            let dir = ListFontSweepTests.sources.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(text.contains("ElevenLabs"), "\(folder)/\(file.lastPathComponent)")
            }
        }
    }

    // MARK: - v0.26 review H1: the key never reaches an HTTP cache

    func testNothingIsCachedAndTheSessionIsPrivate() async throws {
        let configuration = ElevenLabsClient.privateSession.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(ElevenLabsClient(key: Self.key).session === ElevenLabsClient.privateSession, "never .shared")

        var cacheable = StubHTTPServer.Response.json(200, #"[{"model_id":"eleven_v4","can_do_text_to_speech":true}]"#)
        cacheable.headers["Cache-Control"] = "max-age=3600"
        stub.route("/v1/models", cacheable)
        let client = ElevenLabsClient(baseURL: stub.baseURL, key: Self.key)
        _ = try await client.models()
        _ = try await client.models()
        XCTAssertEqual(stub.requests.filter { $0.path == "/v1/models" }.count, 2, "the second GET isn't served from a cache")
        var request = URLRequest(url: stub.baseURL.appendingPathComponent("v1/models"))
        request.setValue(Self.key, forHTTPHeaderField: "xi-api-key")
        XCTAssertNil(URLCache.shared.cachedResponse(for: request), "nothing in the shared cache")
    }
}
