import Foundation

/// How long the microphone keeps running after the key is released. Normally a moment longer, so
/// the last syllable is not cut off; when the VAD says nobody speaks and the last 100 ms are quiet,
/// that wait buys nothing and the text comes sooner.
public enum RecordingTail {
    /// The extra recording after the release when speech may still be going on.
    public static let grace: TimeInterval = 0.15
    /// 100 ms at 16 kHz.
    public static let window = 1_600
    /// About -40 dBFS, the same bound the segmenter uses for "may contain quiet speech".
    public static let silenceRMS: Float = 0.01

    /// `isSpeaking` is the VAD's view (true when there is no VAD); `recent` the newest samples.
    public static func canStopNow(isSpeaking: Bool, recent: [Float]) -> Bool {
        // Too little audio to judge: keep the grace period.
        guard !isSpeaking, recent.count >= window else { return false }
        var sum: Float = 0
        for sample in recent.suffix(window) { sum += sample * sample }
        return (sum / Float(window)).squareRoot() <= silenceRMS
    }
}

/// Where the time goes between releasing the key and the inserted text, for the debug log.
/// The parts are measured from timestamps, so they need no hooks inside the session.
public struct FinishTiming: Sendable {
    public let released: Date
    /// The microphone stopped (after the grace period, if any).
    public var audioStopped: Date?
    /// End of the last speech recognition run; before `audioStopped` when everything was already
    /// transcribed while the user was talking.
    public var lastTranscription: Date?
    /// The final text (cleanup, AI) is ready.
    public var textReady: Date?
    /// The text landed in the app.
    public var inserted: Date?

    public init(released: Date) {
        self.released = released
    }

    /// One log line with milliseconds, e.g. "total 412 ms (tail 150, asr 60, llm/rules 180, insert 22)".
    /// Holds no dictated text.
    public func summary(now: Date = Date()) -> String {
        func ms(_ from: Date?, _ to: Date?) -> String {
            guard let from, let to else { return "–" }
            return String(max(0, Int((to.timeIntervalSince(from) * 1000).rounded())))
        }
        let asrEnd = [audioStopped, lastTranscription].compactMap { $0 }.max()
        let total = ms(released, inserted ?? textReady ?? now)
        return "total \(total) ms (tail \(ms(released, audioStopped)), asr \(ms(audioStopped, asrEnd)), "
            + "llm/rules \(ms(asrEnd, textReady)), insert \(ms(textReady, inserted)))"
    }
}
