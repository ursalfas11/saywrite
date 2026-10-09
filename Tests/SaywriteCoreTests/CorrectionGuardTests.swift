import XCTest
@testable import SaywriteCore

/// Gate false positives and misses, and the structure checks on the model's answer to a correction.
final class CorrectionGuardTests: XCTestCase {

    private func corrects(_ sentence: String, after previous: String? = nil, _ language: DictationLanguage = .german) -> Bool {
        CleanupGate.correctsPrevious(sentence, previous: previous, language: language)
    }

    private func decides(_ text: String, _ language: DictationLanguage = .german) -> Bool {
        CleanupGate.decide(raw: text, style: .neutral, language: language).usesLLM
    }

    func testExclamationsAfterOhAreNotCorrections() {
        XCTAssertFalse(corrects("Oh nein, das Backup fehlt auch.", after: "Der Server ist ausgefallen."))
        XCTAssertFalse(corrects("Also nein, das geht nicht.", after: "Kannst du morgen?"))
        XCTAssertFalse(corrects("Ach nein, mein Handy ist weg.", after: "Ich bin da."))
        XCTAssertFalse(corrects("Oh no, the backup is gone too.", after: "The server crashed.", .english))
        XCTAssertTrue(corrects("Ach nein, Hauptstraße 21.", after: "Die Adresse ist Hauptstraße 12."))
        XCTAssertTrue(corrects("Oder nein, ich komme doch.", after: "Ich bleibe hier."))
        XCTAssertTrue(corrects("Oh no, at six.", after: "Let's meet at five.", .english))
    }

    func testPronounAfterMarkerIsACorrection() {
        XCTAssertTrue(decides("Der Termin ist am Dienstag, nein, es ist Mittwoch."))
        XCTAssertTrue(decides("Ruf Anna an, nein, ich rufe sie selbst an."))
        XCTAssertTrue(decides("The deadline is Friday, no, it's Thursday.", .english))
        XCTAssertTrue(decides("It's on the 3rd, no wait, the 4th.", .english))
        XCTAssertTrue(corrects("Moment, ich rufe dich lieber an.", after: "Ich schreibe dir später."))
        // Quotations and answers stay.
        XCTAssertFalse(decides("Er sagte, nein, das mache ich nicht."))
        XCTAssertFalse(decides("He said, no, I won't do that.", .english))
        XCTAssertFalse(corrects("Moment, ich komme gleich.", after: "Wartest du?"))
    }

    func testOrdinaryMomentAndYesNoMaybeStay() {
        XCTAssertFalse(decides("Hallo, Moment, ich komme gleich."))
        XCTAssertFalse(decides("Ja, nein, vielleicht, ich weiß nicht."))
        XCTAssertFalse(decides("Yes, no, maybe, I honestly don't know yet.", .english))
        XCTAssertTrue(decides("Bring bitte 2 Flaschen Wasser, Moment, 3 Flaschen Wasser mit."))
    }

    func testBareNeinNeedsTheSlotOfThePreviousSentence() {
        XCTAssertFalse(corrects("Nein, in Berlin regnet es.", after: "Wie ist das Wetter?"))
        XCTAssertFalse(corrects("Nein, für mich nicht.", after: "Möchtest du Kaffee?"))
        XCTAssertTrue(corrects("Nein, um sechs.", after: "Ich komme um fünf."))
        XCTAssertTrue(corrects("Nein, am Dienstag.", after: "Treffen wir uns Montag?"))
        XCTAssertTrue(corrects("No, at six.", after: "Let's meet at five.", .english))
        XCTAssertFalse(corrects("No, in Berlin it rains.", after: "How is the weather?", .english))
    }

    private func accepts(_ input: String, _ output: String, _ language: DictationLanguage = .german) -> Bool {
        DictationSession.acceptsCorrection(input, output, language)
    }

