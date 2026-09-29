import XCTest
@testable import SaywriteCore

final class PreviewTests: XCTestCase {
    func testPreviewShowsFinishedSegmentsInOrder() async throws {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Erster Satz.", 2: "ähm zweiter Satz."], delays: [2: 300_000_000]),
            llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        try await Task.sleep(nanoseconds: 100_000_000)
        let early = await session.previewText()
        XCTAssertEqual(early, "Erster Satz.")
        _ = await session.finish()
        let late = await session.previewText()
        XCTAssertEqual(late, "Erster Satz. zweiter Satz.")
    }
}
