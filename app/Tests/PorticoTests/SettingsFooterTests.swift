import XCTest
@testable import Portico

/// v0.9 decisions 6 and 7: the sidebar footer's name and initial, and the
/// quit choices' new wording in Settings › Gateway.
final class SettingsFooterTests: XCTestCase {
    func testFirstNameAndInitialComeFromTheFullName() {
        let person = PersonName(fullName: "Larry Paul Pelty")
        XCTAssertEqual(person.first, "Larry")
        XCTAssertEqual(person.initial, "L")
    }

    func testInitialIsUpperCased() {
        XCTAssertEqual(PersonName(fullName: "ana lópez").initial, "A")
    }

    func testEmptyOrBlankNameGivesNoNameAndTheGlyph() {
        for name in ["", "   "] {
            let person = PersonName(fullName: name)
            XCTAssertNil(person.first)
            XCTAssertNil(person.initial)
        }
    }

    func testGreetingUsesTheSameFirstName() {
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
        XCTAssertEqual(StartView.greeting(at: morning, fullName: "  Larry Pelty"), "Good morning, Larry")
        XCTAssertEqual(StartView.greeting(at: morning, fullName: " "), "Good morning")
    }

    func testQuitLabelsUseTheNewWording() {
        XCTAssertEqual(Settings.QuitBehaviour.keepRunning.label, "Keep the gateway and its services running")
        XCTAssertEqual(Settings.QuitBehaviour.stopEverything.label, "Stop the gateway and its services")
        XCTAssertTrue(Settings.QuitBehaviour.caption.contains("battery"))
        XCTAssertTrue(Settings.QuitBehaviour.caption.contains("stop command first"))
    }

    func testQuitRawValuesAreUnchangedSoSavedChoicesSurvive() {
        XCTAssertEqual(Settings.QuitBehaviour.keepRunning.rawValue, "keepRunning")
        XCTAssertEqual(Settings.QuitBehaviour.stopEverything.rawValue, "stopEverything")
        XCTAssertEqual(Settings.QuitBehaviour.allCases, [.keepRunning, .stopEverything])
    }

    // MARK: - settings window (v0.12 spec section 6, v0.13 decision 7)

    func testWindowIs700By640() {
        XCTAssertEqual(SettingsWindow.width, 700)
        XCTAssertEqual(SettingsWindow.height, 640)
    }

    @MainActor
    private func model(capabilities: [String]) -> AppModel {
        let name = "portico.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(settings: Settings(defaults: defaults))
        model.outbound = { _ in }
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.12.0", epoch: "e1",
            brand: Brand(name: "Portico", agentName: "Acme"), actions: [], roots: [], commands: [],
            capabilities: capabilities)))
        return model
    }

    @MainActor
    func test_no_clear_sessions_control() {
        let model = model(capabilities: ["sessions", "sessions.clear", "spaces.v1"])
        let titles = GeneralSettingsPresentation.sectionTitles(capabilities: model.hello?.capabilities ?? [])
        XCTAssertFalse(titles.contains("Sessions"))
        XCTAssertEqual(titles, ["Folder", "Viewer", "Spaces"])
        XCTAssertFalse(GeneralSettingsPresentation.sectionTitles(capabilities: ["sessions.clear"]).contains("Sessions"))
        // And no path in the model sends the message, whatever the gateway offers.
        let sent = AppModelTests.Sent()
        model.outbound = { sent.frames.append($0) }
        model.apply(.chatList(ChatList(chats: [
            ChatSummary(chat: 1, folder: "/tmp", alias: nil, state: .stopped, created: "2026-10-27T11:00:00Z", title: nil, ended: "2026-10-27T11:30:00Z", logged: nil, parent: nil, compactions: nil, contextPercent: nil),
            ChatSummary(chat: 2, folder: "/tmp", alias: nil, state: .idle, created: "2026-10-27T11:40:00Z", title: nil, ended: nil, logged: nil, parent: 1, compactions: nil, contextPercent: nil)])))
        model.settings.viewerAgentCanSee = false
        model.settings.spacesNotify = false
        model.sendViewerSettings()
        XCTAssertFalse(sent.types().contains("sessions.clear"))
    }

    @MainActor
    func test_check_html_disabled_when_can_see_off() {
        let model = model(capabilities: [])
        XCTAssertTrue(GeneralSettingsPresentation.checksHTMLEnabled(canSee: model.agentCanSee))
        model.settings.viewerAgentCanSee = false
        XCTAssertFalse(GeneralSettingsPresentation.checksHTMLEnabled(canSee: model.agentCanSee))
        model.settings.viewerAgentChecksHTML = true
        XCTAssertFalse(model.agentChecksHTML, "reads off while the agent cannot see")
        model.settings.viewerAgentCanSee = true
        XCTAssertTrue(GeneralSettingsPresentation.checksHTMLEnabled(canSee: model.agentCanSee))
    }

    func test_spaces_group_only_with_capability() {
        XCTAssertEqual(GeneralSettingsPresentation.sectionTitles(capabilities: []), ["Folder", "Viewer"])
        XCTAssertEqual(GeneralSettingsPresentation.sectionTitles(capabilities: ["spaces.v1"]), ["Folder", "Viewer", "Spaces"])
    }

    func testViewerCopyIsGenericAndExact() {
        XCTAssertEqual(GeneralSettingsPresentation.canSeeNote,
            "The agent can look at, scroll and click what's open in the viewer, when asked or when it helps. You see every action as it happens.")
        XCTAssertEqual(GeneralSettingsPresentation.checksHTMLNote,
            "After creating or changing an HTML page, the agent opens it in the viewer and looks before replying. Uses more tokens.")
        XCTAssertEqual(GatewayConnectionPresentation.caption,
            "Leave these empty: the app finds the gateway and reads its token itself. A change is used the next time it connects.")
    }
}
