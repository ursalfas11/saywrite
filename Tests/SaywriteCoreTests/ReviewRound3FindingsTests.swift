import XCTest
@testable import SaywriteCore

/// A model that answers with a fixed function of its input and records what it was given.
private struct ScriptedLLM: LLMClient {
    let log = CallLog()
    let answer: @Sendable (String) -> String
    func prewarm(forRewrite: Bool) async {}
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String {
        await log.record(text)
        // Like LLMOutputGuard.sanitize: the real clients trim whitespace and newlines.
        return answer(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func rewrite(selection: String, instruction: String) async throws -> String { selection }
}

/// Findings of review round 3.
final class ReviewRound3FindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    // MARK: Line break before a sentence the model processes

    func testSplitLeadingBreak() {
        XCTAssertEqual(DictationSession.splitLeadingBreak("\n\nIch komme.").lead, "\n\n")
        XCTAssertEqual(DictationSession.splitLeadingBreak("\n\nIch komme.").body, "Ich komme.")
        XCTAssertEqual(DictationSession.splitLeadingBreak("Ich komme.").lead, "")
    }

    func testLineBreakSurvivesAModelCorrection() async {
        let llm = ScriptedLLM { $0.replacingOccurrences(of: "um fünf, nein, ", with: "") }
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Hallo Max Komma neue Zeile ich komme um fünf, nein, um sechs Uhr."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].contains("\n"), "the model gets the sentence without the break")
        XCTAssertTrue(result?.final.contains(",\n") == true, result?.final ?? "nil")
    }

    func testParagraphSurvivesACorrectionAcrossSentences() async {
        let llm = ScriptedLLM { $0.replacingOccurrences(of: "um fünf. Nein, um ", with: "um ") }
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Hallo Max. Neuer Absatz Ich komme um fünf. Nein, um sechs."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertTrue(result?.final.contains("\n\n") == true, result?.final ?? "nil")
        XCTAssertTrue(result?.final.contains("sechs") == true)
        XCTAssertFalse(result?.final.contains("fünf") == true, result?.final ?? "nil")
    }

    // MARK: Correction guard

    private func accepts(_ input: String, _ output: String) -> Bool {
        DictationSession.acceptsCorrection(input, output, .german)
            && LLMOutputGuard.keepsCorrectionStructure(input: input, output: output)
    }

    func testGuardRefusesAnswerThatKeepsTheOldItemAndDropsTheNewOne() {
        XCTAssertFalse(accepts("Wir brauchen Tinte, Toner, nein, Papier und Stifte.", "Wir brauchen Tinte, Toner und Stifte."))
        XCTAssertFalse(accepts("Kauf Brot, Milch, nein, Butter, Käse und Wurst.", "Kauf Brot, Milch, Käse und Wurst."))
        XCTAssertFalse(accepts("Das Meeting ist am Montag, nein, am Dienstag um 11 Uhr im Büro.", "Das Meeting ist am Montag um 11 Uhr im Büro."))
        XCTAssertFalse(accepts("Schick das an Peter, nein, an Paul Müller in Hamburg.", "Schick das an Peter Müller in Hamburg."))
    }

    func testGuardRefusesDroppedInstruction() {
        XCTAssertFalse(accepts("Übersetze das ins Englische, nein, ins Französische: Guten Morgen.", "Guten Morgen."))
    }

    func testGuardStillAcceptsGoodAnswers() {
        XCTAssertTrue(accepts("Wir brauchen Tinte, Toner, nein, Papier und Stifte.", "Wir brauchen Tinte, Papier und Stifte."))
        XCTAssertTrue(accepts("Das Meeting ist am Montag, nein, am Dienstag um 11 Uhr im Büro.", "Das Meeting ist am Dienstag um 11 Uhr im Büro."))
        XCTAssertTrue(accepts("Schick das an Peter, nein, an Paul Müller in Hamburg.", "Schick das an Paul Müller in Hamburg."))
        XCTAssertTrue(accepts("Ich komme um fünf, nein, um sechs.", "Ich komme um sechs."))
    }

    // MARK: Gate

    func testRefusalAfterQuoteVerbIsNoCorrection() {
        for text in ["Er bot mir ein Stück Kuchen an, ich sagte, nein, Danke.",
                     "Ich habe ihr gesagt, dass ich keinen Hunger habe, nein, Danke.",
                     "Sie fragte mich, ob ich noch Kaffee will, und ich sagte, nein, Danke.",
                     "Möchtest du Kaffee, nein, Danke."] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral).usesLLM, text)
        }
        XCTAssertFalse(CleanupGate.decide(raw: "He offered me cake, I said, no, Thanks.", style: .neutral, language: .english).usesLLM)
    }

    func testNameCorrectionStillGoesToTheModel() {
        XCTAssertTrue(CleanupGate.decide(raw: "Schick das an Mark, sorry, Mike.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "Schick das an Peter, nein, Paul.", style: .neutral).usesLLM)
    }

    func testCommaLessCorrectionsAreDetected() {
        XCTAssertTrue(CleanupGate.decide(raw: "Ich komme morgen um fünf Uhr nein um sechs Uhr vorbei.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "Das macht 12,99 Euro, nein 13,99 Euro.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "I come at five o'clock no at six o'clock.", style: .neutral, language: .english).usesLLM)
        XCTAssertFalse(CleanupGate.decide(raw: "Die Antwort war nein, 13 Leute kamen trotzdem.", style: .neutral).usesLLM)
    }

    // MARK: Rules

    func testSizeMAfterPrepositionStays() {
        for text in ["Haben Sie das Shirt in M auf Lager?", "Ich nehme das Shirt in M mit.", "Wir brauchen von M noch fünf Stück."] {
            XCTAssertEqual(RuleCleaner.removeFillers(text), text)
        }
        XCTAssertEqual(RuleCleaner.removeFillers("Das ist M wirklich gut."), "Das ist wirklich gut.")
    }

    func testBusinessAbbreviationsDoNotEndTheSentence() {
        for (text, expected) in [
            ("Das ist i. d. R. so geregelt", "Das ist i. d. R. so geregelt."),
            ("Der Preis beträgt 100 Euro inkl. MwSt. und Versand", "Der Preis beträgt 100 Euro inkl. MwSt. und Versand."),
            ("Das gilt lt. Vertrag bzgl. der Lieferung ab Mo. nächster Woche", "Das gilt lt. Vertrag bzgl. der Lieferung ab Mo. nächster Woche."),
        ] {
            XCTAssertEqual(RuleCleaner.finalize(RuleCleaner.clean(text), style: .neutral), expected)
        }
        XCTAssertEqual(SentenceSplitter.split("Das ist so. Und weiter."), ["Das ist so.", "Und weiter."])
    }
}
