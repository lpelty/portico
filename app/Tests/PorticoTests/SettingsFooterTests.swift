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
}
