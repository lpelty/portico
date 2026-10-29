import CoreGraphics
import Foundation
import XCTest

@testable import Portico

/// V2/V3: the viewer's artifacts menu heading and focus — the sidebar
/// hidden, the viewer at about 75 % (conversation at least 320 pt), and
/// the exact previous layout back on the second press. Focus lives in the
/// model only, so a launch never starts focused.
@MainActor
final class ArtifactFocusTests: XCTestCase {

    private func model() throws -> (AppModel, Settings) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "portico-v03-focus-\(UUID().uuidString)"))
        let settings = Settings(defaults: defaults)
        let model = AppModel(settings: settings)
        model.outbound = { _ in }
        return (model, settings)
    }

    func testFocusWidths() {
        XCTAssertEqual(ColumnWidths.focusViewer(window: 1440), 1080, "the conversation keeps a quarter")
        XCTAssertEqual(ColumnWidths.focusViewer(window: 960), 640, "never below 320 for the conversation")
        XCTAssertEqual(ColumnWidths.focusViewer(window: 600), ColumnWidths.viewerMinimum, "the viewer keeps its own minimum")
    }

    func testFocusHidesTheSidebarAndPutsEverythingBack() throws {
        let (model, settings) = try model()
        settings.sidebarWidth = 300
        settings.setViewerWidth(500, for: .reading)
        model.selected = 1
        model.sidebarVisible = true

        model.toggleFocus(chat: 1)
        XCTAssertTrue(model.isFocused(chat: 1))
        XCTAssertFalse(model.sidebarVisible)
        XCTAssertTrue(model.isViewerShown(for: 1), "focus opens the viewer")
        XCTAssertEqual(settings.sidebarWidth, 300, "the remembered widths are not touched")
        XCTAssertEqual(settings.viewerWidth(for: .reading), 500)

        model.toggleFocus(chat: 1)
        XCTAssertFalse(model.isFocused(chat: 1))
        XCTAssertTrue(model.sidebarVisible)
        XCTAssertEqual(settings.sidebarWidth, 300)
        XCTAssertEqual(settings.viewerWidth(for: .reading), 500)

        // A sidebar that was hidden before focus stays hidden after it.
        model.sidebarVisible = false
        model.toggleFocus(chat: 1)
        model.toggleFocus(chat: 1)
        XCTAssertFalse(model.sidebarVisible)
    }

    func testCollapsingTheViewerOrShowingAnotherChatEndsFocus() throws {
        let (model, _) = try model()
        model.selected = 1
        model.toggleFocus(chat: 1)
        model.setViewer(visible: false, for: 1)
        XCTAssertNil(model.viewerFocus)
        XCTAssertTrue(model.sidebarVisible)

        model.toggleFocus(chat: 1)
        model.selected = 2
        XCTAssertNil(model.viewerFocus)
        XCTAssertTrue(model.sidebarVisible)
    }

    func testANewModelIsNeverFocused() throws {
        let (model, _) = try model()
        XCTAssertNil(model.viewerFocus)
    }

    func testMadeHereHeading() throws {
        let (model, _) = try model()
        XCTAssertEqual(model.madeHereLabel, "Made in this chat")
        model.apply(.hello(HelloServer(
            protocol: protocolVersion, gatewayVersion: "0.3.0", epoch: "e",
            brand: Brand(name: "Portico", agentName: "Agent"), actions: [], roots: [], commands: [],
            capabilities: [], presentation: "single")))
        XCTAssertEqual(model.madeHereLabel, "Made in this session")
    }
}
