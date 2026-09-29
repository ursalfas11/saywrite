import AVFoundation

/// Short, soft feedback sounds, synthesized at launch (no audio files needed).
@MainActor
final class Sounds {
    private let start: AVAudioPlayer?
    private let stop: AVAudioPlayer?

    init() {
        // Rising two-note blip when recording starts, falling one when the text is inserted.
        start = Self.player(notes: [(740, 0.055), (1110, 0.075)], volume: 0.32)
        stop = Self.player(notes: [(1110, 0.05), (660, 0.08)], volume: 0.3)
    }

    func playStart() { play(start) }
    func playStop() { play(stop) }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func player(notes: [(frequency: Double, duration: Double)], volume: Float) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: wav(notes: notes))
        player?.volume = volume
        player?.prepareToPlay()
        return player
    }

    /// 16-bit mono WAV with a smooth attack/decay per note so it never clicks.
    private static func wav(notes: [(frequency: Double, duration: Double)]) -> Data {
        let sampleRate = 44_100.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.duration * sampleRate)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let progress = Double(i) / Double(count)
                let envelope = min(1, progress * 12) * pow(1 - progress, 1.6)
                // A touch of the octave makes it sound rounder than a pure sine.
                let value = (sin(2 * .pi * note.frequency * t) + 0.25 * sin(4 * .pi * note.frequency * t)) / 1.25
                samples.append(Int16(value * envelope * 0.9 * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(44_100)); append(UInt32(88_200))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for sample in samples { append(sample) }
        return data
    }
}