    func testStartAndEndOfTheSentenceMustSurvive() {
        let input = "Bring bitte 2 Flaschen Wasser, Moment, 3 Flaschen Wasser mit."
        XCTAssertFalse(accepts(input, "3 Flaschen Wasser mit."))
        XCTAssertFalse(accepts(input, "Bring bitte 3 Flaschen Wasser."))
        XCTAssertTrue(accepts(input, "Bring bitte 3 Flaschen Wasser mit."))
        XCTAssertTrue(accepts("Ruf mich morgen an, also nein, übermorgen.", "Ruf mich übermorgen an."))
        XCTAssertTrue(accepts("Schick es an Mark, sorry, Mike.", "Schick es an Mike."))
        // Two corrections: the first old value may be gone.
        XCTAssertTrue(accepts(
            "Ich brauche den Bericht bis Montag, nein, bis Dienstag, und die Präsentation bis Mittwoch, ich meine Donnerstag.",
            "Ich brauche den Bericht bis Dienstag, und die Präsentation bis Donnerstag."))
    }

    func testInventedMovedOrMarkerKeepingAnswersAreRefused() {
        XCTAssertFalse(accepts("The wall is blue, or rather green.", "The color is blue, or green.", .english))
        XCTAssertTrue(accepts("The wall is blue, or rather green.", "The wall is green.", .english))
        XCTAssertFalse(accepts("Invite Sarah, actually, invite Mike instead.", "Actually, invite Mike instead.", .english))
        XCTAssertFalse(accepts("Two coffees, make that three.", "Two coffees, make it three.", .english))
        XCTAssertTrue(accepts("Two coffees, make that three.", "Three coffees.", .english))
        XCTAssertFalse(accepts(
            "I checked the numbers, actually, in March the revenue was higher.",
            "In March the revenue was higher, actually, I checked the numbers.", .english))
        XCTAssertTrue(accepts("Nimm den roten Pullover, oder besser den blauen.", "Nimm den blauen Pullover."))
    }

    func testSpokenNumbersCountLikeDigits() {
        // The old number stays next to the new one, spoken or written.
        XCTAssertFalse(accepts("Ich komme um fünf, nein, um sechs.", "Ich komme um 5 und um sechs."))
        XCTAssertTrue(accepts("Ich komme um fünf, nein, um sechs.", "Ich komme um 6."))
        XCTAssertFalse(accepts("Ich komme um fünf, nein, um sechs.", "Ich komme um fünf."))
        XCTAssertTrue(DictationSession.keepsCorrectedNumbers("Ich komme um fünf, nein, um sechs.", "Ich komme um 6.", .german))
    }

    func testSanitizeKeepsQuotesThatBelongToTheText() {
        XCTAssertEqual(LLMOutputGuard.sanitize("„Ich komme.“ „Wann?“"), "„Ich komme.“ „Wann?“")
        XCTAssertEqual(LLMOutputGuard.sanitize("„Hallo Welt.“"), "Hallo Welt.")
        XCTAssertEqual(LLMOutputGuard.sanitize("\"Hallo Welt.\"", input: "\"Hallo Welt.\""), "\"Hallo Welt.\"")
        XCTAssertEqual(LLMOutputGuard.sanitize("\"Hallo Welt.\"", input: "Hallo Welt."), "Hallo Welt.")
    }

    func testBreakerTripsOnMissingModelAndServerErrors() {
        for error in [LLMError.http(404), .http(500), .http(503), .badResponse, .timeout, .unreachable] {
            let breaker = LLMCircuitBreaker()
            breaker.record(error)
            XCTAssertTrue(breaker.isOpen, "\(error)")
        }
        for error in [LLMError.http(400), .http(429), .rejectedOutput] {
            let breaker = LLMCircuitBreaker()
            breaker.record(error)
            XCTAssertFalse(breaker.isOpen, "\(error)")
        }
    }

    func testDebugLogLeavesOutTheTextByDefault() {
        // SAYWRITE_DEBUG_TEXT is not set in the test run.
        guard !Debug.textEnabled else { return }
        XCTAssertEqual(Debug.text("Mein Geheimnis"), "<14 chars>")
    }
}
