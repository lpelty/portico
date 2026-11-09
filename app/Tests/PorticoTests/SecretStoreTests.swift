import Security
import XCTest
@testable import Portico

/// v0.26 (PORT-23): the ElevenLabs key's store. Tests never touch the app's
/// own Keychain item: a test service, deleted after.
final class SecretStoreTests: XCTestCase {
    func testMemoryStoreRoundTrips() throws {
        let store = MemorySecretStore()
        XCTAssertNil(try store.read())
        XCTAssertFalse(store.exists())
        try store.save("test-key-not-real")
        XCTAssertEqual(try store.read(), "test-key-not-real")
        try store.remove()
        XCTAssertNil(try store.read())
        XCTAssertThrowsError(try store.save("")) { XCTAssertEqual($0 as? SecretStoreError, .empty) }
    }

    func testKeychainStoreRoundTripsUnderATestService() throws {
        let store = KeychainStore(service: "tests.elevenlabs.\(UUID().uuidString)")
        defer { try? store.remove() }
        XCTAssertNil(try store.read())
        do {
            try store.save("test-key-not-real")
        } catch SecretStoreError.status(let status)
            where status == errSecMissingEntitlement || status == errSecInteractionNotAllowed {
            throw XCTSkip("the Keychain refused this test runner (\(status)); the in-memory store covers the logic")
        }
        XCTAssertEqual(try store.read(), "test-key-not-real")
        XCTAssertTrue(store.exists(), "an attributes-only query finds it")
        try store.save("test-key-2")
        XCTAssertEqual(try store.read(), "test-key-2")
        try store.remove()
        XCTAssertNil(try store.read())
        try store.remove()  // removing nothing is fine
        XCTAssertThrowsError(try store.save("")) { XCTAssertEqual($0 as? SecretStoreError, .empty) }
    }

    func testErrorsNeverCarryTheSecret() {
        XCTAssertFalse("\(SecretStoreError.status(-25300))".contains("test-key"))
        XCTAssertEqual("\(SecretStoreError.empty)", "Nothing to save")
    }

    /// The app's service name; and no test calls `.elevenLabs()` (the app's real item) but this one.
    func testTheAppsServiceIsNotUsedByTests() throws {
        let service = KeychainStore.elevenLabs().service
        XCTAssertTrue(service.hasSuffix(" — ElevenLabs key"), service)
        XCTAssertEqual(KeychainStore.elevenLabs().account, "api-key")
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("KeychainStore" + ".elevenLabs()") { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["SecretStoreTests.swift"])
    }

    /// Review L7: what the person sees in Keychain Access and an access prompt names the app as
    /// the person knows it, never the product or a bundle id.
    func testTheItemsNameIsThePersonsAppName() {
        let named = KeychainStore.elevenLabs(appName: "Acme Agent")
        XCTAssertEqual(named.service, "Acme Agent — ElevenLabs key")
        XCTAssertEqual(named.label, "Acme Agent — ElevenLabs key")
        XCTAssertEqual(KeychainStore.elevenLabs(appName: nil).label, "This app — ElevenLabs key")
        XCTAssertEqual(KeychainStore.elevenLabs(appName: "  ").label, "This app — ElevenLabs key")
        for store in [KeychainStore.elevenLabs(), named] {
            XCTAssertFalse(store.service.lowercased().contains("portico"), store.service)
            XCTAssertFalse(store.label.lowercased().contains("portico"), store.label)
            XCTAssertFalse(store.service.contains("dev."), store.service)
        }
    }
}
