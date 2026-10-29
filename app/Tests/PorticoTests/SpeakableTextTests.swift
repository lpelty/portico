import XCTest

@testable import Portico

/// v0.9 decisions 2 and 3: what Read aloud says for a reply, and the
/// `[TTS]` tags taken out of what is drawn. Pure: no window, no voice.
final class SpeakableTextTests: XCTestCase {
    private func speech(_ markdown: String) -> String {
        SpeakableText.speech(fromMarkdown: markdown)
    }

    // MARK: markers

    func testOnlyTheMarkedPartsAreSpokenJoinedInOrder() {
        let reply = """
            Here is the detail nobody needs read out.

            [TTS]I fixed the build.[/TTS]

            ```swift
            let x = 1
            ```

            [TTS]Two tests were failing; both pass now.[/TTS]
            """
        XCTAssertEqual(speech(reply), "I fixed the build. Two tests were failing; both pass now.")
    }

    func testMarkersInsideAParagraphAndInAnyCase() {
        XCTAssertEqual(speech("Long story. [tts]Short version: done.[/Tts] More text."), "Short version: done.")
    }

    func testAnUnclosedMarkerRunsToTheEnd() {
        XCTAssertEqual(speech("Ignored.\n\n[TTS]Still streaming this part"), "Still streaming this part")
        XCTAssertEqual(SpeakableText.markedParts("a [TTS]b[/TTS] c [TTS]d"), ["b", "d"])
    }

    func testAStrayCloseIsDroppedAndTheProseIsSpoken() {
        XCTAssertNil(SpeakableText.markedParts("Done.[/TTS]"))
        XCTAssertEqual(speech("Done.[/TTS]"), "Done.")
    }

    func testEmptyMarkersFallBackToTheProse() {
        XCTAssertEqual(speech("The answer is 4.\n\n[TTS]  [/TTS]"), "The answer is 4.")
    }

    func testMarkdownInsideMarkedPartsIsSpokenAsProse() {
        XCTAssertEqual(
            speech("[TTS]I changed **two** files; see [the diff](https://example.com) and `main.swift`.[/TTS]"),
            "I changed two files; see the diff and main.swift.")
        XCTAssertEqual(speech("[TTS]Here it is:\n```\nrm -rf build\n```\n[/TTS]"), "Here it is: See the code below.")
    }

    func testANestedOpenMarkerDoesNotShow() {
        XCTAssertEqual(speech("[TTS]one [TTS]two[/TTS]"), "one two")
    }

    // MARK: prose

    func testCodeBlocksAreNeverReadAloud() {
        let reply = """
            Run this:

            ```bash
            swift test --filter Speakable
            ```

            Then check the output.
            """
        let spoken = speech(reply)
        XCTAssertEqual(spoken, "Run this: See the code below. Then check the output.")
        XCTAssertFalse(spoken.contains("swift test"))
    }

    func testAnUnclosedFenceIsCodeToo() {
        XCTAssertEqual(speech("Starting:\n```python\nprint('hi')"), "Starting: See the code below.")
    }

    func testRepeatedPointersCollapseOnlyWhenNextToEachOther() {
        let adjacent = "Two files:\n\n```\na\n```\n\n```\nb\n```"
        XCTAssertEqual(speech(adjacent), "Two files: See the code below.")
        let apart = "First:\n\n```\na\n```\n\nSecond:\n\n```\nb\n```"
        XCTAssertEqual(speech(apart), "First: See the code below. Second: See the code below.")
        let mixed = "```\na\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |"
        XCTAssertEqual(speech(mixed), "See the code below. See the table below.")
    }

    func testTablesBecomeAPointer() {
        let reply = """
            The numbers:

            | Name | Count |
            | --- | ---: |
            | apples | 3 |
            | pears | 5 |

            That's all.
            """
        XCTAssertEqual(speech(reply), "The numbers: See the table below. That's all.")
    }

    func testLinksSpeakTheirTextAndInlineCodeItsText() {
        XCTAssertEqual(
            speech("Read [the guide](https://example.com/guide) and run `make test` first."),
            "Read the guide and run make test first.")
    }

    func testHeadingsAndListItemsEndAsSentences() {
        let reply = """
            ## What changed

            - **Header** now sticks
            - Search narrows the list.
            1. First step
            """
        XCTAssertEqual(speech(reply), "What changed. Header now sticks. Search narrows the list. First step.")
    }

    func testNestedListsReadInOrder() {
        let reply = """
            Plan:

            - Parse the reply
              - find the markers
              - drop the code
            - Speak it
            """
        XCTAssertEqual(speech(reply), "Plan: Parse the reply. find the markers. drop the code. Speak it.")
    }

    func testCodeUnderAListItemIsAPointer() {
        let reply = """
            1. Install it:
               ```
               bin/install
               ```
            2. Open the app
            """
        XCTAssertEqual(speech(reply), "Install it: See the code below. Open the app.")
    }

    func testQuotesAreSpokenAndRulesAreSilent() {
        XCTAssertEqual(speech("> Quoted line\n\n---\n\nAfter."), "Quoted line After.")
    }

    func testLineBreaksInsideAParagraphAreOneSpace() {
        XCTAssertEqual(speech("one\ntwo   three"), "one two three")
    }

    func testNothingToSay() {
        XCTAssertEqual(speech(""), "")
        XCTAssertEqual(speech("---"), "")
    }

    // MARK: drawn

    func testTheTagsAreRemovedFromWhatIsDrawnAndTheTextStays() {
        XCTAssertEqual(SpeakableText.displayed("Hi. [TTS]Done.[/TTS] Bye."), "Hi. Done. Bye.")
        XCTAssertEqual(SpeakableText.displayed("[tts]a[/TTS] [TTS]b"), "a b")
        XCTAssertEqual(SpeakableText.displayed("No markers here [x]"), "No markers here [x]")
    }

    func testTagsOnTheirOwnLinesLeaveTheBlocksAsTheyWere() {
        let drawn = SpeakableText.displayed("Intro.\n\n[TTS]\nSummary line.\n[/TTS]\n\n- item")
        let blocks = MarkdownParser.parse(drawn)
        XCTAssertEqual(
            blocks,
            [.paragraph("Intro."), .paragraph("Summary line."), .list([MarkdownListItem(level: 0, number: nil, text: "item")])])
    }
}
