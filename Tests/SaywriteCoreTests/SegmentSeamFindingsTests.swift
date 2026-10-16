import XCTest
@testable import SaywriteCore

/// Findings of the review of PR #14 on joining segments and the word guard.
final class SegmentSeamFindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true; DictationLanguage.lastDetected = nil }
    override func tearDown() { UILanguage.override = nil; DictationLanguage.lastDetected = nil }

    /// Segments as the recognizer returns them; a leading "+" marks a cut without a pause.
    private func dictate(_ segments: [String], language: String = "auto") async -> DictationResult? {
        let texts = Dictionary(uniqueKeysWithValues: segments.enumerated().map {
            ($0.offset, $0.element.hasPrefix("+") ? String($0.element.dropFirst()) : $0.element)
        })
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: texts), llm: nil, style: .neutral, appBundleID: nil, language: language)
        for (index, segment) in segments.enumerated() {
            await session.addSegment(AudioSegment(samples: [Float(index)], continuesPrevious: segment.hasPrefix("+")))
        }
        return await session.finish()
    }

    // MARK: P1 A filler at the start of a segment starts a new sentence

    func testLeadingFillerStartsANewSentence() {
        XCTAssertFalse(DictationSession.startsMidSentence("ähm, ich schicke ihn morgen.", after: "Der Bericht ist fertig."))
        XCTAssertFalse(DictationSession.startsMidSentence("äh das passt so.", after: "Der Bericht ist fertig."))
        XCTAssertFalse(DictationSession.startsMidSentence("um, we send it tomorrow.", after: "The report is done.", language: .english))
        XCTAssertFalse(DictationSession.startsMidSentence("uh, we send it tomorrow.", after: "The report is done.", language: .english))
        // "um" and "er" are German words: no filler in German.
        XCTAssertTrue(DictationSession.startsMidSentence("um zehn Uhr am Bahnhof.", after: "Wir treffen uns morgen.", language: .german))
        XCTAssertTrue(DictationSession.startsMidSentence("und schicke ihn dann weiter.", after: "Bitte prüfe den Bericht.", language: .german))
    }

    func testSegmentAfterAPauseWithLeadingFillerStaysApart() async {
        let german = await dictate(["Der Bericht ist fertig.", "ähm, ich schicke ihn morgen."])
        XCTAssertEqual(german?.final, "Der Bericht ist fertig. Ich schicke ihn morgen.")
        let english = await dictate(["The report is done.", "um, we send it tomorrow."], language: "en")
        XCTAssertEqual(english?.final, "The report is done. We send it tomorrow.")
        let time = await dictate(["Wir treffen uns morgen.", "um zehn Uhr am Bahnhof."], language: "de")
        XCTAssertEqual(time?.final, "Wir treffen uns morgen um zehn Uhr am Bahnhof.")
    }

    // MARK: P2 The period of an ordinal, date or abbreviation stays when segments are glued

    func testDropFalsePeriodKeepsNonTerminalPeriods() {
        XCTAssertEqual(DictationSession.dropFalsePeriod("Bitte prüfe den Bericht.", following: "und schicke ihn"), "Bitte prüfe den Bericht")
        XCTAssertEqual(DictationSession.dropFalsePeriod("Wir treffen uns am 15.", following: "um 10 Uhr"), "Wir treffen uns am 15.")
        XCTAssertEqual(DictationSession.dropFalsePeriod("Die Frist endet am 3.10.", following: "und nicht später"), "Die Frist endet am 3.10.")
        XCTAssertEqual(DictationSession.dropFalsePeriod("Sie wohnt in den U.S.A.", following: "und kommt im Mai"), "Sie wohnt in den U.S.A.")
        XCTAssertEqual(DictationSession.dropFalsePeriod("Wir treffen uns am 15.", following: "Oktober im Büro"), "Wir treffen uns am 15.")
        // A number before a sentence start keeps its period only as the end of that sentence.
        XCTAssertEqual(DictationSession.dropFalsePeriod("Ich komme um 5.", following: "Ich bringe Kuchen mit"), "Ich komme um 5")
        XCTAssertEqual(DictationSession.dropFalsePeriod("Es war still...", following: "und dann"), "Es war still...")
    }

    func testGluedSegmentsKeepTheOrdinalPeriod() async {
        let date = await dictate(["Wir treffen uns am 15.", "um 10 Uhr im Büro."])
        XCTAssertEqual(date?.final, "Wir treffen uns am 15. um 10 Uhr im Büro.")
        let short = await dictate(["Die Frist endet am 3.10.", "und nicht später."])
        XCTAssertEqual(short?.final, "Die Frist endet am 3.10. und nicht später.")
        let letters = await dictate(["Sie wohnt in den U.S.A.", "und kommt im Mai zurück."])
        XCTAssertEqual(letters?.final, "Sie wohnt in den U.S.A. und kommt im Mai zurück.")
        let cut = await dictate(["Wir treffen uns am 15.", "+Oktober im Büro."])
        XCTAssertEqual(cut?.final, "Wir treffen uns am 15. Oktober im Büro.")
        let plain = await dictate(["Bitte prüfe morgen den Bericht.", "und schicke ihn dann an das Team."])
        XCTAssertEqual(plain?.final, "Bitte prüfe morgen den Bericht und schicke ihn dann an das Team.")
    }

    func testCorrectionAfterAnOrdinalKeepsItsComma() {
        XCTAssertEqual(DictationSession.joinForCorrection("Wir treffen uns am 12.", "nein, am 13."), "Wir treffen uns am 12., nein, am 13.")
        XCTAssertEqual(DictationSession.joinForCorrection("Ich komme um fünf.", "Nein, um sechs."), "Ich komme um fünf. Nein, um sechs.")
        XCTAssertEqual(DictationSession.joinForCorrection("Ich komme um 5.", "Nein, um 6."), "Ich komme um 5. Nein, um 6.")
        XCTAssertEqual(DictationSession.joinForCorrection("am Donnerstag", "nein, am Freitag"), "am Donnerstag, nein, am Freitag")
    }

    // MARK: P3 "Er." is a German answer, "Um." a hesitation in both languages

    func testGermanOneWordAnswerIsNoFiller() async {
        let german = await dictate(["Er."], language: "de")
        XCTAssertEqual(german?.final, "Er.")
        let english = await dictate(["Er."], language: "en")
        XCTAssertNil(english)
        for language in ["de", "en", "auto"] {
            let um = await dictate(["Um."], language: language)
            XCTAssertNil(um, language)
        }
        XCTAssertTrue(DictationSession.onlyFillers("Ähm, äh.", language: .german))
        XCTAssertTrue(DictationSession.onlyFillers("Uh, er.", language: .english))
        XCTAssertFalse(DictationSession.onlyFillers("Er.", language: .german))
        XCTAssertFalse(DictationSession.onlyFillers("Äh, er.", language: .german))
    }

    // MARK: E3 The word guard compares accents canonically, like sameWords

    func testWordGuardAcceptsDecomposedAccents() {
        let decomposed = WordPrefixGuard(input: "Cafe\u{301} ist offen")
        XCTAssertTrue(decomposed.allows("Café"))
        XCTAssertTrue(decomposed.allows("Café ist"))
        XCTAssertTrue(decomposed.allows("Cafe"))
        let precomposed = WordPrefixGuard(input: "Café ist offen")
        XCTAssertTrue(precomposed.allows("Cafe\u{301} "))
        // The answer so far ends between the letter and its accent.
        XCTAssertTrue(precomposed.allows("Cafe"))
        XCTAssertTrue(WordPrefixGuard(input: "U\u{308}ber alles").allows("U"))
        XCTAssertTrue(WordPrefixGuard(input: "Über alles").allows("U"))
        XCTAssertTrue(WordPrefixGuard(input: "Über alles").allows("U\u{308}ber a"))
        XCTAssertFalse(WordPrefixGuard(input: "Über alles").allows("Ub"))
        XCTAssertFalse(WordPrefixGuard(input: "Über alles").allows("Uber "))
        XCTAssertFalse(precomposed.allows("Cafe "))
        XCTAssertTrue(LLMOutputGuard.sameWords("Cafe\u{301} ist offen", "Café ist offen."))
    }
}
