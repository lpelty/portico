import Foundation
import XCTest

@testable import Portico

/// v0.26.7 (PORT-75): `/model` was in the command list and did nothing on
/// Enter. The app answers it: the strip's model menu opens, `/model <name>`
/// switches, and where neither can happen one line says why. Nothing is
/// sent to the agent as a message.
@MainActor
final class ModelCommandTests: XCTestCase {
    private final class Sent {
        var frames: [ClientMessage] = []
    }

    private let choices = [
        ModelChoice(value: "default", displayName: "Default (recommended)", description: "", resolvedModel: "claude-fable-5-1"),
        ModelChoice(value: "opus", displayName: "Opus", description: "", resolvedModel: "claude-opus-5"),
        ModelChoice(value: "fable", displayName: "Fable 5.1", description: "", resolvedModel: "claude-fable-5-1"),
        ModelChoice(value: "fable-1m", displayName: "Fable 5.1 (1M context)", description: "", resolvedModel: "claude-fable-5-1"),
        ModelChoice(value: "sonnet", displayName: "Sonnet", description: ""),
    ]

    private func model(capabilities: [String] = ["sessions", "models.v1"], list: Bool = true) -> (AppModel, Sent) {
        let model = AppModel()
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.26.7", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: ["new"], capabilities: capabilities, presentation: "single")))
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-11-01T10:00:00Z")
        ])))
        model.selected = 3
        model.setConnection(.connected)
        if list { model.apply(.models(Models(chat: 3, current: "opus", choices: choices))) }
        sent.frames = []
        return (model, sent)
    }

    private func notices(_ model: AppModel) -> [String] {
        (model.transcripts[3] ?? []).compactMap { item in
            if case .notice(_, let text) = item { return text }
            return nil
        }
    }

    // MARK: - reading the command

    func testOnlyTheWordModelIsTheCommand() {
        XCTAssertEqual(ModelCommand.parse("/model"), .open)
        XCTAssertEqual(ModelCommand.parse("  /model \n"), .open)
        XCTAssertEqual(ModelCommand.parse("/model sonnet"), .named("sonnet"))
        XCTAssertEqual(ModelCommand.parse("/model  Fable 5.1 "), .named("Fable 5.1"))
        XCTAssertNil(ModelCommand.parse("/models"))
        XCTAssertNil(ModelCommand.parse("/modelx sonnet"))
        XCTAssertNil(ModelCommand.parse("what does /model do"))
        XCTAssertNil(ModelCommand.parse("model"))
    }

    func testANameFindsItsChoice() {
        func value(_ name: String) -> String? { ModelCommand.choice(named: name, in: choices)?.value }
        XCTAssertEqual(value("sonnet"), "sonnet")
        XCTAssertEqual(value("SONNET"), "sonnet")
        XCTAssertEqual(value("Fable 5.1"), "fable", "the exact name, not the 1M one that contains it")
        XCTAssertEqual(value("fable 5.1 (1m context)"), "fable-1m")
        XCTAssertEqual(value("default"), "default")
        XCTAssertEqual(value("claude-opus-5"), "opus", "the model id it resolves to")
        XCTAssertEqual(value("claude-fable-5-1"), "fable", "a named choice before Default")
        XCTAssertEqual(value("son"), "sonnet", "the only one that contains it")
        XCTAssertEqual(value("1m"), "fable-1m")
        XCTAssertNil(value("fable 5"), "two contain it")
        XCTAssertNil(value("gpt"))
    }

    // MARK: - Enter on `/model`

    func testModelAloneAsksTheStripToOpenItsMenuAndSendsNothing() {
        let (model, sent) = model()
        model.setDraft("/model ", for: 3)
        model.sendMessage(chat: 3, text: model.draft(for: 3))
        XCTAssertEqual(model.modelMenuRequests, 1)
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(model.draft(for: 3), "")
        XCTAssertEqual(notices(model), [])
    }

    func testModelAndANameSwitchesToIt() {
        let (model, sent) = model()
        model.sendMessage(chat: 3, text: "/model sonnet")
        guard case .modelSet(let set) = sent.frames.first, sent.frames.count == 1 else { return XCTFail("one model.set") }
        XCTAssertEqual(set.chat, 3)
        XCTAssertEqual(set.value, "sonnet")
        XCTAssertEqual(model.modelMenuRequests, 0)
    }

    func testTheModelItIsAlreadyOnSaysSoAndSendsNothing() {
        let (model, sent) = model()
        model.sendMessage(chat: 3, text: "/model opus")
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(notices(model), ["Already on Opus."])
    }

    func testANameThatMatchesNothingSaysSoAndListsTheModels() {
        let (model, sent) = model()
        model.sendMessage(chat: 3, text: "/model gpt")
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(notices(model), [
            "No model matches \u{201C}gpt\u{201D}. Models: Default, Opus (current), Fable 5.1, Fable 5.1 (1M context), Sonnet. Type /model and a name to switch."
        ])
    }

    func testWhereTheModelCannotBeChangedOneLineSaysSo() {
        // A gateway without `models.v1`, and a session with no list yet.
        for (model, sent) in [model(capabilities: ["sessions"]), model(list: false)] {
            XCTAssertTrue(model.runModelCommand("/model", chat: 3))
            XCTAssertTrue(model.runModelCommand("/model sonnet", chat: 3))
            XCTAssertEqual(sent.frames, [])
            XCTAssertEqual(model.modelMenuRequests, 0)
            XCTAssertEqual(notices(model), [ModelCommand.unavailable, ModelCommand.unavailable])
        }
    }

    func testNotConnectedSaysSo() {
        let (model, sent) = model()
        model.setConnection(.disconnected)
        XCTAssertTrue(model.runModelCommand("/model sonnet", chat: 3))
        XCTAssertEqual(sent.frames, [])
        XCTAssertEqual(notices(model), [ModelCommand.disconnected])
    }

    func testANarrowStripListsTheModelsInstead() {
        let (model, _) = model()
        model.listModels(chat: 3)
        XCTAssertEqual(notices(model), ["Models: Default, Opus (current), Fable 5.1, Fable 5.1 (1M context), Sonnet. Type /model and a name to switch."])
    }

    func testAnythingElseIsNotTheCommand() {
        let (model, sent) = model()
        XCTAssertFalse(model.runModelCommand("/models", chat: 3))
        model.sendMessage(chat: 3, text: "/modelx")
        guard case .messageSend(let message) = sent.frames.first else { return XCTFail("message.send") }
        XCTAssertEqual(message.text, "/modelx")
    }
}
