import Foundation
import XCTest

@testable import Portico

/// v0.15, AN1: the strip's model is a menu of the engine's own models
/// (`models.v1`): `models` from the gateway, `model.set` back, dimmed while
/// a reply runs, plain text for a past session or an older gateway.
@MainActor
final class ModelMenuTests: XCTestCase {

    // MARK: - fixtures

    private static var examplesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PorticoTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol/examples", isDirectory: true)
    }

    private let choices = [
        ModelChoice(value: "default", displayName: "Default (recommended)", description: "Opus for complex work"),
        ModelChoice(value: "opus", displayName: "Opus", description: "Opus for the hardest work"),
        ModelChoice(value: "sonnet", displayName: "Sonnet", description: "Efficient for routine tasks"),
    ]

    private func presentation(
        current: String? = nil, busy: Bool = false, live: Bool = true, hasCapability: Bool = true,
        choices: [ModelChoice]? = nil
    ) -> ModelMenuPresentation {
        ModelMenuPresentation(
            choices: choices ?? self.choices, current: current, busy: busy, live: live, hasCapability: hasCapability)
    }

    private func model(capabilities: [String] = ["sessions", "models.v1"]) -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.15.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["new"], capabilities: capabilities, presentation: "single")))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 2, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T09:00:00Z",
                        ended: "2026-11-01T10:00:00Z"),
            ChatSummary(chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T10:00:00Z"),
        ])))
        model.selected = 3
        model.setConnection(.connected)
        return model
    }

    // MARK: - the wire

    func testTheExampleDecodesWithItsChoicesInOrder() throws {
        let data = try Data(contentsOf: Self.examplesDir.appendingPathComponent("server.models.json"))
        guard case .models(let models) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            return XCTFail("server.models.json is not a models frame")
        }
        XCTAssertEqual(models.chat, 14)
        XCTAssertEqual(models.current, "sonnet")
        XCTAssertEqual(models.choices.map(\.value), ["default", "opus", "sonnet", "haiku"])
        XCTAssertEqual(models.choices.first?.displayName, "Default (recommended)")
        XCTAssertEqual(models.choices.last?.description, "Fastest for quick answers")
    }

    func testCurrentIsOptional() throws {
        let json = #"{"type":"models","chat":1,"choices":[],"ts":"2026-11-01T12:00:00Z"}"#
        guard case .models(let models) = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8)) else {
            return XCTFail("not a models frame")
        }
        XCTAssertNil(models.current, "absent: the default")
    }

    func testTheAppAsksForModels() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("models.v1"))
    }

    // MARK: - the presentation

    func testBusyDimsTheMenuWithTheReason() {
        let busy = presentation(busy: true)
        XCTAssertTrue(busy.menu, "still a menu, only dimmed")
        XCTAssertFalse(busy.enabled)
        XCTAssertEqual(busy.help, "Change the model after this reply")
        let idle = presentation()
        XCTAssertTrue(idle.enabled)
        XCTAssertNil(idle.help)
    }

    func testNoChoicesYetIsOneDimmedLine() {
        XCTAssertEqual(presentation(choices: []).emptyLine, "Models appear once the session starts")
        XCTAssertNil(presentation().emptyLine)
    }

    func testTheCheckIsOnTheCurrentChoice() {
        let byDefault = presentation(current: nil)
        XCTAssertTrue(byDefault.checked("default"))
        XCTAssertFalse(byDefault.checked("sonnet"))
        let sonnet = presentation(current: "sonnet")
        XCTAssertEqual(choices.map(\.value).filter(sonnet.checked), ["sonnet"])
    }

    func testAPastSessionOrAnOlderGatewayIsPlainText() {
        XCTAssertFalse(presentation(live: false).menu, "a past session open read-only")
        XCTAssertFalse(presentation(hasCapability: false).menu, "a gateway without models.v1")
        XCTAssertFalse(presentation(live: false).enabled)
    }

    // MARK: - in the model

    func testModelsFramesAreKeptPerChatAndReplaced() {
        let model = model()
        model.apply(.models(Models(chat: 3, current: "opus", choices: choices)))
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertNil(model.models[3]?.current, "each frame replaces the last")
        XCTAssertEqual(model.models[3]?.choices.count, 3)

        // A new hello (a restarted gateway) clears them: it resends its kept list.
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.15.0", epoch: "e2",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["new"], capabilities: ["sessions", "models.v1"], presentation: "single")))
        XCTAssertNil(model.models[3])
    }

    func testTheStripsMenuFollowsTheGatewayTheSessionAndTheTurn() {
        let model = model()
        model.apply(.models(Models(chat: 3, current: "sonnet", choices: choices)))
        let menu = model.modelMenu(for: 3)
        XCTAssertTrue(menu.menu)
        XCTAssertEqual(menu.current, "sonnet")
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).modelMenu?.menu, true)

        XCTAssertEqual(model.modelMenu(for: 2).menu, false, "the ended session shows its model without a menu")

        // No frame for the chat yet: the menu shows only the dimmed line.
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 3, folder: "/tmp/demo", alias: nil, state: .working, created: "2026-11-01T10:00:00Z"),
            ChatSummary(chat: 4, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T11:00:00Z"),
        ])))
        XCTAssertEqual(model.modelMenu(for: 4).emptyLine, "Models appear once the session starts")
        XCTAssertEqual(model.modelMenu(for: 3).enabled, false, "a reply is running")

        let older = self.model(capabilities: ["sessions"])
        older.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertEqual(older.modelMenu(for: 3).menu, false)
        XCTAssertNil(older.statusStrip(gateway: .running(port: 1)).modelMenu, "plain text")
    }

    func testTheMenuIsReachableBeforeTheFirstReply() {
        // No context.usage yet, so no model name: the segment still shows,
        // naming the current choice.
        let model = model()
        model.apply(.models(Models(chat: 3, current: "sonnet", choices: choices)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Sonnet")
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertEqual(
            model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Default",
            "the trailing parenthetical is trimmed")
    }

    func testASwitchNamesTheChoiceAtOnceUntilTheNextUsage() {
        let model = model()
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        model.apply(.contextUsage(ContextUsage(chat: 3, percent: 10, model: "claude-opus-5-5")))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Claude Opus 5.5")

        model.apply(.models(Models(chat: 3, current: "sonnet", choices: choices)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Sonnet", "at once")

        model.apply(.contextUsage(ContextUsage(chat: 3, percent: 12, model: "claude-sonnet-5-5")))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Claude Sonnet 5.5")

        // Back to the default: "Default (recommended)" reads "Default".
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Default")

        // A frame that repeats the current choice is not a switch.
        model.apply(.contextUsage(ContextUsage(chat: 3, percent: 13, model: "claude-opus-5-5")))
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertEqual(model.statusStrip(gateway: .running(port: 1)).model(at: .full), "Claude Opus 5.5")
    }

    func testShortChoiceName() {
        XCTAssertEqual(ModelMenuPresentation.shortChoiceName("Default (recommended)"), "Default")
        XCTAssertEqual(ModelMenuPresentation.shortChoiceName("Sonnet"), "Sonnet")
        XCTAssertEqual(ModelMenuPresentation.shortChoiceName("(beta)"), "(beta)", "never empty")
    }

    func testTheCompactFitNeverWidensTheChoiceLabel() {
        let model = model()
        model.apply(.models(Models(chat: 3, current: nil, choices: [
            ModelChoice(value: "default", displayName: "Claude Opus 5.5 (recommended)", description: ""),
        ])))
        let strip = model.statusStrip(gateway: .running(port: 1))
        XCTAssertEqual(strip.model(at: .full), "Claude Opus 5.5")
        XCTAssertEqual(strip.model(at: .compact), "Opus 5.5", "the same short-name path as a usage name")
        let metrics = StatusStripPresentation.Metrics(text: { CGFloat($0.count * 7) }, symbol: { $0.size + 2 })
        XCTAssertLessThanOrEqual(
            strip.width(at: .compact, restart: false, update: nil, metrics: metrics),
            strip.width(at: .full, restart: false, update: nil, metrics: metrics))
    }

    func testDisconnectedDimsTheMenu() {
        let model = model()
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        XCTAssertTrue(model.modelMenu(for: 3).enabled)
        model.setConnection(.disconnected)
        let menu = model.modelMenu(for: 3)
        XCTAssertTrue(menu.menu)
        XCTAssertFalse(menu.enabled)
        XCTAssertEqual(menu.help, "Not connected")
        XCTAssertEqual(presentation().help, nil, "connected by default")
    }

    func testTheFitMeasuresTheChevron() {
        let services = ServicesPresentation(
            gateway: ServicesPresentation.gatewayRow(.running(port: 1), connection: .connected), services: [])
        let metrics = StatusStripPresentation.Metrics(text: { CGFloat($0.count) }, symbol: { $0.size })
        let plain = StatusStripPresentation(modelText: "Claude Opus 5.5", services: services, gatewayText: "")
        var menu = plain
        menu.modelMenu = presentation()
        let extra = menu.width(at: .full, restart: false, update: nil, metrics: metrics)
            - plain.width(at: .full, restart: false, update: nil, metrics: metrics)
        XCTAssertEqual(
            extra,
            StatusStripPresentation.Measure.iconGap + StatusStripPresentation.Measure.chevron.size
                + 2 * StatusStripPresentation.Measure.modelMenuPadding)
    }

    // MARK: - model.set

    func testSetModelSendsModelSet() async throws {
        let gateway = FakeGateway()
        try await gateway.start()
        defer { gateway.stop() }
        let client = GatewayClient()
        _ = try await client.connect(url: gateway.url, token: "tok", appVersion: "0.15.0-test")
        let model = AppModel()
        model.outbound = { message in Task { try? await client.send(message) } }

        model.setModel("sonnet", chat: 3)

        let received = await gateway.waitForFrame(type: "model.set", seconds: 5)
        let frame = try XCTUnwrap(received)
        XCTAssertEqual(frame["chat"] as? Int, 3)
        XCTAssertEqual(frame["value"] as? String, "sonnet")
        XCTAssertNotNil(frame["id"] as? String, "a request: errors come back with its id")
        await client.disconnect()
    }

    func testChoosingTheCurrentModelSendsNothing() {
        let model = model()
        var sent: [ClientMessage] = []
        model.outbound = { sent.append($0) }
        model.apply(.models(Models(chat: 3, current: nil, choices: choices)))
        model.setModel("default", chat: 3)
        XCTAssertTrue(sent.isEmpty)
        model.setModel("opus", chat: 3)
        XCTAssertEqual(sent.map(\.type), ["model.set"])
    }

    func testARefusalIsTheChatsStatusLine() {
        let model = model()
        model.apply(.error(ErrorMessage(code: "chat.busy", message: "Change the model after this reply", chat: 3, id: "r1")))
        XCTAssertEqual(model.latestStatusLine(for: 3), "Change the model after this reply")
    }
}
