import XCTest
@testable import SaywriteCore

/// Cases found in the review round; each one produced wrong text before.
final class ReviewFindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    private func full(_ text: String, style: Style = .neutral, language: DictationLanguage = .german) -> String {
        RuleCleaner.finalize(RuleCleaner.clean(text, language: language), style: style, language: language)
    }

    func testPunktIsContent() {
        XCTAssertEqual(full("Das ist der wichtigste Punkt."), "Das ist der wichtigste Punkt.")
        XCTAssertEqual(full("Wir treffen uns um Punkt acht Uhr."), "Wir treffen uns um Punkt acht Uhr.")
        XCTAssertEqual(full("Version zwei Punkt null"), "Version zwei Punkt null.")
    }

    func testDecimalComma() {
        XCTAssertEqual(full("Es sind 3 Komma 5 Grad"), "Es sind 3,5 Grad.")
        XCTAssertEqual(full("zwei Komma fünf Prozent"), "Zwei Komma fünf Prozent.")
    }

    func testNewLineAsContent() {
        XCTAssertEqual(full("Ich schreibe eine neue Zeile in das Gedicht"), "Ich schreibe eine neue Zeile in das Gedicht.")
        XCTAssertEqual(full("Hallo zusammen Doppelpunkt neue Zeile erstens"), "Hallo zusammen:\nErstens.")
    }

    func testGrammaticalDoublesStay() {
        XCTAssertEqual(full("Ich glaube, dass das das Beste ist."), "Ich glaube, dass das das Beste ist.")
        XCTAssertEqual(full("Die Frau, die die Blumen gekauft hat."), "Die Frau, die die Blumen gekauft hat.")
        XCTAssertEqual(full("Der Mann, der der Frau hilft."), "Der Mann, der der Frau hilft.")
        XCTAssertEqual(full("ich ich komme gleich"), "Ich komme gleich.")
    }

    func testFormalShortFormsDoNotCorruptWords() {
        XCTAssertEqual(full("Es sind 3 Grad warm", style: .formal), "Es sind 3 Grad warm.")
        XCTAssertEqual(full("Die IS-Kämpfer", style: .formal), "Die IS-Kämpfer.")
        XCTAssertEqual(full("This is great", style: .formal, language: .english), "This is great.")
        XCTAssertEqual(full("ich hab keine Zeit", style: .formal), "Ich habe keine Zeit.")
    }

    func testLetterMStays() {
        XCTAssertEqual(RuleCleaner.clean("Ich trage Größe M oder L."), "Ich trage Größe M oder L.")
        XCTAssertEqual(RuleCleaner.clean("Das schreibt man mit M wie Martha."), "Das schreibt man mit M wie Martha.")
    }

    func testRecognizerFillerSpellings() {
        XCTAssertEqual(full("bring die Folien mit, und em schick mir die Zahlen"), "Bring die Folien mit, und schick mir die Zahlen.")
        XCTAssertEqual(full("Die EM beginnt morgen"), "Die EM beginnt morgen.")
    }

    func testFillerBetweenCommas() {
        XCTAssertEqual(full("ich komme morgen, äh, um drei"), "Ich komme morgen um drei.")
    }

    func testQuotesAndBrackets() {
        XCTAssertEqual(full("er sagte Anführungszeichen hallo Anführungszeichen und ging"), "Er sagte „hallo“ und ging.")
        XCTAssertEqual(full("das Ergebnis Klammer auf siehe unten Klammer zu ist gut"), "Das Ergebnis (siehe unten) ist gut.")
        XCTAssertEqual(full("erstens Semikolon zweitens"), "Erstens; zweitens.")
    }

    func testGateIgnoresOrdinarySentences() {
        for sentence in [
            "Ich warte auf den Bus.", "Im Moment habe ich keine Zeit.", "Einen Moment bitte.",
            "Die Antwort war nein.", "Das ist doch Quatsch.", "Köln beziehungsweise Bonn.",
            "Ich meine, das passt so.", "Nein, danke.",
        ] {
            XCTAssertEqual(CleanupGate.decide(raw: sentence, style: .neutral), .rulesOnly, sentence)
        }
    }

    func testGateStillCatchesCorrections() {
        for sentence in [
            "Wir treffen uns um drei, nein, um vier.", "Schick es an Peter, ich meine an Paul.",
            "Am Montag, Moment, am Dienstag.", "Kauf Milch, besser gesagt Hafermilch.",
        ] {
            XCTAssertTrue(CleanupGate.decide(raw: sentence, style: .neutral).usesLLM, sentence)
        }
    }

    func testDiscardEverythingBefore() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Ich wollte ein neues Repo bauen. Aber nee, vergiss das, ich meine, bau eine neue Webseite."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        _ = await session.finish()
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["Ich wollte ein neues Repo bauen. Aber nee, vergiss das, ich meine, bau eine neue Webseite."])
    }

    func testDiscardAcrossPause() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Ich wollte ein neues Repo bauen.", 2: "Aber nee, vergiss das, bau eine Webseite."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        _ = await session.finish()
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["Ich wollte ein neues Repo bauen. Aber nee, vergiss das, bau eine Webseite."])
    }

    func testGuardAcceptsDiscardingMostWords() {
        XCTAssertEqual(LLMOutputGuard.acceptCleanup(
            input: "Also ich hatte gerade eigentlich überlegt, ein neues, vielleicht ein neues Repo zu bauen. Aber nee, vergiss das, ich meine, bau eine neue Webseite.",
            output: "Bau eine neue Webseite.", style: .neutral), "Bau eine neue Webseite.")
    }

    func testCorrectedNumbers() {
        XCTAssertEqual(CleanupGate.correctedNumbers(in: "Bring 2 bottles, wait, 3 bottles of water.", language: .english), ["3"])
        XCTAssertEqual(CleanupGate.correctedNumbers(in: "Ich komme um 5, nein, um 6.", language: .german), ["6"])
        XCTAssertEqual(CleanupGate.correctedNumbers(in: "Schick es an Tim, sorry, an Tom.", language: .german), [])
    }

    func testLeadingCorrectionDetection() {
        XCTAssertTrue(CleanupGate.startsWithCorrection("Aber nee, vergiss das, ich meine, bau eine Webseite."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Ach nein, streich das, wir kochen."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Nein, um sechs."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Ich meine am Dienstag."))
        XCTAssertFalse(CleanupGate.startsWithCorrection("Nein."))
        XCTAssertFalse(CleanupGate.startsWithCorrection("Nein, das passt so, danke."))
        XCTAssertFalse(CleanupGate.startsWithCorrection("Nee, keine Lust."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Nein, um sechs."))
        XCTAssertTrue(CleanupGate.startsWithCorrection("Nee, lieber am Freitag."))
        XCTAssertFalse(CleanupGate.startsWithCorrection("Neinstein kommt."))
    }

    func testCorrectionAcrossPauseIsMerged() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Ich komme um drei.", 2: "Nein, um vier."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["Ich komme um drei. Nein, um vier."])
        XCTAssertEqual(result?.summary.usedLLM, true)
    }

    func testAIOffIsNotAFailure() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "um drei, nein, um vier"]), llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.summary.llmFailed, false)
        XCTAssertFalse(result?.summary.text.contains("ohne KI") ?? true)
    }

    func testReplacements() {
        let entries = [Replacement(heard: "fluid audio", written: "FluidAudio"), Replacement(heard: "gitt hab", written: "GitHub")]
        let (text, count) = ReplacementEngine.apply(entries, to: "Ich nutze Fluid Audio und Gitt Hab.")
        XCTAssertEqual(text, "Ich nutze FluidAudio und GitHub.")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(ReplacementEngine.apply(entries, to: "Gitt Habsburg").count, 0)
    }

    func testDictionaryAppliedInSession() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Der Code liegt auf Gitt Hab."]), llm: nil, style: .neutral, appBundleID: nil,
            replacements: [Replacement(heard: "gitt hab", written: "GitHub")])
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Der Code liegt auf GitHub.")
        XCTAssertEqual(result?.summary.replacements, 1)
        XCTAssertEqual(result?.summary.wordsChanged, 0)
    }

    func testWithoutAIVersionIsKept() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Wir treffen uns um drei, nein, um vier."]),
            llm: FakeLLM(), style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Wir treffen uns um vier.")
        XCTAssertEqual(result?.withoutAI, "Wir treffen uns um drei, nein, um vier.")
    }
}
