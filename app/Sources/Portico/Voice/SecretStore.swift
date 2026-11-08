import Foundation
import Security

/// v0.26 (PORT-23): where the ElevenLabs API key lives. The Keychain in the
/// app; in memory in tests. The key is never logged, never written to a
/// config file or user defaults, never sent to the gateway.
protocol SecretStore: AnyObject {
    /// Whether a secret is saved, without reading it (review M3: an attributes-only
    /// query, which never asks the person for Keychain access).
    func exists() -> Bool
    /// The secret; nil when none is saved. Throws when one is there but can't be read
    /// (the person denied access, for example).
    func read() throws -> String?
    func save(_ secret: String) throws
    func remove() throws
}

enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    /// The Keychain refused, with its status.
    case status(OSStatus)
    /// Nothing to save.
    case empty

    /// Never the secret: only what went wrong.
    var description: String {
        switch self {
        case .status(let status): "Keychain error \(status)"
        case .empty: "Nothing to save"
        }
    }
}

/// A generic password in the login Keychain (ruling 11): `service`, `account`,
/// readable only while the Mac is unlocked.
final class KeychainStore: SecretStore {
    let service: String
    let account: String

    init(service: String, account: String = "api-key") {
        self.service = service
        self.account = account
    }

    /// The app's own item: "<bundle id>.elevenlabs", account "api-key". Tests never use it.
    static func elevenLabs() -> KeychainStore {
        KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "app").elevenlabs")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func exists() -> Bool {
        var query = self.query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func read() throws -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String) throws {
        guard !secret.isEmpty else { throw SecretStoreError.empty }
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.status(status) }
        var add = query
        add.merge(update) { $1 }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.status(added) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
    }
}

/// A store in memory, for tests and previews.
final class MemorySecretStore: SecretStore {
    private var secret: String?

    init(_ secret: String? = nil) { self.secret = secret }

    func exists() -> Bool { secret != nil }

    func read() throws -> String? { secret }

    func save(_ secret: String) throws {
        guard !secret.isEmpty else { throw SecretStoreError.empty }
        self.secret = secret
    }

    func remove() throws { secret = nil }
}
