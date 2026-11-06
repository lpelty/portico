import AppKit
import XCTest

@testable import Portico

/// v0.22 §1: the visual fixes that code can pin (items 20–23; item 7 is in
/// `TipTests`).
@MainActor
final class VisualFixesTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = ListFontSweepTests.sources.appendingPathComponent(path)
        return ListFontSweepTests.withoutComments(try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - 21, overlay scroll bars

    func testScrollViewsAreOverlayWhateverTheSystemSetting() {
        OverlayScrollers.install()
        OverlayScrollers.install()  // once is enough; twice is harmless
        XCTAssertEqual(NSScroller.preferredScrollerStyle, .overlay)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = true
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "a scroll view made after launch")
        // The system preference changing (to Always) makes AppKit re-read it.
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
    }

    func testTheAppInstallsThemAtLaunch() throws {
        XCTAssertTrue(try source("PorticoApp.swift").contains("OverlayScrollers.install()"))
    }

    func testTheWebPagesDrawThinScrollBars() throws {
        let css = try String(contentsOf: try XCTUnwrap(AppResources.url(forResource: "viewer", withExtension: "css")), encoding: .utf8)
        XCTAssertTrue(css.contains("::-webkit-scrollbar {"))
        XCTAssertTrue(css.contains("::-webkit-scrollbar-thumb"))
        XCTAssertTrue(css.contains("border-radius"))
        XCTAssertFalse(css.contains("rgba("), "solid colours only")
    }

    // MARK: - 20, a plain "Changed this session" heading

    func testChangedThisSessionIsAPlainHeadingNotASectionHeader() throws {
        let files = try source("Views/Sidebar/FilesView.swift")
        XCTAssertEqual(ChangedHeading.text, "Changed this session")
        XCTAssertEqual(files.components(separatedBy: "ChangedHeading().solidRow()").count - 1, 2,
                       "the folders tab and the filter's list")
        XCTAssertFalse(files.contains("Text(\"Changed this session\")"), "not in a section header any more")
    }

    // MARK: - 22, the settings window on the main window's background

    func testSettingsUsesTheMainWindowsBackground() {
        XCTAssertEqual(SettingsWindow.background, .window)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        SettingsWindow.style(window)
        XCTAssertTrue(window.titlebarAppearsTransparent, "the tab header shows the window's background")
        XCTAssertTrue(window.isOpaque)
        for (name, expected) in [(NSAppearance.Name.darkAqua, Theme.hex(.window).dark), (.aqua, Theme.hex(.window).light)] {
            var drawn: NSColor?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                drawn = window.backgroundColor.usingColorSpace(.sRGB)
            }
            let want = NSColor(hex: expected).usingColorSpace(.sRGB)!
            XCTAssertEqual(drawn?.redComponent ?? -1, want.redComponent, accuracy: 0.002, "\(name.rawValue)")
            XCTAssertEqual(drawn?.greenComponent ?? -1, want.greenComponent, accuracy: 0.002)
            XCTAssertEqual(drawn?.blueComponent ?? -1, want.blueComponent, accuracy: 0.002)
            XCTAssertEqual(drawn?.alphaComponent ?? -1, 1, "solid")
        }
    }

    func testSettingsTabHeaderStandsApartFromThePage() throws {
        XCTAssertEqual(SettingsWindow.header, .sidebar)
        XCTAssertNotEqual(Theme.hex(SettingsWindow.header).dark, Theme.hex(SettingsWindow.background).dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        SettingsWindow.style(window)
        SettingsWindow.style(window)
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        let backdrops = titlebar.subviews.filter { $0 is SettingsWindow.HeaderBackdrop }
        XCTAssertEqual(backdrops.count, 1, "installed once, however often the window is styled")
        XCTAssertTrue(titlebar.subviews.first is SettingsWindow.HeaderBackdrop, "behind the tabs and the traffic lights")
        XCTAssertNil(backdrops[0].hitTest(NSPoint(x: 5, y: 5)), "never takes a click")
    }

    func testFolderNameIsARowNotASectionHeader() throws {
        let files = try source("Views/Sidebar/FilesView.swift")
        XCTAssertFalse(files.contains("} header: {"), "a plain list frames a section header in its own lighter fill, with a line under it")
    }

    func testSettingsSectionBoxesKeepThePanel() throws {
        XCTAssertTrue(try source("Views/Settings/SettingsKit.swift").contains(".background(Theme.panel, in: RoundedRectangle(cornerRadius: SettingsKit.panelRadius"))
        XCTAssertTrue(try source("Views/SettingsView.swift").contains(".background(SettingsWindowBackground())"))
    }

    // MARK: - 23, one height for the viewer's header buttons

    func testHeaderButtonsShareOneHeight() throws {
        XCTAssertEqual(ViewerHeader.buttonHeight, 24)
        let viewer = try source("Views/Viewer/ViewerView.swift")
        let editor = try source("Views/Viewer/EditorPane.swift")
        // Icon-only squares: Edit, Focus, Close.
        let square = ".frame(width: ViewerHeader.buttonHeight, height: ViewerHeader.buttonHeight)"
        XCTAssertEqual(viewer.components(separatedBy: square).count - 1, 2, "Focus and Close")
        XCTAssertEqual(editor.components(separatedBy: square).count - 1, 1, "Edit")
        // The open buttons, labelled or not: fixed height, no vertical padding.
        XCTAssertTrue(viewer.contains("minHeight: ViewerHeader.buttonHeight,\n                   maxHeight: ViewerHeader.buttonHeight)"))
        XCTAssertFalse(viewer.contains(".padding(.vertical, labelled ?"))
    }
}
