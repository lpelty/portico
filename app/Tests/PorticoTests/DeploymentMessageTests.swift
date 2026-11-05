import Foundation
import XCTest

@testable import Portico

/// v0.22 S3: a message from the deployment, docked above the open chat's
/// message box (spec §4).
@MainActor
final class DeploymentMessageTests: XCTestCase {

    private func isolatedSettings() -> Settings {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Settings(defaults: defaults)
    }

    private func message(_ id: String, text: String = "Hello", title: String? = nil, notify: Bool? = nil, space: String? = nil)
        -> DeploymentMessage
    {
        DeploymentMessage(id: id, text: text, title: title, notify: notify, space: space, ts: "2026-11-05T12:00:00Z")
    }

    private func summary(_ chat: Int, state: ChatStateWord = .idle) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", alias: nil, state: state, created: "2026-10-27T12:00:00Z")
    }

    private func model() -> (AppModel, AppModelTests.Sent) {
        let model = AppModel(settings: isolatedSettings())
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.22.0", epoch: "e1",
            brand: Brand(name: "Acme", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: ["spaces.v1"])))
        model.apply(.chatList(ChatList(chats: [summary(1)])))
        model.open(chat: 1)
        return (model, sent)
    }

    // MARK: - the wire

    func test_it_decodes_as_the_spec_names_it() throws {
        let json = #"""
            {"type":"deployment.message","id":"m-1","text":"Your **brief** is ready","title":"Morning",
             "notify":true,"space":"brief","ts":"2026-11-05T12:00:00Z"}
            """#
        let decoded = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        guard case .deploymentMessage(let m) = decoded else { return XCTFail("got \(decoded)") }
        XCTAssertEqual(m, message("m-1", text: "Your **brief** is ready", title: "Morning", notify: true, space: "brief"))
        XCTAssertEqual(decoded.envelope.id, "m-1")
        XCTAssertNil(decoded.envelope.chat, "not chat-scoped")

        let bare = try JSONDecoder().decode(ServerMessage.self, from: Data(#"""
            {"type":"deployment.message","id":"m-2","text":"Done","ts":"2026-11-05T12:00:00Z"}
            """#.utf8))
        guard case .deploymentMessage(let b) = bare else { return XCTFail("got \(bare)") }
        XCTAssertNil(b.title)
        XCTAssertNil(b.notify)
        XCTAssertNil(b.space)
    }

    /// The gateway branch's two new examples, inlined (protocol/ is reconciled at merge).
    func test_the_gateway_examples_round_trip() throws {
        let server = #"""
            {"id":"msg-20261105-1","notify":true,"space":"meeting-prep","text":"Today's standup is at **10:30**.",
             "title":"Standup moved","ts":"2026-10-27T12:00:00Z","type":"deployment.message"}
            """#
        let client = #"""
            {"action":"mark-done","id":"meeting-prep","item":"task-3","ts":"2026-10-27T12:00:00Z","type":"space.act"}
            """#
        for (json, isServer) in [(server, true), (client, false)] {
            let data = Data(json.utf8)
            let again: Data = isServer
                ? try JSONEncoder().encode(try JSONDecoder().decode(ServerMessage.self, from: data))
                : try JSONEncoder().encode(try JSONDecoder().decode(ClientMessage.self, from: data))
            let a = try JSONSerialization.jsonObject(with: data) as? NSDictionary
            let b = try JSONSerialization.jsonObject(with: again) as? NSDictionary
            XCTAssertEqual(a, b, json)
        }
    }

    func test_the_app_names_the_capability() {
        XCTAssertTrue(HelloClient.appCapabilities.contains("messages.deployment.v1"))
        XCTAssertEqual(DeploymentMessage.capability, "messages.deployment.v1")
    }

    // MARK: - the queue

    func test_held_while_streaming_then_docked() {
        var queue = DeploymentMessageQueue()
        queue.receive(message("a"), streaming: true)
        XCTAssertEqual(queue.visible(streaming: true).shown, [], "held while a reply streams")
        XCTAssertEqual(queue.visible(streaming: false).shown.map(\.id), ["a"], "shown once it stops")
        queue.release()
        XCTAssertEqual(queue.visible(streaming: true).shown.map(\.id), ["a"], "once docked, a new reply does not hide it")
    }

    func test_three_shown_newest_at_the_bottom_with_n_more() {
        var queue = DeploymentMessageQueue()
        for id in ["a", "b", "c", "d", "e"] { queue.receive(message(id), streaming: false) }
        let visible = queue.visible(streaming: false)
        XCTAssertEqual(visible.shown.map(\.id), ["c", "d", "e"])
        XCTAssertEqual(visible.more, 2)
        XCTAssertEqual(DeploymentMessagePresentation.moreText(2), "2 more")
        XCTAssertNil(DeploymentMessagePresentation.moreText(0))
        queue.dismiss("e")
        XCTAssertEqual(queue.visible(streaming: false).shown.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(queue.visible(streaming: false).more, 1)
    }

    func test_the_same_id_twice_is_one_card() {
        var queue = DeploymentMessageQueue()
        queue.receive(message("a"), streaming: false)
        queue.receive(message("a"), streaming: true)
        XCTAssertEqual(queue.visible(streaming: false).shown.map(\.id), ["a"])
    }

    func test_dismissed_is_gone() {
        var queue = DeploymentMessageQueue()
        queue.receive(message("a"), streaming: true)
        queue.dismiss("a")
        XCTAssertTrue(queue.visible(streaming: false).shown.isEmpty)
        queue.receive(message("b"), streaming: false)
        queue.dismiss("b")
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - the model

    func test_the_model_holds_while_the_open_chat_works() {
        let (model, _) = model()
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 1)))
        model.apply(.deploymentMessage(message("a")))
        XCTAssertTrue(model.dockedDeploymentMessages.shown.isEmpty, "held while the reply streams")
        model.apply(.chatState(ChatState(chat: 1, state: .idle, seq: 2)))
        XCTAssertEqual(model.dockedDeploymentMessages.shown.map(\.id), ["a"])
        model.apply(.chatState(ChatState(chat: 1, state: .working, seq: 3)))
        XCTAssertEqual(model.dockedDeploymentMessages.shown.map(\.id), ["a"], "docked stays docked")
    }

    func test_not_sent_to_the_agent_and_not_in_the_transcript() {
        let (model, sent) = model()
        let before = sent.frames.count
        let transcript = model.transcripts[1] ?? []
        model.apply(.deploymentMessage(message("a")))
        XCTAssertEqual(sent.frames.count, before)
        XCTAssertEqual((model.transcripts[1] ?? []).count, transcript.count)
        model.dismissDeploymentMessage("a")
        XCTAssertEqual(sent.frames.count, before, "a dismiss tells nobody")
        XCTAssertTrue(model.dockedDeploymentMessages.shown.isEmpty)
    }

    func test_open_goes_to_the_space_and_dismisses() {
        let (model, _) = model()
        model.apply(.spacesList(SpacesList(spaces: [
            SpaceInfo(id: "brief", title: "Brief", icon: "doc", order: nil, location: "/tmp/brief.md", media: "markdown",
                      updated: "2026-11-05T12:00:00Z"),
        ])))
        model.apply(.deploymentMessage(message("a", space: "brief")))
        model.openDeploymentMessage("a")
        XCTAssertEqual(model.openSpace, "brief")
        XCTAssertTrue(model.dockedDeploymentMessages.shown.isEmpty)
    }

    func test_notify_posts_a_system_notification() {
        let (model, _) = model()
        let notifier = SpaceActionsTests.FakeNotifier()
        model.spaceNotifier = notifier
        model.apply(.deploymentMessage(message("a", text: "Plain")))
        XCTAssertTrue(notifier.messages.isEmpty)
        model.apply(.deploymentMessage(message("b", text: "Your brief is ready", title: "Morning", notify: true)))
        XCTAssertEqual(notifier.messages.count, 1)
        XCTAssertEqual(notifier.messages.first?.id, "b")
        XCTAssertEqual(notifier.messages.first?.title, "Morning")
        XCTAssertEqual(notifier.messages.first?.body, "Your brief is ready")
        model.apply(.deploymentMessage(message("c", text: "Untitled", notify: true)))
        XCTAssertEqual(notifier.messages.last?.title, "Acme", "no title: the brand's name")
    }
}
