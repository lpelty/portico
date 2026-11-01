import XCTest
@testable import Portico

@MainActor
final class MarkStoreTests: XCTestCase {
    let p1 = MarkPage(key: "/x/trail-detail.html", name: "trail-detail.html")
    let p2 = MarkPage(key: "/x/trail-start.html", name: "trail-start.html")

    private func loc(_ text: String) -> MarkLocator { MarkLocator(path: "0/1", tag: "button", text: text) }
    private func items(_ rows: [(String, String)]) -> [(label: String, note: String, locator: MarkLocator)] {
        rows.map { (label: $0.0, note: $0.1, locator: loc($0.0)) }
    }
    private func seeded() -> MarkStore {
        let store = MarkStore()
        store.add(chat: 1, page: p1, items: items([("Elevation chart", "No axis labels"), ("Start button", "Too small"), ("Share link", "Hidden")]),
                  call: "c1", toolUseId: "t1", replace: false)
        store.add(chat: 1, page: p2, items: items([("End hike", "Same as Pause, one tap away")]),
                  call: "c2", toolUseId: "t2", replace: false)
        return store
    }

    func testNumbersCarryAcrossPages() {
        let store = MarkStore()
        let a = store.add(chat: 1, page: p1, items: items([("a", ""), ("b", ""), ("c", "")]), call: "c1", toolUseId: nil, replace: false)
        let b = store.add(chat: 1, page: p2, items: items([("d", "")]), call: "c2", toolUseId: nil, replace: false)
        XCTAssertEqual(a.map(\.number), [1, 2, 3])
        XCTAssertEqual(b.map(\.number), [4])
        XCTAssertEqual(a.first?.id, 1)
    }

    func testReplaceStartsAtOne() {
        let store = seeded()
        let r = store.add(chat: 1, page: p2, items: items([("x", "")]), call: "c3", toolUseId: nil, replace: true)
        XCTAssertEqual(r.map(\.number), [1])
        XCTAssertEqual(store.marks[1]?.count, 1)
    }

    func testClearRestartsAtOne() {
        let store = seeded()
        XCTAssertEqual(store.clear(chat: 1), 4)
        XCTAssertEqual(store.clear(chat: 1), 0)
        let r = store.add(chat: 1, page: p1, items: items([("x", "")]), call: "c3", toolUseId: nil, replace: false)
        XCTAssertEqual(r.map(\.number), [1])
    }

    func testCutNote() {
        XCTAssertEqual(MarkStore.cutNote(String(repeating: "a", count: 61)), String(repeating: "a", count: 59) + "…")
        XCTAssertEqual(MarkStore.cutNote(String(repeating: "a", count: 60)), String(repeating: "a", count: 60))
        let cut = MarkStore.cutNote(String(repeating: "👍🏽", count: 70))
        XCTAssertEqual(cut.count, 60)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testChipText() {
        let one = MarkStore()
        one.add(chat: 1, page: p1, items: items([("a", "")]), call: "c", toolUseId: nil, replace: false)
        XCTAssertEqual(one.chipText(chat: 1, form: .full), "1 mark")
        let store = seeded()
        XCTAssertEqual(store.chipText(chat: 1, form: .full), "4 marks · 2 pages")
        XCTAssertEqual(store.chipText(chat: 1, form: .short), "4 marks")
        XCTAssertEqual(store.chipText(chat: 1, form: .count), "4")
    }

    func testGroupsThisPageFirst() {
        let groups = seeded().groups(chat: 1, current: p2)
        XCTAssertEqual(groups.map(\.page), [p2, p1])
        XCTAssertEqual(groups.map { $0.marks.map(\.number) }, [[4], [1, 2, 3]])
    }

    func testLookText() {
        let store = seeded()
        XCTAssertEqual(store.lookText(chat: 1, current: p2), """
        Marks:
        - 4 · End hike — Same as Pause, one tap away (this page)
        - 1 · Elevation chart — No axis labels (trail-detail.html)
        - 2 · Start button — Too small (trail-detail.html)
        - 3 · Share link — Hidden (trail-detail.html)
        """)
        XCTAssertNil(MarkStore().lookText(chat: 1, current: p2))
    }

    func testLookTextNotFoundAndEmptyNote() {
        let store = MarkStore()
        store.add(chat: 1, page: p1, items: items([("Chart", ""), ("Nav", "Odd")]), call: "c", toolUseId: nil, replace: false)
        store.setFound(chat: 1, page: p1, found: [2: false])
        XCTAssertEqual(store.lookText(chat: 1, current: p1), """
        Marks:
        - 1 · Chart (this page)
        - 2 · Nav — Odd (this page) — not on the page now
        """)
    }

    func testSetFoundDoesNotPublishWhenUnchanged() {
        let store = seeded()
        var published = 0
        let sub = store.$marks.dropFirst().sink { _ in published += 1 }
        store.setFound(chat: 1, page: p1, found: [1: true, 2: true])
        XCTAssertEqual(published, 0)
        store.setFound(chat: 1, page: p1, found: [1: false])
        XCTAssertEqual(published, 1)
        store.setFound(chat: 1, page: p1, found: [1: false])
        XCTAssertEqual(published, 1)
        sub.cancel()
    }

    func testShowAgainRestoresOriginalNumbersWhenFree() {
        let store = seeded()
        store.clear(chat: 1)
        XCTAssertEqual(store.showAgain(chat: 1, toolUseId: "t1").map(\.number), [1, 2, 3])
        XCTAssertEqual(store.marks[1]?.count, 3)
        XCTAssertEqual(store.showAgain(chat: 1, toolUseId: "nope"), [])
    }

    func testShowAgainRenumbersWhenTaken() {
        let store = seeded()
        store.clear(chat: 1)
        store.add(chat: 1, page: p2, items: items([("x", "")]), call: "c3", toolUseId: "t3", replace: false)
        XCTAssertEqual(store.showAgain(chat: 1, toolUseId: "t1").map(\.number), [2, 3, 4])
    }

    func testShowAgainWhenStillPresentChangesNothing() {
        let store = seeded()
        let again = store.showAgain(chat: 1, toolUseId: "t1")
        XCTAssertEqual(again.map(\.number), [1, 2, 3])
        XCTAssertEqual(store.marks[1]?.count, 4)
    }

    func testEndSessionClears() {
        let store = seeded()
        store.endSession(chat: 1)
        XCTAssertNil(store.lookText(chat: 1, current: p1))
        XCTAssertEqual(store.showAgain(chat: 1, toolUseId: "t1"), [])
    }
}
