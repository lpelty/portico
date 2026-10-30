import Foundation
import XCTest

@testable import Portico

/// v0.11 item 66 (frame AG4): the composer's slash list. The pure ranking,
/// footer and keys (`SlashCompletion`), and the model keeping the agent's
/// commands per folder from `chat.commands`.
@MainActor
final class SlashCompletionTests: XCTestCase {

    private let acme: [AgentCommand] = [
        AgentCommand(name: "standup", description: "Draft a standup from today's log", source: "user"),
        AgentCommand(name: "research", description: "Research a question and cite sources", source: "user"),
        AgentCommand(name: "log-session", description: "Write up this session and file it", source: "project"),
        AgentCommand(name: "acme:review", description: "Review a change before it ships", source: "acme-tools"),
        AgentCommand(name: "plan", description: "Turn a request into a step-by-step plan"),
    ]

    private func names(_ c: SlashCompletion?) -> [String] { c?.items.map(\.name) ?? [] }

    // MARK: - opening and closing

    func testOnlyASlashAtTheStartWithANameBeingTypedOpensIt() {
        XCTAssertEqual(SlashCompletion.query(in: "/"), "")
        XCTAssertEqual(SlashCompletion.query(in: "/lo"), "lo")
        XCTAssertNil(SlashCompletion.query(in: ""))
        XCTAssertNil(SlashCompletion.query(in: " /lo"), "the very start only")
        XCTAssertNil(SlashCompletion.query(in: "say /lo"))
        XCTAssertNil(SlashCompletion.query(in: "/log "), "a blank ends the name: the list closes once picked")
        XCTAssertNil(SlashCompletion.query(in: "/log\nmore"))
        XCTAssertNil(SlashCompletion(text: "/zzz", agentCommands: acme), "nothing matches: closed")
    }

    // MARK: - ranking

    func testASlashAloneListsPorticosOwnFirstThenTheAgentsAlphabetically() throws {
        let c = try XCTUnwrap(SlashCompletion(text: "/", agentCommands: acme))
        XCTAssertEqual(c.portico.map(\.name), ["log", "new"])
        XCTAssertEqual(c.agent.map(\.name), ["acme:review", "log-session", "plan", "research", "standup"])
        XCTAssertEqual(c.total, 7)
        XCTAssertEqual(c.portico.first?.description, "Log this session")
    }

    func testNamesMatchBeforeDescriptions() throws {
        // AG4's right frame: "/lo" is /log, then /log-session, then /standup (its description says "log").
        let c = try XCTUnwrap(SlashCompletion(text: "/lo", agentCommands: acme))
        XCTAssertEqual(names(c), ["log", "log-session", "standup"])
        XCTAssertEqual(c.footer, "3 of 7")
    }

    func testPrefixThenContainsThenDescriptionAndAPluginPrefixCountsAsAStart() throws {
        let commands = [
            AgentCommand(name: "preview", description: "Show it"),
            AgentCommand(name: "acme:review", description: "Ship check"),
            AgentCommand(name: "notes", description: "Review the notes"),
            AgentCommand(name: "review", description: "Look"),
        ]
        let c = try XCTUnwrap(SlashCompletion(text: "/REV", agentCommands: commands))
        XCTAssertEqual(c.agent.map(\.name), ["acme:review", "review", "preview", "notes"])
        XCTAssertTrue(c.portico.isEmpty)
    }

    func testTheAgentsLogAndNewAreDroppedForPorticosOwnAndRepeatsGo() throws {
        let commands = [
            AgentCommand(name: "log", description: "theirs"),
            AgentCommand(name: "new", description: "theirs"),
            AgentCommand(name: "plan", description: "one"),
            AgentCommand(name: "plan", description: "two"),
        ]
        let c = try XCTUnwrap(SlashCompletion(text: "/", agentCommands: commands))
        XCTAssertEqual(names(c), ["log", "new", "plan"])
        XCTAssertEqual(c.agent.first?.description, "one")
        XCTAssertEqual(c.total, 3)
    }

