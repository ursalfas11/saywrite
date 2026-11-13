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

enum AudioCaptureError: LocalizedError {
    case noMicrophone, unsupportedFormat
    /// Core Audio did not answer in time. The call may still hang in the background.
    case notResponding

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Kein Mikrofon gefunden"
        case .unsupportedFormat: return "Audioformat nicht unterstützt"
        case .notResponding: return "Core Audio antwortet nicht"
        }
    }
}

/// Records a microphone into memory as 16 kHz mono Float32.
/// Chunks and levels are delivered on the audio thread via the callbacks.
///
/// Every call into `AVAudioEngine` runs on a private serial queue with a deadline. When Core Audio
/// stops answering (seen on 12.11.2026: `inputNode` spun for hours inside the HAL after a device
/// change), the caller gets `.notResponding` instead of the main thread hanging with it, and later
/// starts fail fast until the stuck call returns.
final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread. Guarded by `lock` so it can be swapped while audio is running.
    private var sampleHandler: (([Float]) -> Void)?
    /// Normalized 0...1 loudness for the overlay meter. Set once before the first recording.
    var onLevel: ((Float) -> Void)?
    /// The input device went away mid-recording and no replacement could be started. Called on main.
    var onDeviceLost: (() -> Void)?

    private let queue = DispatchQueue(label: "Saywrite.AudioCapture", qos: .userInitiated)
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Number of queue jobs whose caller gave up waiting and that have not returned yet. Guarded by `lock`.
    private var overdueJobs = 0
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!

    // Only touched on `queue`.
    private var engine = AVAudioEngine()
    private var isRunning = false
    private var configObserver: NSObjectProtocol?

    /// Starting normally takes well under a second; a Bluetooth device may need a moment longer.
    static let startTimeout: TimeInterval = 5
    static let stopTimeout: TimeInterval = 1

    func setSampleHandler(_ handler: (([Float]) -> Void)?) {
        lock.lock()
        sampleHandler = handler
        lock.unlock()
    }

    /// `true` while an earlier call into Core Audio is still stuck on the audio queue.
    var isStuck: Bool { lock.withLock { overdueJobs > 0 } }

    /// Starts recording from `deviceUID` (nil: the system default).
    func start(deviceUID: String?) async throws {
        // Do not queue behind a call that never returned: the user would wait forever.
        guard !isStuck else { throw AudioCaptureError.notResponding }
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        try await onQueue(timeout: Self.startTimeout) { [self] in
            guard !isRunning else { return }
            // A fresh engine each time, so switching back to "System default" or a device that was
            // plugged in since the last recording takes effect.
            engine = AVAudioEngine()
            try startEngine(deviceUID: deviceUID)
            isRunning = true
            // Headphones connected or the default input changed: continue with the new device instead
            // of silently losing the rest of the dictation.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
            ) { [weak self] note in
                guard let self else { return }
                let changed = note.object as AnyObject?
                self.queue.async {
                    guard self.isRunning, changed === self.engine else { return }
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    self.engine = AVAudioEngine()
                    do {
                        try self.startEngine(deviceUID: deviceUID)
                    } catch {
                        DispatchQueue.main.async { self.onDeviceLost?() }
                    }
                }
            }
        }
    }

    private func startEngine(deviceUID: String?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let input = engine.inputNode
        if let uid = deviceUID, var deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioCaptureError.noMicrophone }
        // Each tap owns its converter: after a device change the old engine may still deliver a
        // buffer in the old format while the new one starts, so a shared converter would be raced
        // and fed the wrong format.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.unsupportedFormat
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns everything captured since `start()`. Never waits longer than
    /// `stopTimeout`: whatever was captured until then is returned even if Core Audio hangs.
    @discardableResult
    func stop() async -> [Float] {
        try? await onQueue(timeout: Self.stopTimeout) { [self] in stopOnQueue() }
        return lock.withLock { samples }
    }

    /// Stops without waiting for the result, for cancelling.
    func stopInBackground() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Runs `work` on the audio queue and waits at most `timeout`. On timeout the work keeps running
    /// (a thread stuck in Core Audio cannot be interrupted) and counts as overdue until it returns.
    private func onQueue(timeout: TimeInterval, _ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let state = JobState()
            queue.async { [self] in
                let result = Result { try work() }
                lock.lock()
                let timedOut = state.timedOut
                state.finished = true
                if timedOut { overdueJobs -= 1 }
                lock.unlock()
                if !timedOut { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let finished = state.finished
                if !finished {
                    state.timedOut = true
                    overdueJobs += 1
                }
                lock.unlock()
                if !finished { continuation.resume(throwing: AudioCaptureError.notResponding) }
            }
        }
    }

    /// Who got there first: the job or its deadline. Guarded by `lock`.
    private final class JobState: @unchecked Sendable {
        var finished = false
        var timedOut = false
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
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
