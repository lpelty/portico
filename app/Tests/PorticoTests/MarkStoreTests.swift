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
    private func seeded(_ store: MarkStore = MarkStore()) -> MarkStore {
        store.add(chat: 1, page: p1, items: items([("Elevation chart", "No axis labels"), ("Start button", "Too small"), ("Share link", "Hidden")]),
                  call: "c1", toolUseId: "t1", replace: false)
        store.add(chat: 1, page: p2, items: items([("End hike", "Same as Pause, one tap away")]),
                  call: "c2", toolUseId: "t2", replace: false)
        return store
    }
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A page's marks are that page's: each page numbers from 1, whatever
    /// chat made them.
    func testEachPageNumbersFromOne() {
        let store = MarkStore()
        let a = store.add(chat: 1, page: p1, items: items([("a", ""), ("b", ""), ("c", "")]), call: "c1", toolUseId: nil, replace: false)
        let b = store.add(chat: 1, page: p2, items: items([("d", "")]), call: "c2", toolUseId: nil, replace: false)
        let c = store.add(chat: 2, page: p1, items: items([("e", "")]), call: "c3", toolUseId: nil, replace: false)
        XCTAssertEqual(a.map(\.number), [1, 2, 3])
        XCTAssertEqual(b.map(\.number), [1])
        XCTAssertEqual(c.map(\.number), [4], "another chat adds to the same page")
        XCTAssertEqual(store.marks(on: p1).count, 4)
    }

    func testReplaceIsThisPageOnly() {
        let store = seeded()
        let r = store.add(chat: 1, page: p2, items: items([("x", "")]), call: "c3", toolUseId: nil, replace: true)
        XCTAssertEqual(r.map(\.number), [1])
        XCTAssertEqual(store.marks(on: p2).count, 1)
        XCTAssertEqual(store.marks(on: p1).count, 3, "the other page keeps its marks")
    }

    func testClearIsThisPageOnlyAndRestartsAtOne() {
        let store = seeded()
        XCTAssertEqual(store.clear(page: p1), 3)
        XCTAssertEqual(store.clear(page: p1), 0)
        XCTAssertEqual(store.marks(on: p2).count, 1, "the other page keeps its marks")
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

    /// The chip counts the page's own marks and never mentions other pages.
    func testChipTextIsThisPagesCount() {
        let store = seeded()
        XCTAssertEqual(store.chipText(page: p1, form: .full), "3 marks")
        XCTAssertEqual(store.chipText(page: p1, form: .short), "3 marks")
        XCTAssertEqual(store.chipText(page: p1, form: .count), "3")
        XCTAssertEqual(store.chipText(page: p2, form: .full), "1 mark")
        XCTAssertEqual(store.chipText(page: MarkPage(key: "/x/other.html", name: "other.html"), form: .full), "")
        XCTAssertEqual(store.chipText(page: nil, form: .full), "")
    }

    func testLookTextIsThisPages() {
        let store = seeded()
        XCTAssertEqual(store.lookText(current: p2), """
        Marks:
        - 1 · End hike — Same as Pause, one tap away
        """)
        XCTAssertNil(store.lookText(current: MarkPage(key: "/x/other.html", name: "other.html")))
        XCTAssertNil(store.lookText(current: nil))
    }

    func testLookTextNotFoundEmptyNoteAndHidden() {
        let store = MarkStore()
        store.add(chat: 1, page: p1, items: items([("Chart", ""), ("Nav", "Odd")]), call: "c", toolUseId: nil, replace: false)
        store.setFound(page: p1, found: [2: false])
        XCTAssertEqual(store.lookText(current: p1), """
        Marks:
        - 1 · Chart
        - 2 · Nav — Odd — not on the page now
        """)
        store.setHidden(true, page: p1)
        XCTAssertEqual(store.lookText(current: p1), """
        Marks (hidden by the person, not drawn on the page now):
        - 1 · Chart
        - 2 · Nav — Odd
        """)
    }

    func testSetFoundDoesNotPublishWhenUnchanged() {
        let store = seeded()
        var published = 0
        let sub = store.$marks.dropFirst().sink { _ in published += 1 }
        store.setFound(page: p1, found: [1: true, 2: true])
        XCTAssertEqual(published, 0)
        store.setFound(page: p1, found: [1: false])
        XCTAssertEqual(published, 1)
        store.setFound(page: p1, found: [1: false])
        XCTAssertEqual(published, 1)
        sub.cancel()
    }

    /// Hidden is per page, keeps the marks and their count, and new marks
    /// on a hidden page show it again.
    func testHideAndShowKeepTheMarks() {
        let store = seeded()
        store.setHidden(true, page: p1)
        XCTAssertTrue(store.isHidden(p1))
        XCTAssertFalse(store.isHidden(p2))
        XCTAssertEqual(store.marks(on: p1).map(\.number), [1, 2, 3])
        XCTAssertEqual(store.chipText(page: p1, form: .full), "3 marks")
        store.setHidden(false, page: p1)
        XCTAssertFalse(store.isHidden(p1))
        store.setHidden(true, page: p1)
        store.add(chat: 1, page: p1, items: items([("x", "")]), call: "c3", toolUseId: nil, replace: false)
        XCTAssertFalse(store.isHidden(p1), "new marks are seen")
        store.setHidden(true, page: MarkPage(key: "/x/none.html", name: "none.html"))
        XCTAssertEqual(store.hidden, [], "a page without marks has nothing to hide")
    }

    /// Show again shows the call's page and gives its first mark to go to.
    func testShowAgainShowsHiddenMarks() {
        let store = seeded()
        store.setHidden(true, page: p1)
        XCTAssertEqual(store.showAgain(chat: 1, toolUseId: "t1")?.number, 1)
        XCTAssertFalse(store.isHidden(p1))
        XCTAssertNil(store.showAgain(chat: 1, toolUseId: "nope"))
        XCTAssertNil(store.showAgain(chat: 2, toolUseId: "t1"), "a call belongs to its chat")
    }

    /// Clear is final: the call's record loses the marks, so the chat's
    /// row offers no Show again and none brings them back.
    func testClearIsFinal() {
        let store = seeded()
        store.clear(page: p1)
        XCTAssertNil(store.showAgain(chat: 1, toolUseId: "t1"))
        XCTAssertEqual(store.call(chat: 1, toolUseId: "t1")?.marks, [])
        XCTAssertEqual(store.call(chat: 1, toolUseId: "t2")?.marks.count, 1)
        XCTAssertTrue(store.marks(on: p1).isEmpty)
    }

    /// A page is its key: the same file reached under another name (a
    /// space's title, then the file's name) is the same page, and the
    /// store keeps the name it first saw.
    func testPageIdentityIsTheKeyAlone() {
        let space = MarkPage(key: "/x/brief.md", name: "Brief")
        let file = MarkPage(key: "/x/brief.md", name: "brief.md")
        XCTAssertEqual(space, file)
        XCTAssertEqual(Set([space, file]).count, 1)
        let store = MarkStore()
        store.add(chat: 1, page: space, items: items([("a", "")]), call: "c1", toolUseId: nil, replace: false)
        let more = store.add(chat: 1, page: file, items: items([("b", "")]), call: "c2", toolUseId: nil, replace: false)
        XCTAssertEqual(more.first?.page.name, "Brief", "a known key keeps its stored name")
        XCTAssertEqual(store.marks(on: file).count, 2)
        store.setFound(page: file, found: [1: false])
        XCTAssertEqual(store.marks(on: file).first?.found, false)
    }

    // MARK: kept on disk (v0.26.5)

    /// Marks, their numbers and whether they were hidden come back in a
    /// new store reading the same home, as after a restart.
    func testMarksComeBackAsTheyWereLeft() throws {
        let home = try home()
        let first = MarkStore()
        first.keep(in: home)
        _ = seeded(first)
        first.setHidden(true, page: p1)
        first.setFound(page: p2, found: [1: false])

        let second = MarkStore()
        second.keep(in: home)
        XCTAssertEqual(second.marks(on: p1).map(\.number), [1, 2, 3])
        XCTAssertEqual(second.marks(on: p1).map(\.note), ["No axis labels", "Too small", "Hidden"])
        XCTAssertEqual(second.marks(on: p1).first?.page.name, "trail-detail.html")
        XCTAssertEqual(second.marks(on: p1).first?.locator, loc("Elevation chart"))
        XCTAssertTrue(second.isHidden(p1), "hidden marks come back hidden")
        XCTAssertFalse(second.isHidden(p2), "shown marks come back shown")
        XCTAssertEqual(second.marks(on: p2).first?.found, true, "found is read from the page again")
        let more = second.add(chat: 9, page: p1, items: items([("x", "")]), call: "c9", toolUseId: nil, replace: false)
        XCTAssertEqual(more.map(\.number), [4])
    }

    func testClearedMarksAreGoneFromDisk() throws {
        let home = try home()
        let first = MarkStore()
        first.keep(in: home)
        _ = seeded(first)
        first.clear(page: p1)
        let second = MarkStore()
        second.keep(in: home)
        XCTAssertTrue(second.marks(on: p1).isEmpty)
        XCTAssertEqual(second.marks(on: p2).count, 1)
    }

    /// The file is the person's alone, and a file that cannot be read
    /// starts empty without being thrown away until a change writes it.
    func testFileIsPrivateAndAnUnreadableFileStartsEmpty() throws {
        let home = try home()
        let file = home.appendingPathComponent(MarkStore.fileName)
        let store = MarkStore()
        store.keep(in: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing is written until there is a mark")
        _ = seeded(store)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)

        try Data("not json".utf8).write(to: file)
        let broken = MarkStore()
        broken.keep(in: home)
        XCTAssertTrue(broken.all.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
    }

    /// Without a home (a test, or no supervisor) the store works in memory.
    func testWithoutAHomeNothingIsWritten() {
        let store = seeded()
        XCTAssertEqual(store.all.count, 4)
    }
}
