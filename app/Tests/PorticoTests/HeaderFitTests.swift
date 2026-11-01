import XCTest
@testable import Portico

/// v0.14 (§3.4, AK5): the viewer header measures its parts and gives way
/// in a fixed order — buttons to icons, the note, the chip's words, and
/// the title last.
final class HeaderFitTests: XCTestCase {
    private func widths(
        title: CGFloat = 180, note: CGFloat = 0, chip: (CGFloat, CGFloat, CGFloat),
        labelled: CGFloat, icons: CGFloat, fixed: CGFloat = 80
    ) -> HeaderFit.Widths {
        HeaderFit.Widths(title: title, note: note, chipFull: chip.0, chipShort: chip.1, chipCount: chip.2,
                         buttonsLabelled: labelled, buttonsIcons: icons, fixed: fixed)
    }

    /// No marks, Open externally alone: today's labelled/icon switch.
    func testNoChipOneButton() {
        let w = widths(chip: (0, 0, 0), labelled: 125, icons: 30)
        XCTAssertEqual(HeaderFit.step(available: 668, w), .full, "needs 385")
        XCTAssertEqual(HeaderFit.step(available: 385, w), .full, "exactly fits")
        XCTAssertEqual(HeaderFit.step(available: 300, w), .buttonIcons, "needs 290")
        XCTAssertEqual(HeaderFit.step(available: 280, w), .titleShrinks)
    }

    /// A vault file with marks: AK5's row is icons with the full chip.
    func testVaultFileWithMarks() {
        let w = widths(chip: (150, 85, 40), labelled: 260, icons: 62)
        XCTAssertEqual(HeaderFit.step(available: 670, w), .full)
        XCTAssertEqual(HeaderFit.step(available: 668, w), .buttonIcons, "needs 472")
    }

    func testTheNoteShrinksBeforeTheChip() {
        let w = widths(note: 200, chip: (150, 85, 40), labelled: 260, icons: 62)
        XCTAssertEqual(HeaderFit.step(available: 668, w), .noteShrinks, ".buttonIcons would need 672")
    }

    func testNarrowGoesChipShortThenCountThenTitle() {
        let w = widths(chip: (150, 85, 40), labelled: 260, icons: 62)
        XCTAssertEqual(HeaderFit.step(available: 440, w), .chipShort, "needs 407")
        XCTAssertEqual(HeaderFit.step(available: 400, w), .chipCount, "needs 362")
        XCTAssertEqual(HeaderFit.step(available: 361, w), .titleShrinks)
    }

    func testStepsAreOrdered() {
        XCTAssertLessThan(HeaderFit.Step.full, .buttonIcons)
        XCTAssertLessThan(HeaderFit.Step.chipCount, .titleShrinks)
        XCTAssertEqual(HeaderFit.Step.chipShort.chipForm, .short)
        XCTAssertEqual(HeaderFit.Step.titleShrinks.chipForm, .count)
        XCTAssertEqual(HeaderFit.Step.noteShrinks.chipForm, .full)
        XCTAssertTrue(HeaderFit.Step.full.labelled)
        XCTAssertFalse(HeaderFit.Step.buttonIcons.labelled)
    }

    /// The chip's VoiceOver label.
    func testChipSpokenLabel() {
        XCTAssertEqual(MarksChip.spokenLabel(count: 1, pages: 1), "1 mark on 1 page, opens the list")
        XCTAssertEqual(MarksChip.spokenLabel(count: 4, pages: 2), "4 marks on 2 pages, opens the list")
    }
}
