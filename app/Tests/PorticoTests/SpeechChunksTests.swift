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
}
