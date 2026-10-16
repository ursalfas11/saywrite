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
}
