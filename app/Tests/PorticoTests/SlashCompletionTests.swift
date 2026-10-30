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

    // MARK: - the composer's key path

    /// Both composers (`InputBar`, `StartView`) route an editor key press
    /// through `SlashCompletion.Key(_:modifiers:composing:)` while the list
    /// is open: `nil` leaves the press to the text editor.
    func testTheListTakesItsKeysFromTheEditorUnlessAModifierOrAnInputMethodHasThem() {
        typealias Key = SlashCompletion.Key
        XCTAssertEqual(Key(.upArrow, modifiers: [], composing: false), .up)
        XCTAssertEqual(Key(.downArrow, modifiers: [], composing: false), .down)
        // macOS marks the arrows as function and keypad keys; Caps Lock changes nothing.
        XCTAssertEqual(Key(.downArrow, modifiers: [.function, .numericPad], composing: false), .down)
        XCTAssertEqual(Key(.upArrow, modifiers: [.function, .numericPad, .capsLock], composing: false), .up)
        XCTAssertEqual(Key(.return, modifiers: [], composing: false), .enter)
        XCTAssertEqual(Key(.tab, modifiers: [], composing: false), .tab)
        XCTAssertEqual(Key(.escape, modifiers: [], composing: false), .escape)

        XCTAssertNil(Key(.return, modifiers: .shift, composing: false), "Shift+Enter adds a line")
        XCTAssertNil(Key(.tab, modifiers: .shift, composing: false))
        XCTAssertNil(Key(.downArrow, modifiers: [.command, .function, .numericPad], composing: false), "⌘↓ goes to the end of the text")
        XCTAssertNil(Key(.upArrow, modifiers: [.option, .function, .numericPad], composing: false))
        XCTAssertNil(Key(.return, modifiers: [], composing: true), "Return commits the input method's text")
        XCTAssertNil(Key(.downArrow, modifiers: [.function, .numericPad], composing: true), "the candidate window has the arrows")
        XCTAssertNil(Key("a", modifiers: [], composing: false))
    }

    /// A walk through a long list as the composer drives it: the keys move
    /// the selection through `SlashListState`, which the list scrolls to.
    func testALongListWalksDownAndBackAndPicksWhatIsSelected() throws {
        let many = (1...12).map { AgentCommand(name: String(format: "cmd%02d", $0), description: "") }
        var state = SlashListState()
        let c = try XCTUnwrap(state.completion(text: "/", agentCommands: many))
        XCTAssertGreaterThan(c.items.count, SlashCompletion.visibleRows, "it scrolls")
        for _ in 0..<20 {
            XCTAssertNil(state.apply(c.handle(try XCTUnwrap(SlashCompletion.Key(.downArrow, modifiers: [.function], composing: false)), selection: state.selection)))
        }
        XCTAssertEqual(state.selection, c.items.count - 1, "stops at the last row")
        XCTAssertNil(state.apply(c.handle(.up, selection: state.selection)))
        let picked = try XCTUnwrap(state.apply(c.handle(.tab, selection: state.selection)))
        XCTAssertEqual(picked.item, c.items[c.items.count - 2])
        XCTAssertFalse(picked.send)
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
