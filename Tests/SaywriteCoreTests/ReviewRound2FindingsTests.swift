import XCTest
@testable import SaywriteCore

/// Findings of review round 2.
final class ReviewRound2FindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    // MARK: "I mean," as filler

    func testEnglishFillerIMeanIsNoCorrection() {
        for sentence in ["I mean, she had a train to catch.", "I mean, he tried hard for months.", "I mean, the weather was bad.",
                         "I mean, there was nothing else to do.", "I mean, my sister knows him."] {
            XCTAssertFalse(CleanupGate.startsWithCorrection(sentence, language: .english), sentence)
            XCTAssertFalse(CleanupGate.correctsPrevious(sentence, previous: "She left early.", language: .english), sentence)
        }
    }

    func testEnglishIMeanStillCorrectsWithEvidence() {
        XCTAssertTrue(CleanupGate.startsWithCorrection("I mean at nine.", language: .english))
        XCTAssertTrue(CleanupGate.startsWithCorrection("I mean Tuesday.", language: .english))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Sorry, I mean the red one.", language: .english))
        XCTAssertTrue(CleanupGate.correctsPrevious(
            "I mean, we should order three large pizzas.", previous: "We should order two large pizzas.", language: .english))
    }

    func testGermanIchMeineWithArticleIsNoCorrection() {
        for sentence in ["Ich meine, die Lösung ist gut.", "Ich meine, der Plan klingt vernünftig.", "Ich meine, den Weg kenne ich."] {
            XCTAssertFalse(CleanupGate.startsWithCorrection(sentence), sentence)
        }
        XCTAssertTrue(CleanupGate.startsWithCorrection("Ich meine am Dienstag."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Ich meine Paul."))
    }

    // MARK: English corrections

    func testEnglishDeterminerRepeatAndMakeThat() {
        for text in ["I want the red one, no, the blue one, please.", "Get a coffee, no, a tea.",
                     "Let's meet Monday, make that Tuesday.", "Two coffees, make that three."] {
            XCTAssertTrue(CleanupGate.decide(raw: text, style: .neutral, language: .english).usesLLM, text)
        }
        for text in ["Do your best, make it work.", "I said no, the answer is final.", "He asked, no, the other way round was meant."] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral, language: .english).usesLLM, text)
        }
    }

    // MARK: Spelling and enumerations

    func testSpelledLettersKeepDoubles() {
        XCTAssertEqual(RuleCleaner.collapseStutter("Müller mit Ü, M Ü L L E R"), "Müller mit Ü, M Ü L L E R")
        XCTAssertEqual(RuleCleaner.collapseStutter("Code B B 7"), "Code B B 7")
        XCTAssertEqual(RuleCleaner.collapseStutter("I I think so", language: .english), "I think so")
        XCTAssertEqual(RuleCleaner.collapseStutter("Das ist ist gut"), "Das ist gut")
    }

    func testFillerInEnumerationKeepsTheListComma() {
        XCTAssertEqual(RuleCleaner.removeFillers("Ich brauche Äpfel, äh, Birnen und Bananen."), "Ich brauche Äpfel, Birnen und Bananen.")
        XCTAssertEqual(RuleCleaner.removeFillers("Wir haben Rot, Grün, ähm, Blau und Gelb."), "Wir haben Rot, Grün, Blau und Gelb.")
        XCTAssertEqual(RuleCleaner.removeFillers("Ich habe das gestern, äh, gemacht."), "Ich habe das gestern gemacht.")
    }

    // MARK: Backend choice, Ollama parsing

    func testUpgraderWithoutModelKeepsOllama() {
        XCTAssertEqual(LLMBackend.resolveAtLaunch(stored: nil, modelInstalled: false, usedEarlierVersion: true), .ollama)
        XCTAssertEqual(LLMBackend.resolveAtLaunch(stored: nil, modelInstalled: true, usedEarlierVersion: true), .builtin)
        XCTAssertEqual(LLMBackend.resolveAtLaunch(stored: nil, modelInstalled: false, usedEarlierVersion: false), .builtin)
        XCTAssertEqual(LLMBackend.resolveAtLaunch(stored: "builtin", modelInstalled: false, usedEarlierVersion: true), .builtin)
        XCTAssertEqual(LLMBackend.resolveAtLaunch(stored: "ollama", modelInstalled: true, usedEarlierVersion: false), .ollama)
    }

    func testOllamaTruncatedAnswerIsRejected() throws {
        let cut = Data(#"{"message":{"content":"Half a sen"},"done_reason":"length"}"#.utf8)
        XCTAssertThrowsError(try OllamaClient.parseChatResponse(cut)) { XCTAssertEqual($0 as? LLMError, .rejectedOutput) }
        let whole = Data(#"{"message":{"content":"Done."},"done_reason":"stop"}"#.utf8)
        XCTAssertEqual(try OllamaClient.parseChatResponse(whole), "Done.")
    }
}
