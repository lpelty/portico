import AppKit
import Foundation
import XCTest

@testable import Portico

/// v0.7 decisions 1 and 5 (frames AA1, AA3): the one date rule every time
/// in the app follows, on a fixed clock, time zone and locale (12- and
/// 24-hour), and the corner test that decides whether the brand mark is
/// rounded. View-free.
final class DateRuleAndMarkTests: XCTestCase {

    // MARK: - the date rule

    /// A zone that is not UTC, so a test fails if the zone is ignored.
    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")
    /// Thursday 29 Oct 2026, 10:00 AM in Chicago (CDT, UTC−5).
    private let now = SessionTime.parse("2026-10-29T15:00:00Z")!
    private func date(_ stamp: String) -> Date { SessionTime.parse(stamp)! }

    private func full(_ stamp: String, _ locale: Locale) -> String {
        SessionTime.full(date(stamp), now: now, calendar: chicago, locale: locale)
    }
    private func compact(_ stamp: String, _ locale: Locale) -> String {
        SessionTime.compact(date(stamp), now: now, calendar: chicago, locale: locale)
    }

    func testTheFullFormIn12Hour() {
        XCTAssertEqual(full("2026-10-29T14:59:40Z", us), "just now")
        XCTAssertEqual(full("2026-10-29T14:48:00Z", us), "12 min ago")
        XCTAssertEqual(full("2026-10-29T13:47:00Z", us), "today, 8:47 AM", "an hour or more ago today: the time")
        XCTAssertEqual(full("2026-10-28T21:12:00Z", us), "yesterday, 4:12 PM")
        XCTAssertEqual(full("2026-10-29T03:00:00Z", us), "yesterday, 10:00 PM", "the day is the calendar zone's, not UTC's")
        XCTAssertEqual(full("2026-10-27T21:12:00Z", us), "Oct 27, 4:12 PM", "this year: no year")
        XCTAssertEqual(full("2025-10-27T21:12:00Z", us), "Oct 27, 2025, 4:12 PM", "an earlier year: with it")
    }

    func testTheFullFormIn24Hour() {
        XCTAssertEqual(full("2026-10-29T14:48:00Z", gb), "12 min ago")
        XCTAssertEqual(full("2026-10-29T13:47:00Z", gb), "today, 8:47")
        XCTAssertEqual(full("2026-10-28T21:12:00Z", gb), "yesterday, 16:12")
        XCTAssertEqual(full("2026-10-27T21:12:00Z", gb), "27 Oct, 16:12", "the locale orders the day and month")
        XCTAssertEqual(full("2025-10-27T21:12:00Z", gb), "27 Oct 2025, 16:12")
    }

    func testTheCompactColumn() {
        XCTAssertEqual(compact("2026-10-29T14:59:40Z", us), "just now")
        XCTAssertEqual(compact("2026-10-29T14:48:00Z", us), "12 min ago")
        XCTAssertEqual(compact("2026-10-29T13:47:00Z", us), "8:47 AM")
        XCTAssertEqual(compact("2026-10-28T21:12:00Z", us), "Yesterday")
        XCTAssertEqual(compact("2026-10-27T21:12:00Z", us), "Oct 27")
        XCTAssertEqual(compact("2025-10-27T21:12:00Z", us), "Oct 27, 2025")

        XCTAssertEqual(compact("2026-10-29T13:47:00Z", gb), "8:47")
        XCTAssertEqual(compact("2026-10-28T21:12:00Z", gb), "Yesterday")
        XCTAssertEqual(compact("2026-10-27T21:12:00Z", gb), "27 Oct")
        XCTAssertEqual(compact("2025-10-27T21:12:00Z", gb), "27 Oct 2025")
    }

    func testTheCompactTooltipIsTheFullDateAndTime() {
        XCTAssertEqual(SessionTime.tooltip(date("2026-10-29T14:48:00Z"), calendar: chicago, locale: us), "Oct 29, 2026, 9:48 AM")
        XCTAssertEqual(SessionTime.tooltip(date("2026-10-29T14:48:00Z"), calendar: chicago, locale: gb), "29 Oct 2026, 9:48")
    }

    func testNoTimeIsABareClock() {
        // Each part of the rule names its day or is relative.
        for stamp in ["2026-10-29T13:47:00Z", "2026-10-28T21:12:00Z", "2026-10-27T21:12:00Z", "2025-10-27T21:12:00Z"] {
            XCTAssertNotEqual(full(stamp, us), SessionTime.clock(date(stamp), calendar: chicago, locale: us))
        }
        XCTAssertFalse(SessionTime.clock(date("2026-10-29T13:47:00Z"), calendar: chicago, locale: us).contains("\u{202F}"),
            "the narrow space before AM is a plain one")
    }

    // MARK: - the rounded mark

    private func image(side: CGFloat = 64, draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(rect)
            return true
        }
    }

    func testAnOpaqueSquareIsRounded() {
        let square = image { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
        }
        XCTAssertTrue(BrandIconShape.rounds(square))
    }

    func testTransparentCornersAreDrawnAsGiven() {
        let rounded = image { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22).fill()
        }
        XCTAssertFalse(BrandIconShape.rounds(rounded), "already shaped")
        let circle = image { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        XCTAssertFalse(BrandIconShape.rounds(circle))
    }

    func testOneOpaqueCornerStillRounds() {
        let notched = image { rect in
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        }
        XCTAssertTrue(BrandIconShape.rounds(notched), "only an image with all four corners transparent is shaped already")
    }

    func testTheRadiusIsTheMacOSIconShare() {
        XCTAssertEqual(BrandIconShape.cornerFraction, 0.22, accuracy: 0.005)
    }
}
