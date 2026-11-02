import AppKit
import SwiftUI
import XCTest
@testable import Portico

/// Fix I-1 (v0.14 §6b.2): the viewer divider's grip reaches 13 pt over the
/// conversation, so the conversation's scrollers move left by as much
/// while the viewer is shown; a drag on the scroller then scrolls.
@MainActor
final class ScrollerClearanceTests: XCTestCase {
    func testTheOverhangIsTheGripsReachPastTheLine() {
        XCTAssertEqual(ColumnDivider.overhang(.leading), 13)
        XCTAssertEqual(ColumnDivider.overhang(.leading), -ColumnDivider.gripSpan(.leading).lowerBound)
        XCTAssertEqual(ColumnDivider.overhang(.centred), 6.5)
    }

    func testClearanceOnlyWhileTheViewerIsShown() {
        XCTAssertEqual(MainWindow.scrollerClearance(viewerShown: true), 13)
        XCTAssertEqual(MainWindow.scrollerClearance(viewerShown: false), 0)
    }

    /// The modifier the transcript and the pinned cards use, hosted: the
    /// AppKit scroll view under it keeps its scroller clear of the grip.
    func testTheScrollersInsetFollowsTheClearance() throws {
        for clearance in [CGFloat(13), 0] {
            let host = NSHostingView(rootView:
                ScrollView { Color.red.frame(height: 2000) }
                    .clearOfViewerGrip()
                    .environment(\.viewerGripClearance, clearance)
                    .frame(width: 400, height: 300))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            defer { window.close() }
            let scroll = try XCTUnwrap(Self.scrollView(in: host))
            XCTAssertEqual(scroll.scrollerInsets.right, clearance, "clearance \(clearance)")
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
}
