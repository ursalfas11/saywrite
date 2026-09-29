import XCTest
@testable import SaywriteCore

final class SeamTests: XCTestCase {
    func testForcedCutIsGluedBack() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Schick mir die Zahlen vom letzten.", 2: "Quartal und die Folien."]),
            llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment(AudioSegment(samples: [1]))
        await session.addSegment(AudioSegment(samples: [2], continuesPrevious: true))
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Schick mir die Zahlen vom letzten Quartal und die Folien.")
    }

    func testFunctionWordIsLowercasedAtSeam() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Ich gehe heute.", 2: "Und morgen auch."]),
            llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment(AudioSegment(samples: [1]))
        await session.addSegment(AudioSegment(samples: [2], continuesPrevious: true))
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Ich gehe heute und morgen auch.")
    }

    func testRealPauseKeepsSentences() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Ich gehe heute.", 2: "Und morgen auch."]),
            llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Ich gehe heute. Und morgen auch.")
    }
}