    func testTheFooterSaysHowManyMoreWhenTheListScrolls() throws {
        let many = (1...135).map { AgentCommand(name: String(format: "cmd%03d", $0), description: "") }
        let c = try XCTUnwrap(SlashCompletion(text: "/", agentCommands: many))
        XCTAssertEqual(c.footer, "↓ 130 more — scroll, or keep typing")
        let filtered = try XCTUnwrap(SlashCompletion(text: "/cmd00", agentCommands: many))
        XCTAssertEqual(filtered.footer, "9 of 137")
    }

    // MARK: - keys

    func testArrowsStopAtTheEndsAndEnterOrTabPick() throws {
        let c = try XCTUnwrap(SlashCompletion(text: "/lo", agentCommands: acme))
        XCTAssertEqual(c.handle(.up, selection: 0), .select(0))
        XCTAssertEqual(c.handle(.down, selection: 0), .select(1))
        XCTAssertEqual(c.handle(.down, selection: 2), .select(2))
        XCTAssertEqual(c.handle(.escape, selection: 1), .close)

        let logSession = c.items[1]
        XCTAssertEqual(logSession.completion, "/log-session ")
        XCTAssertEqual(c.handle(.tab, selection: 1), .pick(logSession, send: false))
        XCTAssertEqual(c.handle(.enter, selection: 1), .pick(logSession, send: false), "the agent's: fill, then type")
        // Portico's own: Enter does what Enter on a typed /log always did.
        XCTAssertEqual(c.handle(.enter, selection: 0), .pick(c.items[0], send: true))
        XCTAssertEqual(c.handle(.tab, selection: 0), .pick(c.items[0], send: false))
        // A selection past the end (the list shrank) picks the last row.
        XCTAssertEqual(c.handle(.tab, selection: 9), .pick(c.items[2], send: false))
    }

    func testEscKeepsTheListClosedUntilTheSlashNameIsGone() throws {
        var state = SlashListState()
        let c = try XCTUnwrap(state.completion(text: "/lo", agentCommands: acme))
        XCTAssertNil(state.apply(c.handle(.down, selection: state.selection)))
        XCTAssertEqual(state.selection, 1)
        state.queryChanged(to: "log")
        XCTAssertEqual(state.selection, 0, "a new query starts at the top")

        XCTAssertNil(state.apply(.close))
        XCTAssertNil(state.completion(text: "/log", agentCommands: acme), "typing on after Esc keeps it closed")
        state.queryChanged(to: nil)
        XCTAssertNotNil(state.completion(text: "/", agentCommands: acme), "cleared, a new / opens it again")

        let picked = state.apply(c.handle(.enter, selection: 0))
        XCTAssertEqual(picked?.item.name, "log")
        XCTAssertEqual(picked?.send, true)
    }

    // MARK: - the model

    private func model() -> AppModel {
        let model = AppModel()
        model.outbound = { _ in }
        return model
    }

    func testChatCommandsAreKeptPerFolderAndTheLatestStandsInForAnUnknownFolder() {
        let model = model()
        XCTAssertEqual(model.agentCommands(folder: "/tmp/demo"), [])
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-30T12:00:00Z"),
        ])))
        model.apply(.chatCommands(ChatCommands(folder: "/tmp/demo", commands: acme)))
        model.apply(.chatCommands(ChatCommands(folder: "/tmp/other", commands: [acme[0]], chat: 2)))
        XCTAssertEqual(model.agentCommands(folder: "/tmp/demo"), acme)
        XCTAssertEqual(model.agentCommands(chat: 1), acme, "the chat's own folder")
        XCTAssertEqual(model.agentCommands(folder: "/tmp/demo/"), acme, "a trailing slash is the same folder")
        XCTAssertEqual(model.agentCommands(folder: "/elsewhere"), [acme[0]], "no list there yet: the last one heard")
        XCTAssertEqual(model.agentCommands(folder: nil), [acme[0]])
    }

    func testTheExampleFrameDecodes() throws {
        let json = #"{"type":"chat.commands","ts":"2026-10-30T12:00:00Z","folder":"/x","commands":[{"name":"plan"},{"name":"acme:review","description":"Review","source":"acme-tools"}]}"#
        let message = try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        guard case .chatCommands(let frame) = message else { return XCTFail("expected chat.commands") }
        XCTAssertNil(frame.chat)
        XCTAssertEqual(frame.commands, [
            AgentCommand(name: "plan"),
            AgentCommand(name: "acme:review", description: "Review", source: "acme-tools"),
        ])
    }
}
