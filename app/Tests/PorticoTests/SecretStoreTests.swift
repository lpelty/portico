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
        XCTAssertTrue(service.hasSuffix(".elevenlabs"))
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
}
