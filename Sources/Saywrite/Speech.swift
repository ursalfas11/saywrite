import CoreML
import FluidAudio
import Foundation
import SaywriteCore

/// Parakeet (via FluidAudio) as the app's `Transcriber`.
actor ParakeetTranscriber: Transcriber {
    enum State: Equatable {
        case notLoaded
        case loading(Double)
        case ready
        case failed(String)
    }

    private var manager: AsrManager?
    private var version: AsrModelVersion = .ultra
    private var language: Language?

    func setLanguage(_ code: String) {
        language = Language(rawValue: code)
    }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { update in
            progress(update.fractionCompleted)
        })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        // First inference compiles the Neural Engine graph; do it now instead of on the first dictation.
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        var padded = samples
        // Very short clips are padded with silence; the model needs at least ~0.3 s and does better with 1 s.
        if padded.count < 16_000 { padded += [Float](repeating: 0, count: 16_000 - padded.count) }
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await manager.transcribe(padded, decoderState: &state, language: language)
        return result.text
    }
}

/// Cuts the live sample stream into utterances at natural pauses so they can be transcribed
/// while the user keeps talking.
actor Segmenter {
    static let chunkSize = 4096 // 256 ms at 16 kHz, what the Silero model expects
    private static let sampleRate = 16_000

    private let vad: VadManager?
    private var state: VadStreamState?
    private let config: VadSegmentationConfig
    private var pending: [Float] = []
    private var buffer: [Float] = []
    private var lastCut = 0
    private var speechSinceCut = false
    private var inSpeech = false
    private var afterForcedCut = false

    init(vad: VadManager?) {
        self.vad = vad
        var config = VadSegmentationConfig.default
        config.minSilenceDuration = 0.45
        config.minSpeechDuration = 0.2
        config.speechPadding = 0.1
        self.config = config
    }

    func reset() async {
        pending.removeAll()
        buffer.removeAll()
        lastCut = 0
        speechSinceCut = false
        inSpeech = false
        afterForcedCut = false
        state = await vad?.makeStreamState()
    }

    /// Feed new samples. Returns any utterances that ended with this input.
    func append(_ samples: [Float]) async -> [AudioSegment] {
        buffer.append(contentsOf: samples)
        guard let vad, var currentState = state else { return [] }
        pending.append(contentsOf: samples)
        var segments: [AudioSegment] = []
        while pending.count >= Self.chunkSize {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(Self.chunkSize)
            guard let result = try? await vad.processStreamingChunk(chunk, state: currentState, config: config) else { continue }
            currentState = result.state
            guard let event = result.event else { continue }
            Debug.log("vad \(event.kind) at \(String(format: "%.2f", Double(event.sampleIndex) / 16_000))s")
            switch event.kind {
            case .speechStart:
                speechSinceCut = true
                inSpeech = true
            case .speechEnd:
                inSpeech = false
                defer {
                    // Also when a forced cut already consumed this audio: the next utterance starts fresh.
                    speechSinceCut = false
                    afterForcedCut = false
                }
                // The VAD's end index already includes `speechPadding`.
                let cut = min(buffer.count, event.sampleIndex)
                if speechSinceCut, cut > lastCut {
                    segments.append(AudioSegment(samples: Array(buffer[lastCut..<cut]), continuesPrevious: afterForcedCut))
                    afterForcedCut = false
                    lastCut = cut
                    speechSinceCut = false
                }
            }
        }
        state = currentState
        // Without a clear pause (reverb, fast talkers) cut at the quietest spot anyway, so the work
        // left after releasing the key stays small. The streaming VAD has no length limit itself.
        if inSpeech, buffer.count - lastCut > Self.maxSegmentSamples {
            let from = max(lastCut + Self.sampleRate, buffer.count - Self.sampleRate * 3 / 2)
            let cut = Self.quietestPoint(in: buffer, from: from, to: buffer.count)
            if cut > lastCut {
                segments.append(AudioSegment(samples: Array(buffer[lastCut..<cut]), continuesPrevious: afterForcedCut))
                lastCut = cut
                speechSinceCut = true // the rest of the utterance continues after the cut
                afterForcedCut = true
            }
        }
        return segments
    }

    /// Only very long stretches without any pause are cut, because a cut mid-sentence costs accuracy.
    static let maxSegmentSamples = 15 * sampleRate

    /// Start of the quietest 100 ms window in the range, a good place to split speech.
    static func quietestPoint(in samples: [Float], from start: Int, to end: Int) -> Int {
        let window = 1600
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = max(0, start)
        while index + window <= end {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            if sum < bestEnergy {
                bestEnergy = sum
                best = index + window / 2
            }
            index += window / 2
        }
        return best
    }

    /// The most recent audio after the last cut (at most `limit` samples), without consuming it.
    /// Used for the live preview; the limit keeps preview cost constant.
    func openAudio(limit: Int = 6 * 16_000) -> (samples: [Float], totalCount: Int) {
        guard lastCut < buffer.count else { return ([], 0) }
        let start = max(lastCut, buffer.count - limit)
        return (Array(buffer[start...]), buffer.count - lastCut)
    }

    /// Whether speech is going on right now (VAD), or unknown without a VAD.
    var isSpeaking: Bool { vad == nil || inSpeech }

    /// The rest of the recording after the last cut. Nil when it holds no speech.
    func flush() -> AudioSegment? {
        guard lastCut < buffer.count else { return nil }
        let rest = Array(buffer[lastCut...])
        lastCut = buffer.count
        // Without a VAD everything is one segment. With a VAD, skip trailing silence, but never
        // drop audio that is clearly loud enough to contain quiet speech the VAD missed.
        if vad == nil || speechSinceCut || inSpeech || Self.hasEnergy(rest) {
            return AudioSegment(samples: rest, continuesPrevious: afterForcedCut)
        }
        return nil
    }

    static func hasEnergy(_ samples: [Float]) -> Bool {
        guard samples.count >= sampleRate * 3 / 10 else { return false }
        let window = 1600 // 100 ms
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for i in index..<(index + window) { sum += samples[i] * samples[i] }
            if sqrt(sum / Float(window)) > 0.01 { return true } // about -40 dBFS
            index += window
        }
        return false
    }
}
