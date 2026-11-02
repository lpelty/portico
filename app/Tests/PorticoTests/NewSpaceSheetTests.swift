import Foundation
import XCTest

@testable import Portico

/// v0.16 Task 8 (AO2): New space… opens a small dialog; Create sends one
/// ordinary message into Main.
@MainActor
final class NewSpaceSheetTests: XCTestCase {

    private final class Sent { var frames: [ClientMessage] = [] }

    private static let created = "2026-11-02T12:00:00Z"

    private static func main(_ chat: Int = 3, state: ChatStateWord = .idle) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: state, created: created)
    }

    private static func thread(_ chat: Int, slot: Int) -> ChatSummary {
        var summary = ChatSummary(chat: chat, folder: "/tmp/acme", alias: nil, state: .idle, created: created)
        summary.parent = 3
        summary.thread = ThreadInfo(
            label: "Thread \(slot)", slot: slot, parent: 3, brief: "Review the pricing page on its own.",
            files: [], openedAt: created)
        return summary
    }

    private func model(chats: [ChatSummary], queue: Bool = false) -> (AppModel, Sent) {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Settings(defaults: defaults))
        let sent = Sent()
        model.outbound = { sent.frames.append($0) }
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.16.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: ["log"],
            capabilities: ["sessions", "threads.v1", SpacesList.capability] + (queue ? [ChatQueue.capability] : []), presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: chats)))
        return (model, sent)
    }

    // MARK: - the draft

    func test_create_needs_both_fields() {
        XCTAssertFalse(NewSpaceDraft(name: "Acme launch", prompt: "  ").canCreate)
        XCTAssertFalse(NewSpaceDraft(name: " \n", prompt: "Track it").canCreate)
        XCTAssertFalse(NewSpaceDraft(name: "", prompt: "").canCreate)
        XCTAssertTrue(NewSpaceDraft(name: "Acme launch", prompt: "Track the launch checklist").canCreate)
    }

    func test_message_is_the_name_then_the_prompt_each_trimmed() {
        let draft = NewSpaceDraft(name: " Acme launch ", prompt: "Track the launch checklist\n")
        XCTAssertEqual(draft.message, "New space: Acme launch\n\nTrack the launch checklist")
    }

    // MARK: - opening

    func test_new_space_opens_the_sheet_and_leaves_every_draft_alone() {
        let (model, _) = model(chats: [Self.main(3)])
        model.setDraft("half a thought", for: 3)
        model.startDraft = "start words"
        model.beginNewSpace()
        XCTAssertTrue(model.newSpaceShown)
        XCTAssertEqual(model.draft(for: 3), "half a thought")
        XCTAssertEqual(model.startDraft, "start words")
        XCTAssertEqual(model.composerFocusRequests, 0)
    }

    // MARK: - Create

    func test_create_from_a_thread_selects_main_and_sends_the_message_there() {
        let (model, sent) = model(chats: [Self.main(3), Self.thread(5, slot: 1)])
        model.open(chat: 5)
        model.openDocumentView()
        model.setDraft("typed in Main", for: 3)
        model.beginNewSpace()
        model.createSpace(NewSpaceDraft(name: " Acme launch ", prompt: "Track the launch checklist\n"))

        XCTAssertFalse(model.newSpaceShown)
        XCTAssertEqual(model.selected, 3, "Main")
        XCTAssertFalse(model.documentMode)
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send, got \(sent.frames)") }
        XCTAssertEqual(message.chat, 3)
        XCTAssertEqual(message.text, "New space: Acme launch\n\nTrack the launch checklist")
        XCTAssertEqual(model.draft(for: 3), "typed in Main", "Main's draft is untouched")
    }

    func test_create_on_the_welcome_continuing_main_shows_main_with_the_message() {
        let (model, sent) = model(chats: [Self.main(3)])
        XCTAssertEqual(model.mainScreen, .continuing(3))
        model.createSpace(NewSpaceDraft(name: "Acme", prompt: "Track it"))
        XCTAssertEqual(model.selected, 3)
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.text, "New space: Acme\n\nTrack it")
    }

    func test_create_with_nothing_started_starts_the_first_session_with_the_message() throws {
        let (model, sent) = model(chats: [])
        model.chosenStartFolder = URL(fileURLWithPath: "/tmp")
        model.beginNewSpace()
        model.createSpace(NewSpaceDraft(name: "Acme", prompt: "Track it"))
        XCTAssertFalse(model.newSpaceShown)
        guard case .chatNew(let new)? = sent.frames.last else { return XCTFail("expected chat.new, got \(sent.frames)") }
        model.apply(.chatState(ChatState(chat: 7, state: .idle, id: new.id, seq: 1)))
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.chat, 7)
        XCTAssertEqual(message.text, "New space: Acme\n\nTrack it")
    }

    func test_create_with_a_blank_field_does_nothing() {
        let (model, sent) = model(chats: [Self.main(3)])
        model.beginNewSpace()
        let before = sent.frames.count
        model.createSpace(NewSpaceDraft(name: "Acme", prompt: "  "))
        XCTAssertTrue(model.newSpaceShown)
        XCTAssertEqual(sent.frames.count, before)
    }

    // MARK: - blocked states (fix round 1)

    func test_no_folder_and_no_main_is_blocked() {
        let (model, sent) = model(chats: [])
        XCTAssertEqual(model.newSpaceBlockedReason(), "Pick a folder on the start screen first.")
        model.beginNewSpace()
        model.createSpace(NewSpaceDraft(name: "Acme", prompt: "Track it"))
        XCTAssertTrue(model.newSpaceShown, "the sheet keeps its words")
        XCTAssertTrue(sent.frames.isEmpty)
        model.chosenStartFolder = URL(fileURLWithPath: "/tmp")
        XCTAssertNil(model.newSpaceBlockedReason())
    }

    func test_a_start_in_flight_is_blocked() {
        let (model, _) = model(chats: [])
        model.chosenStartFolder = URL(fileURLWithPath: "/tmp")
        model.startChat(text: "hello")
        XCTAssertEqual(model.newSpaceBlockedReason(), "Starting your first session…")
    }

    func test_a_send_in_flight_on_main_is_blocked() {
        let (model, _) = model(chats: [Self.main(3)])
        XCTAssertNil(model.newSpaceBlockedReason())
        model.sendMessage(chat: 3, text: "hello")
        XCTAssertTrue(model.isSending(chat: 3))
        XCTAssertEqual(model.newSpaceBlockedReason(), "Main is still sending your last message.")
    }

    func test_a_session_step_running_on_main_is_blocked() {
        let (model, _) = model(chats: [Self.main(3)])
        model.logSession(chat: 3)
        XCTAssertTrue(model.isSessionCommandPending(chat: 3))
        XCTAssertEqual(model.newSpaceBlockedReason(), "Main is finishing a session step.")
    }

    func test_main_busy_without_queue_is_blocked_but_with_queue_sends() {
        let (old, _) = model(chats: [Self.main(3, state: .working)])
        XCTAssertEqual(old.newSpaceBlockedReason(), "Main is busy; try again when it finishes.")

        let (model, sent) = model(chats: [Self.main(3, state: .working)], queue: true)
        XCTAssertNil(model.newSpaceBlockedReason())
        model.createSpace(NewSpaceDraft(name: "Acme", prompt: "Track it"))
        guard case .messageSend(let message)? = sent.frames.last else { return XCTFail("expected message.send") }
        XCTAssertEqual(message.text, "New space: Acme\n\nTrack it")
    }

    func test_create_is_disabled_while_blocked() {
        let (model, _) = model(chats: [Self.main(3, state: .working)])
        let draft = NewSpaceDraft(name: "Acme", prompt: "Track it")
        XCTAssertFalse(NewSpaceSheet.createEnabled(draft, blockedReason: model.newSpaceBlockedReason()))
        XCTAssertTrue(NewSpaceSheet.createEnabled(draft, blockedReason: nil))
        XCTAssertFalse(NewSpaceSheet.createEnabled(NewSpaceDraft(), blockedReason: nil))
    }
}
