import XCTest
@testable import SaywriteCore

/// The pure parts of the faster built-in engine (round 4): prompt lookup, the early word check,
/// the saved prompt prefixes, the prewarm after an update and Ollama's context estimate.
final class EngineSpeedupTests: XCTestCase {
    // MARK: Prompt lookup

    func testDraftContinuesTheLongestMatchingTail() {
        let source: [Int32] = [1, 2, 3, 4, 5, 6, 7]
        XCTAssertEqual(PromptLookup.draft(generated: [9, 2, 3], source: source, limit: 3), [4, 5, 6])
        // Only the last token matches: n falls back to 1.
        XCTAssertEqual(PromptLookup.draft(generated: [9, 9, 5], source: source, limit: 8), [6, 7])
        // The limit caps the draft.
        XCTAssertEqual(PromptLookup.draft(generated: [1], source: source, limit: 2), [2, 3])
    }

    func testDraftPrefersTheLatestMatch() {
        // "2" appears twice; the later place in the source is taken.
        XCTAssertEqual(PromptLookup.draft(generated: [2], source: [2, 10, 11, 2, 20, 21], limit: 2), [20, 21])
        // A longer tail wins over a later single-token match.
        XCTAssertEqual(PromptLookup.draft(generated: [1, 2], source: [1, 2, 10, 5, 2, 20], limit: 1), [10])
    }

    func testDraftIsEmptyWithoutMatchOrRoom() {
        XCTAssertEqual(PromptLookup.draft(generated: [42], source: [1, 2, 3], limit: 8), [])
        // A match at the very end has nothing after it.
        XCTAssertEqual(PromptLookup.draft(generated: [3], source: [1, 2, 3], limit: 8), [])
        XCTAssertEqual(PromptLookup.draft(generated: [1], source: [1, 2, 3], limit: 0), [])
        XCTAssertEqual(PromptLookup.draft(generated: [], source: [1, 2, 3], limit: 8), [])
        XCTAssertEqual(PromptLookup.draft(generated: [1], source: [], limit: 8), [])
    }

    func testAcceptKeepsTheConfirmedPrefixAndTheModelsNextToken() {
        let end: Int32 = 99
        // The model agrees with the first two guesses and then predicts 7.
        var asked: [Int] = []
        let predictions: [Int32] = [4, 5, 7, 6]
        let result = PromptLookup.accept(draft: [4, 5, 6], isEnd: { $0 == end }) { asked.append($0); return predictions[$0] }
        XCTAssertEqual(result.accepted, 2)
        XCTAssertEqual(result.next, 7)
        // Positions after the first mismatch are not looked at.
        XCTAssertEqual(asked, [0, 1, 2])
    }

    func testAcceptAllAndEmptyDraft() {
        let all = PromptLookup.accept(draft: [4, 5], isEnd: { _ in false }) { [4, 5, 8][$0] }
        XCTAssertEqual(all.accepted, 2)
        XCTAssertEqual(all.next, 8)
        let none = PromptLookup.accept(draft: [], isEnd: { _ in false }) { _ in 3 }
        XCTAssertEqual(none.accepted, 0)
        XCTAssertEqual(none.next, 3)
    }

    func testAcceptStopsAtTheEndToken() {
        // A guessed end token is never taken over: the answer ends with it as the next token.
        let result = PromptLookup.accept(draft: [4, 99, 5], isEnd: { $0 == 99 }) { [4, 99, 5, 6][$0] }
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.next, 99)
    }
}
