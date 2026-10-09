import XCTest
@testable import SaywriteCore

/// Findings of review round 5.
final class ReviewRound5FindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true; DictationLanguage.lastDetected = nil }
    override func tearDown() { UILanguage.override = nil; DictationLanguage.lastDetected = nil }

    func testPrepositionPrefixesAreNoCorrection() {
        for text in ["Sie wollte um 5 kommen, sorry, aber sie hat abgesagt.",
                     "Ich schaffe es heute nicht. Sorry, aber ich habe noch zu tun.",
                     "Moment, aber wir haben sie doch schon bezahlt.",
                     "Das ist wichtig, sorry, anscheinend fehlt etwas."] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral).usesLLM, text)
        }
        for text in ["Actually, today is Friday so I will send it later.",
                     "I was busy, sorry, only now I have time.",
                     "Wait, only the first one is ready."] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral, language: .english).usesLLM, text)
        }
        XCTAssertTrue(CleanupGate.decide(raw: "Wir treffen uns um fünf, sorry, um sechs.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "Let's meet at five, sorry, at six.", style: .neutral, language: .english).usesLLM)
    }

    func testDontForgetItIsNoCorrection() {
        for text in ["Bring the keys tomorrow and please don't forget it. The door is locked at six.",
                     "Please do not forget that, it matters.", "You should never forget it!"] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral, language: .english).usesLLM, text)
        }
        XCTAssertTrue(CleanupGate.decide(raw: "Send the file to Mark. Forget it, I'll do it myself.", style: .neutral, language: .english).usesLLM)
    }

    func testGuardRejectsAnswerThatKeepsTheOldValue() {
        let input = "Morgen früh, nein, übermorgen früh geht es weiter."
        XCTAssertFalse(DictationSession.keepsCorrectedNumbers(input, "Morgen früh geht es weiter.", .german))
        XCTAssertTrue(DictationSession.keepsCorrectedNumbers(input, "Übermorgen früh geht es weiter.", .german))
    }

    func testEnglishFillersDoNotEatGermanWordsAfterEnglishDictation() {
        DictationLanguage.lastDetected = .english
        for text in ["Treffen um 10 Uhr bei Anna.", "Er kommt um 9, Anna um 10.", "Termin um 14:30 Uhr, Raum 5, Frau Müller."] {
            XCTAssertEqual(DictationLanguage.resolve(setting: "auto", text: text), .german, text)
        }
    }

    func testSentenceEndingNamesKeepTheCapitalAfterAFiller() {
        XCTAssertEqual(RuleCleaner.finalize(RuleCleaner.clean("Hallo Max. Ähm wie geht es dir?"), style: .neutral), "Hallo Max. Wie geht es dir?")
        XCTAssertEqual(RuleCleaner.finalize(RuleCleaner.clean("Ich arbeite bei der Müller GmbH. Ähm, bitte ruf mich an."), style: .neutral),
                       "Ich arbeite bei der Müller GmbH. Bitte ruf mich an.")
    }

    func testDateBeforeCapitalizedOpenerEndsTheSentence() {
        XCTAssertFalse(RuleCleaner.isNonTerminalPeriod("13.5.", following: " Bitte alle einladen."))
        XCTAssertTrue(RuleCleaner.isNonTerminalPeriod("13.5.", following: " Dienstag"))
    }

    func testTerminalPeriodAfterSymbols() {
        XCTAssertEqual(RuleCleaner.ensureTerminalPunctuation("Das kostet 20 %", style: .neutral), "Das kostet 20 %.")
        XCTAssertEqual(RuleCleaner.ensureTerminalPunctuation("Das kostet 5 €", style: .neutral), "Das kostet 5 €.")
    }

    func testOllamaContextIsSizedToTheRequest() {
        XCTAssertEqual(OllamaClient.contextSize(promptCharacters: 600, maxTokens: 150), 4096)
        XCTAssertEqual(OllamaClient.contextSize(promptCharacters: 24_700, maxTokens: 24_700), 32768)
        XCTAssertNil(OllamaClient.contextSize(promptCharacters: 80_000, maxTokens: 80_000))
        let full = Data(#"{"message":{"content":"Eintrag 400"},"done_reason":"stop","prompt_eval_count":4090}"#.utf8)
        XCTAssertThrowsError(try OllamaClient.parseChatResponse(full, contextSize: 4096)) { XCTAssertEqual($0 as? LLMError, .tooLong) }
        let fine = Data(#"{"message":{"content":"Ok"},"done_reason":"stop","prompt_eval_count":300}"#.utf8)
        XCTAssertEqual(try OllamaClient.parseChatResponse(fine, contextSize: 4096), "Ok")
    }
}
