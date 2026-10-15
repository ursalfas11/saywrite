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

    // MARK: Saved prompt prefixes

    func testPrefixIsTheStartOfThePrompt() {
        let prompt = ChatTemplate.qwen(system: "System", user: "Text")
        XCTAssertTrue(prompt.hasPrefix(ChatTemplate.prefix(system: "System")))
        XCTAssertEqual(prompt, ChatTemplate.prefix(system: "System") + "Text<|im_end|>\n<|im_start|>assistant\n")
    }

    func testRestoresTheLongestSavedPrefixWorthIt() {
        var snapshots = PrefixSnapshots<String>(capacity: 4)
        snapshots.store([1, 2], "short")
        snapshots.store([1, 2, 3, 4], "long")
        snapshots.store([7, 8, 9], "other")
        XCTAssertEqual(snapshots.restorable(for: [1, 2, 3, 4, 5, 6], keep: 0)?.state, "long")
        // The cache already shares more than any saved prefix: nothing to restore.
        XCTAssertNil(snapshots.restorable(for: [1, 2, 3, 4, 5, 6], keep: 4))
        XCTAssertEqual(snapshots.restorable(for: [1, 2, 9, 9], keep: 1)?.state, "short")
        XCTAssertEqual(snapshots.restorable(for: [7, 8, 9, 1], keep: 0)?.state, "other")
        // A prefix as long as the whole prompt leaves no token to decode for the logits.
        XCTAssertNil(snapshots.restorable(for: [7, 8, 9], keep: 0))
        XCTAssertNil(snapshots.restorable(for: [5, 6, 7], keep: 0))
    }

    func testSnapshotsDropTheLeastRecentlyUsed() {
        var snapshots = PrefixSnapshots<Int>(capacity: 2)
        snapshots.store([1], 1)
        snapshots.store([2], 2)
        // Using [1] makes [2] the oldest.
        XCTAssertEqual(snapshots.restorable(for: [1, 0], keep: 0)?.state, 1)
        snapshots.store([3], 3)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.contains([1]))
        XCTAssertFalse(snapshots.contains([2]))
        XCTAssertTrue(snapshots.contains([3]))
        // Storing the same prefix again replaces it.
        snapshots.store([3], 30)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.restorable(for: [3, 0], keep: 0)?.state, 30)
        snapshots.removeAll()
        XCTAssertEqual(snapshots.count, 0)
    }

    // MARK: Engine settings

    func testShortResidencyOnlyOnSmallMacs() {
        XCTAssertEqual(EngineTuning.residencyKeepAlive(physicalMemory: 8 << 30), 30)
        XCTAssertEqual(EngineTuning.residencyKeepAlive(physicalMemory: 4 << 30), 30)
        XCTAssertNil(EngineTuning.residencyKeepAlive(physicalMemory: 16 << 30))
    }

    // MARK: Early word check

    func testWordGuardAllowsPunctuationAndCapitalization() {
        let guardian = WordPrefixGuard(input: "ich komme morgen um drei uhr")
        XCTAssertTrue(guardian.allows(""))
        XCTAssertTrue(guardian.allows("Ich"))
        XCTAssertTrue(guardian.allows("Ich ko"))
        XCTAssertTrue(guardian.allows("Ich komme morgen, um"))
        XCTAssertTrue(guardian.allows("Ich komme morgen um drei Uhr."))
    }

    func testWordGuardStopsChangedMissingOrExtraWords() {
        let guardian = WordPrefixGuard(input: "ich komme morgen um drei uhr")
        XCTAssertFalse(guardian.allows("Ich kam "))
        XCTAssertFalse(guardian.allows("Ich komme um"))
        XCTAssertFalse(guardian.allows("Ich komme morgen um 3"))
        XCTAssertFalse(guardian.allows("Ich komme morgen um drei Uhr. Gerne"))
        // An unfinished word that cannot become the next input word.
        XCTAssertFalse(guardian.allows("Ich kx"))
    }

    func testWordGuardIgnoresWhatSanitizeRemoves() {
        let guardian = WordPrefixGuard(input: "das ist gut")
        XCTAssertTrue(guardian.allows("<diktat>\nDas ist"))
        XCTAssertTrue(guardian.allows("-> Das ist gut"))
        XCTAssertTrue(guardian.allows("„Das ist gut.“"))
        XCTAssertTrue(guardian.allows("Das ist gut.\n</dik"))
        XCTAssertTrue(guardian.allows("Das ist gut.\n</diktat>"))
    }

    func testWordGuardIsNeverStricterThanSameWords() {
        let pairs = [
            ("das kostet 5 € pro stück", "Das kostet 5 € pro Stück."),
            ("treffen wir uns um 10:30", "Treffen wir uns um 10:30?"),
            ("die e-mail an herrn müller", "Die E-Mail an Herrn Müller."),
            ("we'll meet at the café", "We'll meet at the café."),
        ]
        for (input, output) in pairs {
            XCTAssertTrue(LLMOutputGuard.sameWords(input, output))
            let guardian = WordPrefixGuard(input: input)
            // Every prefix of an accepted answer passes, character by character.
            var partial = ""
            for character in output {
                partial.append(character)
                XCTAssertTrue(guardian.allows(partial), "\(input) -> \(partial)")
            }
        }
    }

    func testSessionAsksForKeptWordsOnlyWithoutACorrection() async {
        let llm = WordFlagLLM()
        let plain = DictationSession(
            // More than 25 words without punctuation: the model adds the commas.
            transcriber: FakeTranscriber(texts: [1: "ich wollte Ihnen nur kurz mitteilen dass wir die Unterlagen wie vereinbart bis Ende der Woche prüfen werden und die Antwort dann direkt im Anschluss an Sie per Post senden"]),
            llm: llm, style: .formal, appBundleID: nil)
        await plain.addSegment([1])
        _ = await plain.finish()
        let corrected = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Wir treffen uns um drei, nein, um vier."]), llm: llm, style: .neutral, appBundleID: nil)
        await corrected.addSegment([1])
        _ = await corrected.finish()
        let flags = await llm.log.flags
        XCTAssertEqual(flags, [true, false])
    }
}

actor FlagLog {
    var flags: [Bool] = []
    func record(_ flag: Bool) { flags.append(flag) }
}

/// Records whether the session asked for an answer with the input's words.
struct WordFlagLLM: LLMClient {
    let log = FlagLog()
    func prewarm(forRewrite: Bool) async {}
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String { text }
    func cleanup(text: String, style: Style, language: DictationLanguage, keepingWords: Bool) async throws -> String {
        await log.record(keepingWords)
        return text
    }
    func rewrite(selection: String, instruction: String) async throws -> String { selection }
}
