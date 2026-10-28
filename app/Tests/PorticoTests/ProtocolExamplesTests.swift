import Foundation
import XCTest

@testable import Portico

/// The drift test between the gateway's protocol and the app's types.
///
/// Every `protocol/examples/server.*.json` must decode into a `ServerMessage`
/// case, and every `client.*.json` must decode into a `ClientMessage` and
/// encode back to the same JSON (compared after key sorting). A new example
/// without a Swift case, a renamed field, or a dropped field fails here.
final class ProtocolExamplesTests: XCTestCase {

    // MARK: - locating the examples

    /// `protocol/examples/` at the repo root, found relative to this file:
    /// app/Tests/PorticoTests/ProtocolExamplesTests.swift -> ../../../../protocol/examples
    private static var examplesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PorticoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol/examples", isDirectory: true)
    }

    private static func exampleFiles(prefix: String) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(
            at: examplesDir, includingPropertiesForKeys: nil)
        return all
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Canonical bytes: parsed and re-serialised with sorted keys, so two
    /// documents compare on content, not on whitespace or key order.
    private static func canonical(_ data: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - tests

    func testExamplesDirectoryExists() throws {
        let server = try Self.exampleFiles(prefix: "server.")
        let client = try Self.exampleFiles(prefix: "client.")
        XCTAssertFalse(server.isEmpty, "no server examples under \(Self.examplesDir.path)")
        XCTAssertFalse(client.isEmpty, "no client examples under \(Self.examplesDir.path)")
    }

    func testEveryServerExampleDecodes() throws {
        let decoder = JSONDecoder()
        var seen: [String] = []
        for file in try Self.exampleFiles(prefix: "server.") {
            let data = try Data(contentsOf: file)
            do {
                let message = try decoder.decode(ServerMessage.self, from: data)
                // The type key in the file must match the case we decoded into.
                let raw = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(
                    message.type, raw["type"] as? String,
                    "\(file.lastPathComponent) decoded into the wrong case")
                // The envelope must carry what the file carries.
                XCTAssertEqual(message.envelope.chat, raw["chat"] as? Int, file.lastPathComponent)
                XCTAssertEqual(message.envelope.id, raw["id"] as? String, file.lastPathComponent)
                XCTAssertEqual(message.envelope.seq, raw["seq"] as? Int, file.lastPathComponent)
                seen.append(message.type)
            } catch {
                XCTFail("\(file.lastPathComponent) failed to decode: \(error)")
            }
        }
        XCTAssertEqual(seen.count, Set(seen).count, "two server examples decoded to one type")
    }

    func testEveryServerExampleRoundTrips() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for file in try Self.exampleFiles(prefix: "server.") {
            let data = try Data(contentsOf: file)
            do {
                let message = try decoder.decode(ServerMessage.self, from: data)
                let encoded = try encoder.encode(message)
                XCTAssertEqual(
                    try Self.canonical(encoded), try Self.canonical(data),
                    "\(file.lastPathComponent) did not survive a round trip")
            } catch {
                XCTFail("\(file.lastPathComponent) failed: \(error)")
            }
        }
    }

    func testEveryClientExampleRoundTrips() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for file in try Self.exampleFiles(prefix: "client.") {
            let data = try Data(contentsOf: file)
            do {
                let message = try decoder.decode(ClientMessage.self, from: data)
                let raw = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(
                    message.type, raw["type"] as? String,
                    "\(file.lastPathComponent) decoded into the wrong case")
                let encoded = try encoder.encode(message)
                XCTAssertEqual(
                    try Self.canonical(encoded), try Self.canonical(data),
                    "\(file.lastPathComponent) did not survive a round trip")
            } catch {
                XCTFail("\(file.lastPathComponent) failed: \(error)")
            }
        }
    }

    func testClientMessagesStampTimestampAndType() throws {
        // A freshly built client message carries an ISO-8601 UTC `ts` and its `type`.
        let message = ClientMessage.turnStop(TurnStop(chat: 3))
        let data = try JSONEncoder().encode(message)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["type"] as? String, "turn.stop")
        XCTAssertEqual(raw["chat"] as? Int, 3)
        let ts = try XCTUnwrap(raw["ts"] as? String)
        XCTAssertTrue(ts.hasSuffix("Z"), "ts must be UTC with a Z suffix, got \(ts)")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: ts), "ts must parse as ISO-8601: \(ts)")
    }

    func testUnknownServerTypeFailsToDecode() {
        let data = Data(#"{"type":"nope","ts":"2026-10-27T12:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: data))
    }
}
