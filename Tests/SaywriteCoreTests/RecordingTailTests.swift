import XCTest
@testable import SaywriteCore

/// The grace period after the release and the timing log (round 4).
final class RecordingTailTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Recording tail

    func testSilentTailStopsAtOnce() {
        let quiet = [Float](repeating: 0.001, count: 4_000)
        XCTAssertTrue(RecordingTail.canStopNow(isSpeaking: false, recent: quiet))
    }

    func testSpeechKeepsTheGracePeriod() {
        let quiet = [Float](repeating: 0, count: 4_000)
        XCTAssertFalse(RecordingTail.canStopNow(isSpeaking: true, recent: quiet))
    }

    func testEnergyInTheLast100msKeepsTheGracePeriod() {
        var samples = [Float](repeating: 0, count: 4_000)
        for i in (4_000 - 800)..<4_000 { samples[i] = i % 2 == 0 ? 0.05 : -0.05 }
        XCTAssertFalse(RecordingTail.canStopNow(isSpeaking: false, recent: samples))
        // Loud audio before the last 100 ms does not matter.
        var earlier = [Float](repeating: 0, count: 4_000)
        for i in 0..<2_000 { earlier[i] = 0.3 }
        XCTAssertTrue(RecordingTail.canStopNow(isSpeaking: false, recent: earlier))
    }

    func testTooLittleAudioKeepsTheGracePeriod() {
        XCTAssertFalse(RecordingTail.canStopNow(isSpeaking: false, recent: [Float](repeating: 0, count: 800)))
        XCTAssertFalse(RecordingTail.canStopNow(isSpeaking: false, recent: []))
    }

    // MARK: - Timing

    func testTimingSplitsTheWait() {
        var timing = FinishTiming(released: t0)
        timing.audioStopped = t0 + 0.15
        timing.lastTranscription = t0 + 0.21
        timing.textReady = t0 + 0.39
        timing.inserted = t0 + 0.412
        XCTAssertEqual(timing.summary(), "total 412 ms (tail 150, asr 60, llm/rules 180, insert 22)")
    }

    func testTimingWithAllSpeechDoneWhileTalking() {
        var timing = FinishTiming(released: t0)
        timing.audioStopped = t0
        timing.lastTranscription = t0 - 2 // last segment finished during the recording
        timing.textReady = t0 + 0.05
        XCTAssertEqual(timing.summary(now: t0 + 0.06), "total 50 ms (tail 0, asr 0, llm/rules 50, insert –)")
    }
}
