import Foundation
import XCTest

@testable import Portico

/// v0.10 decision 6: the newest artifact the agent made, or the person
/// picked, wins over the one remembered at the last quit, whatever order
/// the held restore, the history replay and the live artifact arrive in.
///
/// The report: launch on the welcome with "a2" (Session 3) remembered,
/// send from the welcome, the agent writes "new"; the viewer kept "a2".
/// Model-only.
@MainActor
final class ViewerNewestWinsTests: XCTestCase {

    // MARK: - helpers

    private var defaults: UserDefaults!

    /// A launch with "a2" in Session 3 remembered at the last quit.
    private func launch() throws -> AppModel {
        let suite = "portico-v010-viewer-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in defaults?.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        settings.viewerAtQuit = SavedViewer(chat: 3, artifact: "a2")
        let model = AppModel(settings: settings)
        model.outbound = { _ in }
        model.relistDelay = .zero
        model.setConnection(.connected)
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.10.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [],
            commands: [], capabilities: ["files", "sessions"], presentation: "single", canLog: true)))
        model.apply(.chatList(ChatList(chats: [ChatSummary(
            chat: 3, folder: "/tmp/demo", alias: nil, state: .idle, created: "2026-10-29T09:14:00Z",
            ended: nil, unlogged: nil, lastReply: nil)])))
        XCTAssertEqual(model.heldViewer, 3, "the welcome holds the restore")
        return model
    }

    private func artifact(_ id: String, open: Bool = false, seq: Int? = nil) -> ServerMessage {
        .artifactCreated(ArtifactCreated(chat: 3, artifact: Artifact(
            id: id, kind: .file, location: "/tmp/demo/\(id).html", media: .html, title: "\(id).html",
            source: .tool, open: open), seq: seq))
    }

    private func history(_ events: [ServerMessage]) -> ServerMessage {
        .chatHistory(ChatHistory(chat: 3, events: events, truncated: false))
    }

    private func send(_ model: AppModel) {
        model.continueSession(chat: 3, text: "make the login page")
    }

    private func assertNewestShown(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.current[3]?.id, "new", "the artifact the agent just made", file: file, line: line)
        XCTAssertTrue(model.isViewerShown(for: 3), file: file, line: line)
    }

    // MARK: - the orders

    func testHistoryFirstThenSendThenTheNewArtifact() throws {
        let model = try launch()
        model.apply(history([artifact("a1"), artifact("a2")]))
        model.apply(.chatLive(ChatLive(chat: 3)))
        send(model)
        XCTAssertEqual(model.current[3]?.id, "a2", "restored as the conversation shows")
        model.apply(artifact("new", open: true, seq: 9))
        assertNewestShown(model)
    }

    func testSendBeforeTheHistoryThenTheNewArtifact() throws {
        let model = try launch()
        send(model)
        model.apply(history([artifact("a1"), artifact("a2")]))
        XCTAssertEqual(model.current[3]?.id, "a2")
        model.apply(artifact("new", open: true, seq: 9))
        assertNewestShown(model)
    }

    /// The failing order: the live artifact comes before the history reply
    /// (a ring replay that carries it), and the remembered one, stored from
    /// an earlier launch, is re-listed after the replay.
    func testTheNewArtifactBeforeARingReplayAndTheStoredRememberedOne() throws {
        let model = try launch()
        send(model)
        model.apply(artifact("new", open: true, seq: 9))
        model.apply(history([artifact("new", open: true, seq: 9)]))
        model.apply(artifact("a1"))
        model.apply(artifact("a2"))
        assertNewestShown(model)
    }

    func testTheNewArtifactBeforeATranscriptReplay() throws {
        let model = try launch()
        send(model)
        model.apply(artifact("new", open: true, seq: 9))
        // A restored chat: the transcript, then the stored artifacts, unopened.
        model.apply(history([]))
        model.apply(artifact("a1"))
        model.apply(artifact("a2"))
        model.apply(artifact("new"))
        assertNewestShown(model)
    }

    func testTheHistoryCarryingTheRememberedOneAfterTheNewArtifact() throws {
        let model = try launch()
        send(model)
        model.apply(artifact("new", open: true, seq: 9))
        model.apply(history([artifact("a1"), artifact("a2"), artifact("new")]))
        assertNewestShown(model)
    }

    /// The other failing order: the agent's artifact arrives while the
    /// welcome still holds the restore; going into the conversation then
    /// put the remembered one over it.
    func testTheNewArtifactWhileTheRestoreIsHeld() throws {
        let model = try launch()
        model.apply(history([artifact("a1"), artifact("a2")]))
        model.apply(.chatLive(ChatLive(chat: 3)))
        model.apply(artifact("new", open: true, seq: 9))
        XCTAssertNil(model.heldViewer, "the newer artifact replaces the held restore")
        send(model)
        assertNewestShown(model)
    }

    func testTheNewArtifactWhileTheRestoreWaitsForItsListing() throws {
        let model = try launch()
        model.open(chat: 3)  // View Session 3 before its events: the restore waits for "a2"
        model.apply(artifact("new", open: true, seq: 9))
        model.apply(history([artifact("a1"), artifact("a2"), artifact("new")]))
        assertNewestShown(model)
        // A later replay from the beginning (the gateway restarted) keeps it.
        model.apply(history([artifact("a1"), artifact("a2"), artifact("new")]))
        assertNewestShown(model)
    }

    func testAPickFromTheHistoryAlsoWinsOverTheRemembered() throws {
        let model = try launch()
        model.open(chat: 3)
        model.apply(.artifactCreated(ArtifactCreated(chat: 3, artifact: Artifact(
            id: "new", kind: .file, location: "/tmp/demo/new.html", media: .html, title: "new.html",
            source: .tool, open: false), seq: 9)))
        let picked = try XCTUnwrap(model.artifacts[3]?.first { $0.id == "new" })
        model.show(picked, in: 3)
        model.apply(history([artifact("a1"), artifact("a2"), artifact("new")]))
        assertNewestShown(model)
    }

    /// The restore itself still works when nothing newer came.
    func testWithNothingNewerTheRememberedOneStillComesBack() throws {
        let model = try launch()
        send(model)
        model.apply(history([artifact("a1", open: true, seq: 1), artifact("a2", seq: 2)]))
        XCTAssertEqual(model.current[3]?.id, "a2", "a replayed auto-open is not newer than the remembered one")
    }
}
