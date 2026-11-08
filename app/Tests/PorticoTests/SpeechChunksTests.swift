import XCTest
@testable import Portico

/// v0.26 (PORT-23): a reply cut for ElevenLabs, in order, nothing lost.
final class SpeechChunksTests: XCTestCase {
    private func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }

    func testParagraphsPackUnderTheLimit() {
        let text = "One two.\n\nThree four.\n\nFive six seven eight."
        XCTAssertEqual(SpeechChunks.split(text, limit: 100), ["One two.\n\nThree four.\n\nFive six seven eight."])
        XCTAssertEqual(SpeechChunks.split(text, limit: 22), ["One two.\n\nThree four.", "Five six seven eight."])
        XCTAssertEqual(SpeechChunks.split(text, limit: 21), ["One two.\n\nThree four.", "Five six seven eight."])
        XCTAssertEqual(SpeechChunks.split(text, limit: 20), ["One two.", "Three four.", "Five six seven", "eight."])
    }

    func testAParagraphOverTheLimitSplitsAtSentencesThenWords() {
        let sentence = "This is a sentence that runs on for a while"
        let text = (1...30).map { "\(sentence) number \($0)." }.joined(separator: " ")
            + " " + String(repeating: "word ", count: 60) + "Supercalifragilisticexpialidocious!"
        for limit in [20, 40, 120, 500] {
            let chunks = SpeechChunks.split(text, limit: limit)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= limit }, "limit \(limit)")
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty })
            if limit >= 40 { XCTAssertEqual(words(chunks.joined(separator: " ")), words(text), "limit \(limit)") }
        }
        // Sentence ends are preferred when they fit.
        let two = SpeechChunks.split("Alpha beta. Gamma delta.", limit: 15)
        XCTAssertEqual(two, ["Alpha beta.", "Gamma delta."])
        // A word longer than the limit is cut hard; nothing is lost.
        let hard = SpeechChunks.split("abcdefghij", limit: 4)
        XCTAssertEqual(hard, ["abcd", "efgh", "ij"])
    }

    func testEmptyTextHasNoChunks() {
        XCTAssertEqual(SpeechChunks.split("", limit: 100), [])
        XCTAssertEqual(SpeechChunks.split("  \n\n \n", limit: 100), [])
    }

    /// Review L2: a real reply, through `SpeakableText` as ElevenLabs gets it, splits at its
    /// paragraphs (whole paragraphs packed under the limit); one paragraph over the limit
    /// splits at sentence ends, then at spaces.
    func testARepliesParagraphsAreTheSplitPoints() {
        let reply = """
        # Plan

        First paragraph, with **bold** words.

        Second paragraph says more.

        - an item
        - another item

        ```
        code here
        ```
        """
        let speech = SpeakableText.speech(fromMarkdown: reply, paragraphs: true)
        XCTAssertEqual(speech, "Plan.\n\nFirst paragraph, with bold words.\n\nSecond paragraph says more.\n\nan item.\n\nanother item.\n\nSee the code below.")
        XCTAssertEqual(SpeechChunks.split(speech, limit: 40),
                       ["Plan.\n\nFirst paragraph, with bold words.", "Second paragraph says more.\n\nan item.",
                        "another item.\n\nSee the code below."])
        // The Mac voice's text is unchanged: one line.
        XCTAssertFalse(SpeakableText.speech(fromMarkdown: reply).contains("\n"))
        let long = "One sentence here. Another one follows here. And a third."
        XCTAssertEqual(SpeechChunks.split(SpeakableText.speech(fromMarkdown: long, paragraphs: true), limit: 30),
                       ["One sentence here.", "Another one follows here.", "And a third."])
    }
}
