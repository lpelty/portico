import Foundation

/// v0.26 (PORT-23): the ElevenLabs side of Read aloud: whether a key is saved
/// (the key itself stays in the store, the Keychain in the app), the models
/// to offer, and the account's voices for Choose…. One per app.
@MainActor
final class ElevenLabsAccount: ObservableObject {
    private let store: SecretStore
    private let client: (String) -> ElevenLabsClient

    @Published private(set) var hasKey: Bool
    /// The live text-to-speech models once fetched this launch, else the documented IDs (limit nil).
    @Published private(set) var models: [ElevenLabsModel]

    init(store: SecretStore, client: @escaping (String) -> ElevenLabsClient = { ElevenLabsClient(key: $0) }) {
        self.store = store
        self.client = client
        // Review M3: an attributes-only query; the secret itself is read only when it's used.
        hasKey = store.exists()
        models = Self.offlineModels
    }

    static var offlineModels: [ElevenLabsModel] {
        ElevenLabsModels.offline.map { ElevenLabsModel(id: $0, name: $0, limit: nil) }
    }

    /// The key once read this session (review M3: read once, when first used).
    private var cachedKey: String?
    /// A key is saved but couldn't be read (the person denied Keychain access).
    @Published private(set) var keyUnreadable = false

    /// The saved key, for Read aloud only. Never shown, logged or sent anywhere but ElevenLabs.
    /// Read from the store the first time it's needed, then kept in memory for the session.
    var key: String? {
        if let cachedKey { return cachedKey }
        do {
            let read = try store.read()
            cachedKey = read
            keyUnreadable = false
            if read == nil { hasKey = false }
            return read
        } catch {
            keyUnreadable = true
            return nil
        }
    }

    /// Saves `key` trimmed; an empty one is refused (`SecretStoreError.empty`).
    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretStoreError.empty }
        try store.save(trimmed)
        hasKey = true
        cachedKey = trimmed
        keyUnreadable = false
    }

    func removeKey() throws {
        try store.remove()
        hasKey = false
        cachedKey = nil
        keyUnreadable = false
        models = Self.offlineModels
    }

    /// Fetches the models; on any failure (or no key) the offline list stays.
    func loadModels() async {
        guard let key else { return }
        if let live = try? await client(key).models(), !live.isEmpty { models = live }
    }

    /// The account's voices, by name, for Choose….
    func voices() async throws(ElevenLabsFailure) -> [ElevenLabsVoice] {
        guard let key else { throw keyUnreadable ? .keyUnreadable : .noKey }
        return try await client(key).voices()
    }

    /// A client with the saved key, for speaking; nil without a key.
    func speechClient() -> ElevenLabsClient? {
        key.map(client)
    }
}
