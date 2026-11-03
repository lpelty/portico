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
                // `server.<type>.<variant>.json` files show another shape of one type.
                if file.lastPathComponent == "server.\(message.type).json" { seen.append(message.type) }
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

    // MARK: - v0.16 fields no example carries

    func testThreadExamplesDecodeIntoTheirCases() throws {
        let decoder = JSONDecoder()
        func client(_ name: String) throws -> ClientMessage {
            try decoder.decode(ClientMessage.self, from: Data(contentsOf: Self.examplesDir.appendingPathComponent(name)))
        }
        guard case .threadStart(let start) = try client("client.thread.start.json") else { return XCTFail("thread.start") }
        XCTAssertEqual(start.close, 15)
        guard case .threadDismiss(let dismiss) = try client("client.thread.dismiss.json") else { return XCTFail("thread.dismiss") }
        XCTAssertEqual(dismiss.proposal, "p-7c21")
        guard case .threadClose(let close) = try client("client.thread.close.json") else { return XCTFail("thread.close") }
        XCTAssertTrue(close.log)
    }

    func testThreadCloseWithoutLoggingEncodesLogFalse() throws {
        let data = try JSONEncoder().encode(ClientMessage.threadClose(ThreadClose(chat: 15, log: false, id: "req-1")))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(raw["type"] as? String, "thread.close")
        XCTAssertEqual(raw["log"] as? Bool, false)
        let back = try JSONDecoder().decode(ClientMessage.self, from: data)
        guard case .threadClose(let close) = back else { return XCTFail("thread.close") }
        XCTAssertFalse(close.log)
    }

    func testAQuestionCardCarriesItsToolUseAndPreviews() throws {
        let json = #"""
            {"type":"card.ask","chat":1,"id":"card-9","kind":"question","title":"Acme asks","tool_use_id":"toolu_q",
             "questions":[{"question":"Which tone for step 2?","header":"Tone","multi_select":false,
               "options":[{"label":"Plain","description":"Short words","preview":"**Plain**: we ship today."},
                          {"label":"Warm","description":"Friendly"}]}],
             "seq":3,"ts":"2026-11-02T12:00:00Z"}
            """#
        guard case .cardAsk(let card) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("card.ask")
        }
        XCTAssertEqual(card.toolUseId, "toolu_q")
        XCTAssertEqual(card.questions?.first?.options.map(\.preview), ["**Plain**: we ship today.", nil])
        let encoded = try JSONEncoder().encode(Option(label: "Warm", description: "Friendly"))
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(raw["preview"], "no preview: none on the wire")
    }

    func testACardAnswerMayDecline() throws {
        for decline in QuestionDecline.allCases {
            let answer = CardAnswer.declining(chat: 1, id: "card-9", decline)
            let data = try JSONEncoder().encode(ClientMessage.cardAnswer(answer))
            let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((raw["answer"] as? [String: Any])?["declined"] as? String, decline.rawValue)
            guard case .cardAnswer(let back) = try JSONDecoder().decode(ClientMessage.self, from: data) else {
                return XCTFail("card.answer")
            }
            XCTAssertEqual(back.declined, decline)
        }
        XCTAssertEqual(QuestionDecline.allCases.map(\.rawValue), ["skipped", "dismissed", "replied"])
        let answered = CardAnswer(chat: 1, id: "card-9", answer: ["answers": .object(["Which tone?": .string("Plain")])])
        XCTAssertNil(answered.declined)
    }

    func testToolFinishedCarriesAnswers() throws {
        let json = #"""
            {"type":"tool.finished","chat":1,"turn":2,"tool_use_id":"toolu_q","ok":true,"summary":"Answered",
             "answers":{"Which tone for step 2?":"Plain","Which steps?":["One","Two"]},"seq":7,"ts":"2026-11-02T12:00:00Z"}
            """#
        let data = Data(json.utf8)
        guard case .toolFinished(let finished) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            return XCTFail("tool.finished")
        }
        XCTAssertEqual(finished.answers?["Which tone for step 2?"], .one("Plain"))
        XCTAssertEqual(finished.answers?["Which steps?"], .many(["One", "Two"]))
        XCTAssertEqual(
            try Self.canonical(JSONEncoder().encode(ServerMessage.toolFinished(finished))), try Self.canonical(data))

        let older = #"{"type":"tool.finished","chat":1,"turn":2,"tool_use_id":"toolu_r","ok":true,"summary":"Read","ts":"2026-11-02T12:00:00Z"}"#
        guard case .toolFinished(let plain) = try JSONDecoder().decode(ServerMessage.self, from: Data(older.utf8)) else {
            return XCTFail("tool.finished")
        }
        XCTAssertNil(plain.answers)
    }

    // MARK: - v0.17 fields no example carries

    func testAShowActDecodes() throws {
        let json = #"{"type":"viewer.act","id":"a","chat":1,"action":"show","args":{"artifact":"art-1","location":"https://acme.example"}}"#
        guard case .viewerAct(let act) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("viewer.act")
        }
        XCTAssertEqual(act.action, .show)
        XCTAssertEqual(act.args["artifact"], .string("art-1"))
        XCTAssertEqual(act.args["location"], .string("https://acme.example"))
    }

    func testTheAppSaysItAnswersTheShow() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("viewer.show.v1"))
        XCTAssertEqual(ViewerAct.showCapability, "viewer.show.v1")
    }

    func testViewerDefaultsPropertiesIsOptional() throws {
        func defaults(_ viewer: String) throws -> ViewerDefaults? {
            let json = #"{"type":"hello","protocol":1,"gateway_version":"0.17.0","epoch":"e","brand":{"name":"Portico","agent_name":"Agent"},"actions":[],"roots":[],"commands":[],"capabilities":[],"ts":"2026-11-02T12:00:00Z","viewer_defaults":"# + viewer + "}"
            guard case .hello(let hello) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
                XCTFail("hello")
                return nil
            }
            return hello.viewerDefaults
        }
        XCTAssertEqual(try defaults(#"{"act_hosts":[],"properties":"open"}"#)?.properties, "open")
        let without = try XCTUnwrap(try defaults(#"{"act_hosts":["acme.example"]}"#))
        XCTAssertNil(without.properties)
        XCTAssertEqual(without.actHosts, ["acme.example"])
    }

    // MARK: - v0.18 MCP Apps

    func testTheAppDeclaresApps() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("apps.v1"))
    }

    func testAppExamplesDecodeIntoTheirCases() throws {
        let decoder = JSONDecoder()
        func server(_ name: String) throws -> ServerMessage {
            try decoder.decode(ServerMessage.self, from: Data(contentsOf: Self.examplesDir.appendingPathComponent(name)))
        }
        func client(_ name: String) throws -> ClientMessage {
            try decoder.decode(ClientMessage.self, from: Data(contentsOf: Self.examplesDir.appendingPathComponent(name)))
        }
        guard case .appOpen(let open) = try server("server.app.open.json") else { return XCTFail("app.open") }
        XCTAssertEqual(open.serverTitle, "Acme Tracker")
        XCTAssertEqual(open.prefersBorder, true)
        XCTAssertEqual(open.csp?["connectDomains"], .array([.string("https://api.acme.example")]))
        XCTAssertNotNil(open.html)
        guard case .appResult(let result) = try server("server.app.result.json") else { return XCTFail("app.result") }
        XCTAssertNotNil(result.structuredContent)
        guard case .appCancelled = try server("server.app.cancelled.json") else { return XCTFail("app.cancelled") }
        guard case .appCallResult(let call) = try server("server.app.call_result.json") else { return XCTFail("app.call_result") }
        XCTAssertEqual(call.id, "req-40")
        XCTAssertTrue(call.ok)
        guard case .appCallTool = try client("client.app.call_tool.json") else { return XCTFail("app.call_tool") }
        guard case .appMessage = try client("client.app.message.json") else { return XCTFail("app.message") }
        guard case .appContext = try client("client.app.context.json") else { return XCTFail("app.context") }
        guard case .appReload = try client("client.app.reload.json") else { return XCTFail("app.reload") }
    }

    func testUserTextViaIsOptional() throws {
        func text(_ json: String) throws -> UserText? {
            guard case .userText(let user) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else { return nil }
            return user
        }
        let typed = try XCTUnwrap(try text(#"{"type":"user.text","chat":1,"turn":2,"text":"Hi","ts":"2026-11-03T12:00:00Z"}"#))
        XCTAssertNil(typed.via)
        let sent = try XCTUnwrap(try text(#"{"type":"user.text","chat":1,"turn":2,"text":"Mark it done","via":"Acme Tracker","ts":"2026-11-03T12:00:00Z"}"#))
        XCTAssertEqual(sent.via, "Acme Tracker")
    }

    func testUnknownServerTypeFailsToDecode() {
        let data = Data(#"{"type":"nope","ts":"2026-10-27T12:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ServerMessage.self, from: data))
    }
}
