import XCTest
@testable import Portico

final class HistoryTests: XCTestCase {
    private func ended(_ chat: Int, _ title: String?) -> ChatSummary {
        ChatSummary(chat: chat, folder: "/tmp/demo", state: .stopped, created: "2026-10-27T12:00:00Z",
                    title: title, ended: "2026-10-27T13:00:00Z")
    }

    func testTheRowIsHiddenWithNoEndedSessions() {
        XCTAssertFalse(HistoryPresentation(sessions: [], query: "").showsRow)
        XCTAssertTrue(HistoryPresentation(sessions: [ended(1, "Sam")], query: "").showsRow)
    }

    func testTheRowAndHeaderCounts() {
        let eleven = (1...11).map { ended($0, "Title \($0)") }
        let p = HistoryPresentation(sessions: eleven, query: "")
        XCTAssertEqual(p.rowCount, "11 earlier")
        XCTAssertEqual(p.header, "11 ended sessions")
        XCTAssertEqual(HistoryPresentation(sessions: [ended(1, "Sam")], query: "").header, "1 ended session")
    }

    func testAQueryFiltersByTitleIgnoringCase() {
        let all = [ended(1, "Plan for Acme"), ended(2, "Priya's notes"), ended(3, nil)]
        let p = HistoryPresentation(sessions: all, query: "ACME")
        XCTAssertEqual(p.shown.map(\.chat), [1])
        XCTAssertNil(p.emptyMessage)
        XCTAssertEqual(HistoryPresentation(sessions: all, query: "").shown.count, 3)
    }

    func testAnEmptyResultSaysSo() {
        let p = HistoryPresentation(sessions: [ended(1, "Sam")], query: "q")
        XCTAssertTrue(p.shown.isEmpty)
        XCTAssertEqual(p.emptyMessage, "No session titled “q”")
        XCTAssertEqual(p.header, "1 ended session", "the header counts all, not the matches")
    }

    func testTheEmptyLineQuotesTheTrimmedQuery() {
        let p = HistoryPresentation(sessions: [ended(1, "Sam")], query: "  zed \n")
        XCTAssertEqual(p.emptyMessage, "No session titled “zed”")
    }

    func testTheSidebarBandIs36() {
        XCTAssertEqual(Theme.sidebarBandHeight, 36)
        XCTAssertEqual(Theme.toolbarHeight, 52)
    }
}
