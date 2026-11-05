import AppKit
import XCTest
@testable import Portico

/// v0.20 §4: the viewer agent while the person edits the shown file.
@MainActor
final class EditorAgentTests: XCTestCase {
    private var folder: URL!
    private var defaultsName = ""

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("edit-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaultsName = "edit-agent.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    private func rig(_ text: String, editing: Bool) throws -> (ViewerAgent, EditSession?, URL) {
        let file = folder.appendingPathComponent("plan.txt")
        try Data(text.utf8).write(to: file)
        let model = AppModel(settings: Settings(defaults: UserDefaults(suiteName: defaultsName)!))
        model.outbound = { _ in }
        model.selected = 1
        let artifact = Artifact(id: "a-1", kind: .file, location: file.path, media: .text, title: "plan.txt",
                                source: .tool, open: true)
        model.show(artifact, in: 1)
        let agent = ViewerAgent(model: model)
        let registry = EditSessions()
        agent.editSessions = registry
        var session: EditSession?
        if editing {
            let edit = ViewerEdit(registry: registry)
            edit.chat = 1
            edit.turnOn(artifact)
            session = edit.session
            addTeardownBlock { _ = edit }
        }
        addTeardownBlock { _ = model }
        return (agent, session, file)
    }

    private func act(_ action: ViewerAct.Action, _ args: [String: JSONValue] = [:]) -> ViewerAct {
        ViewerAct(id: "act-\(UUID().uuidString.prefix(6))", chat: 1, action: action, args: args)
    }

    func testLookWhileEditingReturnsTheEditorsTextAndSaysSo() async throws {
        let (agent, session, file) = try rig("first line\nsecond line\n", editing: true)
        let edit = try XCTUnwrap(session)
        // What the editor shows now, typed but not yet saved.
        edit.currentText = { "first line\nsecond line\nthird, typed\n" }
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok, look.text)
        XCTAssertEqual(look.text, "Open: plan.txt — \(file.path)\nThe person is editing this file.\n\nfirst line\nsecond line\nthird, typed\n")
    }

    func testClickAndTypeAreRefusedWhileEditing() async throws {
        let (agent, _, file) = try rig("text\n", editing: true)
        let click = await agent.perform(act(.click, ["target": .string("e1")]))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.text, "The person is editing this file; ask them, or wait.")
        let typed = await agent.perform(act(.type, ["target": .string("e1"), "text": .string("x")]))
        XCTAssertFalse(typed.ok)
        XCTAssertEqual(typed.text, "The person is editing this file; ask them, or wait.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "text\n", "nothing reached the file")
    }

    func testWithEditOffTodaysBehaviourIsUnchanged() async throws {
        let (agent, _, _) = try rig("text\n", editing: false)
        let click = await agent.perform(act(.click, ["target": .string("e1")]))
        XCTAssertEqual(click.text, "This is a text file; it can be looked at, not used.")
        let look = await agent.perform(act(.look))
        XCTAssertTrue(look.ok)
        XCTAssertFalse(look.text.contains("The person is editing this file."))
    }

    func testASessionNoViewerShowsDoesNotCount() async throws {
        let (agent, session, _) = try rig("text\n", editing: true)
        session?.attached = false  // e.g. its viewer moved on, the save still pending
        let click = await agent.perform(act(.click, ["target": .string("e1")]))
        XCTAssertEqual(click.text, "This is a text file; it can be looked at, not used.")
    }
}
