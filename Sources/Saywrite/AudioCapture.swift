import AVFoundation
import CoreAudio

/// An audio input device, identified by its stable UID.
struct InputDevice: Identifiable, Hashable {
    let id: String // UID
    let name: String
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard hasInput(deviceID), let uid = string(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = string(deviceID, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid && hasInput($0) }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Records a microphone into memory as 16 kHz mono Float32.
/// Chunks and levels are delivered on the audio thread via the callbacks.
final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread. Guarded by `lock` so it can be swapped while audio is running.
    private var sampleHandler: (([Float]) -> Void)?
    /// Normalized 0...1 loudness for the overlay meter.
    var onLevel: ((Float) -> Void)?
    /// The input device went away mid-recording and no replacement could be started.
    var onDeviceLost: (() -> Void)?

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!
    private(set) var isRunning = false
    /// UID of the chosen input device, nil for the system default.
    var preferredDeviceUID: String?
    private var configObserver: NSObjectProtocol?

    func setSampleHandler(_ handler: (([Float]) -> Void)?) {
        lock.lock()
        sampleHandler = handler
        lock.unlock()
    }

    func start() throws {
        guard !isRunning else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        // A fresh engine each time, so switching back to "System default" or a device that was
        // plugged in since the last recording takes effect.
        engine = AVAudioEngine()
        try startEngine()
        isRunning = true
        // Headphones connected or the default input changed: continue with the new device instead
        // of silently losing the rest of the dictation.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isRunning, (note.object as? AVAudioEngine) === self.engine else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            do {
                try self.startEngine()
            } catch {
                self.onDeviceLost?()
            }
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if let uid = preferredDeviceUID, var deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Saywrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon gefunden"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns everything captured since `start()`.
    @discardableResult
    func stop() -> [Float] {
        if isRunning {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        lock.lock()
        samples.append(contentsOf: chunk)
        let handler = sampleHandler
        lock.unlock()

        handler?(chunk)
        onLevel?(Self.level(of: chunk))
    }

    static func level(of chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = sqrt(sum / Float(chunk.count))
        // Map roughly -50 dB...-10 dB to 0...1.
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 40))
    }
}
