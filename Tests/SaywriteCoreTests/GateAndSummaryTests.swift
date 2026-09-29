import XCTest
@testable import SaywriteCore

final class CleanupGateTests: XCTestCase {

    func testCleanSentenceNeedsNoLLM() {
        XCTAssertEqual(CleanupGate.decide(raw: "Das Meeting ist morgen um zehn.", style: .neutral), .rulesOnly)
    }

    func testSelfCorrectionUsesLLM() {
        XCTAssertTrue(CleanupGate.decide(raw: "Wir treffen uns um drei, nein, um vier.", style: .neutral).usesLLM)
        XCTAssertTrue(CleanupGate.decide(raw: "Schick es an Peter, ich meine an Paul.", style: .neutral).usesLLM)
    }

    func testLeadingNeinIsNotACorrection() {
        XCTAssertEqual(CleanupGate.decide(raw: "Nein, danke, das passt so.", style: .neutral), .rulesOnly)
    }

    func testFormalUsesLLMOnlyWhenNeeded() {
        XCTAssertEqual(CleanupGate.decide(raw: "Ich hab morgen keine Zeit.", style: .formal), .rulesOnly)
        XCTAssertTrue(CleanupGate.decide(raw: "Am Montag, nein, am Dienstag.", style: .formal).usesLLM)
    }

    func testCasualOnlyForCorrections() {
        let long = Array(repeating: "wort", count: 80).joined(separator: " ")
        XCTAssertEqual(CleanupGate.decide(raw: long, style: .casual), .rulesOnly)
        XCTAssertTrue(CleanupGate.decide(raw: "um drei, nein, um vier", style: .casual).usesLLM)
    }

    func testLongRunWithoutPunctuation() {
        let run = Array(repeating: "und", count: 30).joined(separator: " ")
        XCTAssertTrue(CleanupGate.decide(raw: run, style: .neutral).usesLLM)
    }

    func testLongDictation() {
        let sentence = "Das ist ein ganz normaler Satz mit zehn Wörtern darin."
        let long = Array(repeating: sentence, count: 7).joined(separator: " ")
        XCTAssertTrue(CleanupGate.decide(raw: long, style: .neutral).usesLLM)
    }
}

final class ChangeSummarizerTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    func testEnglishSummary() {
        UILanguage.override = false
        let s = ChangeSummarizer.summarize(raw: "um I'll come tomorrow", final: "I'll come tomorrow.", usedLLM: false, llmFailed: false, language: .english)
        XCTAssertEqual(s.text, "1 filler word · 1 punctuation")
    }

    func testUnchanged() {
        let s = ChangeSummarizer.summarize(raw: "Hallo Welt.", final: "Hallo Welt.", usedLLM: false, llmFailed: false)
        XCTAssertEqual(s.text, "unverändert")
    }

    func testFillersAndPunctuation() {
        let s = ChangeSummarizer.summarize(
            raw: "ähm ich komme äh morgen", final: "Ich komme morgen.", usedLLM: false, llmFailed: false)
        XCTAssertEqual(s.fillersRemoved, 2)
        XCTAssertEqual(s.punctuationChanged, 1)
        XCTAssertEqual(s.wordsChanged, 0)
        XCTAssertEqual(s.text, "2 Füllwörter · 1 Satzzeichen")
    }

    func testLLMCorrection() {
        let s = ChangeSummarizer.summarize(
            raw: "um drei, nein, um vier", final: "Um vier.", usedLLM: true, llmFailed: false)
        XCTAssertEqual(s.wordsChanged, 3)
        XCTAssertTrue(s.text.contains("KI: 3 Korrekturen"))
    }

    func testFailedLLMIsMarked() {
        let s = ChangeSummarizer.summarize(raw: "Hallo.", final: "Hallo.", usedLLM: false, llmFailed: true)
        XCTAssertEqual(s.text, "unverändert · ⚠ ohne KI")
    }
}

final class StyleMapTests: XCTestCase {

    func testDefaultsAndOverrides() {
        var map = StyleMap()
        XCTAssertEqual(map.style(for: "com.apple.mail"), .formal)
        XCTAssertEqual(map.style(for: "net.whatsapp.WhatsApp"), .casual)
        XCTAssertEqual(map.style(for: "com.apple.Notes"), .neutral)
        XCTAssertEqual(map.style(for: nil), .neutral)
        map.overrides["com.apple.mail"] = .neutral
        XCTAssertEqual(map.style(for: "com.apple.mail"), .neutral)
    }

    func testCodableRoundTrip() throws {
        let map = StyleMap(overrides: ["com.apple.Notes": .formal])
        let decoded = try JSONDecoder().decode(StyleMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded, map)
    }
}

final class OutputGuardTests: XCTestCase {

    func testStripsTagsAndQuotes() {
        XCTAssertEqual(LLMOutputGuard.sanitize("<diktat>\n„Hallo Welt.“\n</diktat>"), "Hallo Welt.")
    }

    func testRejectsAnswerInsteadOfCorrection() {
        let input = "Erklär mir kurz, was ein Integral ist."
        let answer = "Ein Integral ist ein mathematisches Konzept, das die Fläche unter einer Kurve beschreibt. Es wird in der Analysis verwendet, um Größen aufzusummieren."
        XCTAssertNil(LLMOutputGuard.acceptCleanup(input: input, output: answer, style: .neutral))
    }

    func testAcceptsSmallFix() {
        XCTAssertEqual(LLMOutputGuard.acceptCleanup(input: "um drei, nein, um vier", output: "Um vier.", style: .neutral), "Um vier.")
    }

    func testRejectsRepeatedContextSentence() {
        XCTAssertNil(LLMOutputGuard.acceptCleanup(
            input: "Ich habe morgen leider keine Zeit, weil ich beim Arzt bin.",
            output: "Kannst du die Rechnung bitte an Paul schicken?", style: .formal))
    }

    func testAcceptsFormalShortFormFix() {
        XCTAssertNotNil(LLMOutputGuard.acceptCleanup(
            input: "Ich hab morgen keine Zeit.", output: "Ich habe morgen keine Zeit.", style: .formal))
    }

    func testAcceptsSelfCorrectionThatDropsHalfTheWords() {
        XCTAssertEqual(LLMOutputGuard.acceptCleanup(
            input: "Ich möchte einen Stuhl kaufen, nein, ich meine, ich möchte ein Fahrrad kaufen.",
            output: "Ich möchte ein Fahrrad kaufen.", style: .neutral), "Ich möchte ein Fahrrad kaufen.")
    }

    func testRejectsShortInventedOutput() {
        XCTAssertNil(LLMOutputGuard.acceptCleanup(
            input: "Ich möchte einen Stuhl kaufen, nein, ich meine, ich möchte ein Fahrrad kaufen.",
            output: "Mobilität ist wichtig.", style: .neutral))
    }

    func testRejectsEmpty() {
        XCTAssertNil(LLMOutputGuard.acceptCleanup(input: "Hallo", output: "  ", style: .neutral))
    }
}
