import XCTest
@testable import SaywriteCore

final class RuleCleanerTests: XCTestCase {

    private func full(_ text: String, style: Style = .neutral) -> String {
        RuleCleaner.finalize(RuleCleaner.clean(text), style: style)
    }

    func testRemovesFillerWords() {
        XCTAssertEqual(full("Ähm, ich wollte äh nur kurz fragen, öhm, ob das passt."),
                       "Ich wollte nur kurz fragen, ob das passt.")
    }

    func testKeepsWordsThatContainFillerLetters() {
        XCTAssertEqual(full("Das ist ähnlich wie ein Ehemann im Hmm-Modus"),
                       "Das ist ähnlich wie ein Ehemann im Hmm-Modus.")
    }

    func testCollapsesStutter() {
        XCTAssertEqual(full("ich ich wollte wir haben wir haben das gemacht"),
                       "Ich wollte wir haben das gemacht.")
    }

    func testKeepsEmphasisRepetition() {
        XCTAssertEqual(full("das ist sehr sehr gut"), "Das ist sehr sehr gut.")
    }

    func testDoesNotCollapseAcrossSentences() {
        XCTAssertEqual(full("Ich komme. Ich komme gleich."), "Ich komme. Ich komme gleich.")
    }

    func testSpokenPunctuationCommands() {
        XCTAssertEqual(full("Hallo Komma wie geht es dir Fragezeichen"), "Hallo, wie geht es dir?")
    }

    func testPunctuationWordAfterDeterminerIsContent() {
        XCTAssertEqual(full("Das Komma fehlt hier"), "Das Komma fehlt hier.")
        XCTAssertEqual(full("Ich habe einen Punkt gemacht"), "Ich habe einen Punkt gemacht.")
    }

    func testRecognizerPunctuationAroundCommandIsSwallowed() {
        XCTAssertEqual(full("Hallo, Komma, wie geht's?"), "Hallo, wie geht's?")
    }

    func testParagraphCommand() {
        XCTAssertEqual(full("Erster Teil. Neuer Absatz. zweiter Teil"), "Erster Teil.\n\nZweiter Teil.")
        XCTAssertEqual(full("erster Teil, neue Zeile zweiter Teil"), "Erster Teil,\nzweiter Teil.")
    }

    func testCapitalizesSentences() {
        XCTAssertEqual(full("das ist gut. und das auch! wirklich? ja"), "Das ist gut. Und das auch! Wirklich? Ja.")
    }

    func testCasualDropsPeriodOnSingleSentence() {
        XCTAssertEqual(full("bin gleich da", style: .casual), "Bin gleich da")
        XCTAssertEqual(full("bin gleich da. bis dann", style: .casual), "Bin gleich da. Bis dann.")
        XCTAssertEqual(full("kommst du", style: .casual), "Kommst du")
        XCTAssertEqual(full("kommst du?", style: .casual), "Kommst du?")
    }

    func testFormalExpandsShortForms() {
        XCTAssertEqual(full("hab heute keine Zeit, is nich so wichtig", style: .formal),
                       "Habe heute keine Zeit, ist nicht so wichtig.")
        XCTAssertEqual(full("Gibt's da was Neues? Kannste mir das schicken", style: .formal),
                       "Gibt es da was Neues? Kannst du mir das schicken.")
        XCTAssertEqual(full("ich hab grad keine Zeit", style: .neutral), "Ich hab grad keine Zeit.")
        XCTAssertEqual(full("Das ist ein Haben-Konto", style: .formal), "Das ist ein Haben-Konto.")
    }

    func testMathStaysVerbatim() {
        let input = "Die Ableitung von x hoch zwei minus drei x ist zwei x minus drei."
        XCTAssertEqual(full(input), input)
    }

    func testEmptyAndFillerOnly() {
        XCTAssertEqual(full(""), "")
        XCTAssertEqual(full("Ähm. Äh."), "")
    }

    func testWhitespaceNormalization() {
        XCTAssertEqual(RuleCleaner.normalizeWhitespace("Hallo  ,  Welt  ."), "Hallo, Welt.")
    }
}

final class SentenceSplitterTests: XCTestCase {
    func testSplitsSentencesAndKeepsLineBreaks() {
        XCTAssertEqual(SentenceSplitter.split("Hallo. Wie geht's? Gut!"), ["Hallo.", "Wie geht's?", "Gut!"])
        XCTAssertEqual(SentenceSplitter.split("Eins.\n\nZwei"), ["Eins.", "\n\nZwei"])
        XCTAssertEqual(SentenceSplitter.split("Um 3.5 Uhr"), ["Um 3.5 Uhr"])
    }

    func testLoneMIsTreatedAsFiller() {
        XCTAssertEqual(RuleCleaner.clean("Bitte bring die Folien mit, und M schick mir die Zahlen."),
                       "Bitte bring die Folien mit, und schick mir die Zahlen.")
        XCTAssertEqual(RuleCleaner.clean("Ich brauche Größe M."), "Ich brauche Größe M.")
    }
}
