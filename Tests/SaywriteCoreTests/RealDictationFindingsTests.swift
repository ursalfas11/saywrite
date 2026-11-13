import XCTest
@testable import SaywriteCore

/// A model that answers with a fixed function of its input and records what it was given.
private struct RecordingLLM: LLMClient {
    let log = CallLog()
    let answer: @Sendable (String) -> String
    func prewarm(forRewrite: Bool) async {}
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String {
        await log.record(text)
        return answer(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func rewrite(selection: String, instruction: String) async throws -> String { selection }
}

/// Findings from real dictations (patterns rebuilt with neutral sentences).
final class RealDictationFindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true; DictationLanguage.lastDetected = nil }
    override func tearDown() { UILanguage.override = nil; DictationLanguage.lastDetected = nil }

    private func dictate(_ segments: [String], llm: LLMClient? = nil, style: Style = .neutral, language: String = "auto") async -> DictationResult? {
        let texts = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.offset, $0.element) })
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: texts), llm: llm, style: style, appBundleID: nil, language: language)
        for index in segments.indices { await session.addSegment([Float(index)]) }
        return await session.finish()
    }

    // MARK: B1 "Nein, ich meine, …" starts the sentence over

    func testNoIMeanCorrectsTheSentenceBefore() {
        let previous = "Ich brauche drei Ordner für das Büro."
        for lead in ["Nein", "Nee", "Oder nein", "Ach nee", "Aber nein"] {
            let sentence = "\(lead), ich meine, ich brauche vier Ordner für das Büro."
            XCTAssertTrue(CleanupGate.correctsPrevious(sentence, previous: previous), sentence)
        }
        let english = "I need three folders for the office."
        for lead in ["No", "Oh no"] {
            let sentence = "\(lead), I mean, I need four folders for the office."
            XCTAssertTrue(CleanupGate.correctsPrevious(sentence, previous: english, language: .english), sentence)
        }
    }

    func testNoIMeanAfterAQuestionIsAnAnswer() {
        XCTAssertFalse(CleanupGate.correctsPrevious(
            "Nein, ich meine, der Schlüssel liegt im Auto.", previous: "Hast du den Schlüssel gefunden?"))
        XCTAssertFalse(CleanupGate.correctsPrevious(
            "Nein, ich meine, die Farben sind zu dunkel.", previous: "Gefällt dir der Entwurf?"))
        XCTAssertFalse(CleanupGate.correctsPrevious(
            "No, I mean, the key is in the car.", previous: "Did you find the key?", language: .english))
        // Without a sentence before, nothing is corrected.
        XCTAssertFalse(CleanupGate.correctsPrevious("Nein, ich meine, ich brauche vier Ordner.", previous: nil))
    }

    func testLeadingNoIMeanAloneDoesNotGoToTheModel() {
        XCTAssertFalse(CleanupGate.decide(raw: "Nein, ich meine, der Schlüssel liegt im Auto.", style: .neutral).usesLLM)
        XCTAssertFalse(CleanupGate.decide(raw: "Sorry, ich meine, der Termin passt.", style: .neutral).usesLLM)
        // A correction later in the sentence still counts.
        XCTAssertTrue(CleanupGate.decide(raw: "Nein, ich meine, am Montag, nein, am Dienstag.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "Wir treffen uns um fünf, ich meine, um sechs.", style: .neutral).usesLLM)
    }

    func testNoIMeanAfterAPauseIsCorrectedWithTheSentenceBefore() async {
        let llm = RecordingLLM { text in
            text.contains("ich meine") ? "Ich brauche vier Ordner für das Büro." : text
        }
        let result = await dictate(["Ich brauche drei Ordner für das Büro.", "Nein, ich meine, ich brauche vier Ordner für das Büro."], llm: llm)
        XCTAssertEqual(result?.final, "Ich brauche vier Ordner für das Büro.")
        XCTAssertEqual(result?.summary.llmFailed, false)
        // One call with both sentences, none with the second one alone.
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["Ich brauche drei Ordner für das Büro. Nein, ich meine, ich brauche vier Ordner für das Büro."])
    }

    func testNoIMeanAnswerStaysAsSpoken() async {
        let llm = RecordingLLM { _ in "Der Schlüssel liegt im Auto." }
        let text = "Hast du den Schlüssel gefunden? Nein, ich meine, der Schlüssel liegt im Auto."
        let result = await dictate([text], llm: llm)
        XCTAssertEqual(result?.final, text)
        let calls = await llm.log.cleanups
        XCTAssertTrue(calls.isEmpty)
    }

    func testCorrectedTailFindsTheNewVersionAfterNoIMean() {
        let input = "Wir treffen uns um fünf Uhr am Bahnhof. Nee, ich meine, wir treffen uns um sechs Uhr am Bahnhof."
        XCTAssertEqual(CleanupGate.changedWords(in: input, language: .german), ["sechs"])
    }

    // MARK: B2 A lowercase segment after a pause continues the sentence

    func testStartsMidSentence() {
        XCTAssertTrue(DictationSession.startsMidSentence("und schicke ihn dann an das Team.", after: "Bitte prüfe morgen den Bericht."))
        XCTAssertTrue(DictationSession.startsMidSentence("brauche ich noch zwei Lampen.", after: "Für die neue Wohnung."))
        XCTAssertFalse(DictationSession.startsMidSentence("Und schicke ihn weiter.", after: "Bitte prüfe den Bericht."))
        XCTAssertFalse(DictationSession.startsMidSentence("und wann genau?", after: "Kommst du heute?"))
        XCTAssertFalse(DictationSession.startsMidSentence("und das war es.", after: "Achtung!"))
        XCTAssertFalse(DictationSession.startsMidSentence("und dann ging es weiter.", after: "Es war still..."))
        XCTAssertFalse(DictationSession.startsMidSentence("und noch Toner.", after: "Wir brauchen Stifte, Papier usw."))
        XCTAssertFalse(DictationSession.startsMidSentence("iPhone-Fotos fehlen noch.", after: "Der Bericht ist fertig."))
        XCTAssertFalse(DictationSession.startsMidSentence("github.com ist erreichbar.", after: "Der Server läuft."))
        XCTAssertFalse(DictationSession.startsMidSentence("und weiter.", after: nil))
    }

    func testLowercaseSegmentAfterAPauseIsJoined() async {
        let joined = await dictate(["Bitte prüfe morgen den Bericht.", "und schicke ihn dann an das Team."])
        XCTAssertEqual(joined?.final, "Bitte prüfe morgen den Bericht und schicke ihn dann an das Team.")
        let verb = await dictate(["Für die neue Wohnung.", "brauche ich noch zwei Lampen."])
        XCTAssertEqual(verb?.final, "Für die neue Wohnung brauche ich noch zwei Lampen.")
        let english = await dictate(["Please check the report tomorrow.", "and send it to the team."], language: "en")
        XCTAssertEqual(english?.final, "Please check the report tomorrow and send it to the team.")
    }

    func testCapitalizedOrQuestionSegmentsStayApart() async {
        let question = await dictate(["Kommst du heute?", "und wann genau?"])
        XCTAssertEqual(question?.final, "Kommst du heute? Und wann genau?")
        let capital = await dictate(["Der Bericht ist fertig.", "Die Fotos fehlen noch."])
        XCTAssertEqual(capital?.final, "Der Bericht ist fertig. Die Fotos fehlen noch.")
        let brand = await dictate(["Der Bericht ist fertig.", "iPhone-Fotos fehlen noch."])
        XCTAssertEqual(brand?.final, "Der Bericht ist fertig. iPhone-Fotos fehlen noch.")
    }

    func testLowercaseCorrectionAfterAPauseStaysASeparateSentence() async {
        // Without the model the period stays; with it, both sentences go to the model together.
        let plain = await dictate(["Ich komme um fünf.", "nein, um sechs."])
        XCTAssertEqual(plain?.final, "Ich komme um fünf. Nein, um sechs.")
        let llm = RecordingLLM { _ in "Ich komme um sechs." }
        let corrected = await dictate(["Ich komme um fünf.", "nein, um sechs."], llm: llm)
        XCTAssertEqual(corrected?.final, "Ich komme um sechs.")
    }

    // MARK: B3 Recognizer hint in automatic mode

    func testRecognizerHintKeepsAutomaticModeInLatinScript() {
        XCTAssertEqual(DictationLanguage.recognizerHint(setting: "auto"), "de")
        XCTAssertEqual(DictationLanguage.recognizerHint(setting: ""), "de")
        XCTAssertEqual(DictationLanguage.recognizerHint(setting: "en"), "en")
        XCTAssertEqual(DictationLanguage.recognizerHint(setting: "de"), "de")
        XCTAssertEqual(DictationLanguage.recognizerHint(setting: "pl"), "pl")
    }

    // MARK: B5 Fillers alone insert nothing

    func testOnlyFillersInsertNothing() async {
        for text in ["Um", "Um.", "Äh.", "Ähm, äh.", "Uh, hmm."] {
            let result = await dictate([text])
            XCTAssertNil(result, text)
        }
        let time = await dictate(["Um acht."])
        XCTAssertEqual(time?.final, "Um acht.")
        let question = await dictate(["Hm, gute Frage."])
        XCTAssertEqual(question?.final, "Gute Frage.")
        let english = await dictate(["Um, see you at eight."], language: "en")
        XCTAssertEqual(english?.final, "See you at eight.")
    }

    // MARK: B6 Capitalization changes are no "unchanged"

    func testCapitalizationChangeIsCounted() {
        let s = ChangeSummarizer.summarize(raw: "und dann gehen wir.", final: "Und dann gehen wir.", usedLLM: false, llmFailed: false)
        XCTAssertEqual(s.punctuationChanged, 1)
        XCTAssertEqual(s.wordsChanged, 0)
        XCTAssertEqual(s.text, "1 Satzzeichen")
        // Punctuation and capital on the same word count once.
        let both = ChangeSummarizer.summarize(raw: "hallo", final: "Hallo.", usedLLM: false, llmFailed: false)
        XCTAssertEqual(both.punctuationChanged, 1)
        let same = ChangeSummarizer.summarize(raw: "Hallo Welt.", final: "Hallo Welt.", usedLLM: false, llmFailed: false)
        XCTAssertEqual(same.text, "unverändert")
    }
}
