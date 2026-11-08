import Foundation

// v0.26 (PORT-23): ElevenLabs voices for Read aloud. The app calls ElevenLabs
// itself, with the key from the Keychain; the gateway never sees the key, the
// voice or the text. Every test points the client at a local stub.

struct ElevenLabsVoice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
}

struct ElevenLabsModel: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// Characters per request (`maximum_text_length_per_request`), when the API said.
    let limit: Int?
}

enum ElevenLabsModels {
    /// Larry's default (spec §2).
    static let defaultID = "eleven_v4_turbo"
    /// Offered when the models list can't be fetched: the documented text-to-speech models.
    static let offline: [String] = [
        "eleven_v4", "eleven_v4_turbo", "eleven_v3", "eleven_v3_conversational",
        "eleven_multilingual_v2", "eleven_flash_v2_5", "eleven_flash_v2",
    ]
    /// The deprecated Turbo v2 models are never offered.
    static let hidden: Set<String> = ["eleven_turbo_v2", "eleven_turbo_v2_5"]
    /// The documented limits (ruling 3), for when the live list didn't say.
    static let documentedLimits: [String: Int] = [
        "eleven_v4": 10_000, "eleven_v3": 5_000, "eleven_multilingual_v2": 10_000,
        "eleven_flash_v2_5": 40_000, "eleven_flash_v2": 30_000,
    ]
    /// Unknown models (and `eleven_v4_turbo`, `eleven_v3_conversational`) are split at this.
    static let fallbackLimit = 5_000

    /// The most characters one request may carry for `id` (ruling 3): the live list's
    /// limit, else the documented one, else 5,000.
    static func limit(for id: String, live: [ElevenLabsModel]) -> Int {
        if let limit = live.first(where: { $0.id == id })?.limit, limit > 0 { return limit }
        return documentedLimits[id] ?? fallbackLimit
    }
}

/// Why ElevenLabs couldn't speak a reply (ruling 7). Each case falls back to the
/// Mac voice, with its note under the reply. Never carries the key.
enum ElevenLabsFailure: Error, Equatable, Sendable {
    case noKey, noVoice, key, voice, quota, network, audio, http(Int)
    /// Review M3: a key is saved but couldn't be read (Keychain access denied).
    case keyUnreadable

    var note: String {
        let reason = switch self {
        case .noKey: "no ElevenLabs API key is saved."
        case .keyUnreadable: "the saved ElevenLabs key couldn't be read."
        case .noVoice: "no ElevenLabs voice is chosen."
        case .key: "ElevenLabs didn't accept the API key."
        case .voice: "ElevenLabs doesn't know this voice."
        case .quota: "your ElevenLabs plan's limit was reached."
        case .network: "ElevenLabs couldn't be reached."
        case .audio: "ElevenLabs sent audio this Mac couldn't play."
        case .http(let code): "ElevenLabs returned an error (HTTP \(code))."
        }
        return Self.prefix + reason
    }

    /// What every note starts with; Labs drops it where the Mac voice isn't involved.
    static let prefix = "Read with this Mac's voice: "

    /// The note without "Read with this Mac's voice: ", capitalised ("ElevenLabs didn't accept the API key.").
    var reason: String {
        let text = String(note.dropFirst(Self.prefix.count))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A response's failure (ruling 7), or nil for a success.
    static func classify(status: Int, body: Data) -> ElevenLabsFailure? {
        if (200..<300).contains(status) { return nil }
        let detail = detailStatus(body)
        if detail == "quota_exceeded" { return .quota }
        if detail == "voice_not_found" || status == 404 { return .voice }
        if status == 401 || status == 403 { return .key }
        if status == 429 { return .quota }
        return .http(status)
    }

    /// `detail.status` when `detail` is an object (a 422's `detail` is a list: none).
    private static func detailStatus(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = object["detail"] as? [String: Any]
        else { return nil }
        return detail["status"] as? String
    }
}

/// The three calls the app makes. `baseURL` is the API's in the app, a stub's in tests.
struct ElevenLabsClient: Sendable {
    static let api = URL(string: "https://api.elevenlabs.io")!
    static let timeout: TimeInterval = 30
    /// Voices are fetched 100 at a time, at most this many pages (ruling 1).
    static let maxVoicePages = 10

    let baseURL: URL
    private let key: String
    let session: URLSession

    /// Review H1: the client's own session. Ephemeral, with no URL cache and no
    /// cookies, so a request (and its `xi-api-key` header) is never written to
    /// the app's `Cache.db`. Never `.shared`.
    static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(baseURL: URL = api, key: String, session: URLSession = ElevenLabsClient.privateSession) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
    }

    /// The account's voices, by name (`GET /v2/voices`, following `next_page_token`).
    func voices() async throws(ElevenLabsFailure) -> [ElevenLabsVoice] {
        struct Page: Decodable {
            struct Voice: Decodable {
                let voice_id: String
                let name: String?
            }
            let voices: [Voice]
            let has_more: Bool?
            let next_page_token: String?
        }
        var all: [ElevenLabsVoice] = []
        var token: String?
        for _ in 0..<Self.maxVoicePages {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) }
            let data = try await send(request(path: "/v2/voices", query: query, accept: "application/json"))
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw .http(200) }
            all += page.voices.map { ElevenLabsVoice(id: $0.voice_id, name: $0.name ?? $0.voice_id) }
            guard page.has_more != false, let next = page.next_page_token, !next.isEmpty else { break }
            token = next
        }
        return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The text-to-speech models, deprecated Turbo v2 left out (`GET /v1/models`, ruling 2).
    func models() async throws(ElevenLabsFailure) -> [ElevenLabsModel] {
        struct Model: Decodable {
            let model_id: String
            let name: String?
            let can_do_text_to_speech: Bool?
            let maximum_text_length_per_request: Int?
        }
        let data = try await send(request(path: "/v1/models", query: [], accept: "application/json"))
        guard let models = try? JSONDecoder().decode([Model].self, from: data) else { throw .http(200) }
        return models
            .filter { $0.can_do_text_to_speech == true && !ElevenLabsModels.hidden.contains($0.model_id) }
            .map { ElevenLabsModel(id: $0.model_id, name: $0.name ?? $0.model_id, limit: $0.maximum_text_length_per_request) }
    }

    /// One chunk of speech as MP3 (`POST /v1/text-to-speech/{voice}`, `mp3_44100_128`).
    func speech(_ text: String, voiceID: String, modelID: String) async throws(ElevenLabsFailure) -> Data {
        let voice = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? voiceID
        var request = request(
            path: "/v1/text-to-speech/\(voice)",
            query: [URLQueryItem(name: "output_format", value: "mp3_44100_128")], accept: "audio/mpeg")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelID])
        let data = try await send(request)
        // The content type isn't trusted; an empty body is no audio (the player judges the rest).
        guard !data.isEmpty else { throw .audio }
        return data
    }

    private func request(path: String, query: [URLQueryItem], accept: String) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws(ElevenLabsFailure) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = ElevenLabsFailure.classify(status: status, body: data) { throw failure }
        return data
    }
}
