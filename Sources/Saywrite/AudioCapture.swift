import AVFoundation
import CoreAudio
import SaywriteCore

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

    /// The current system default input.
    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Opening the microphone of a Bluetooth headset switches it to its call profile: the sound
    /// quality of music or a call drops for as long as the input is open.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
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
/// The engine is started and stopped on a serial queue, never on the main thread: opening an input
/// can take a few hundred ms (Bluetooth), and the main thread also serves the event tap that every
/// key press of the user waits for. Chunks and levels are delivered on the audio thread via the callbacks.
final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Called on the audio thread. Guarded by `lock` so it can be swapped while audio is running.
    private var sampleHandler: (([Float]) -> Void)?
    /// Normalized 0...1 loudness for the overlay meter. Set once before the first recording.
    var onLevel: ((Float) -> Void)?
    /// The input device went away mid-recording and no replacement could be started. Main thread.
    var onDeviceLost: (() -> Void)?

    private let queue = DispatchQueue(label: "saywrite.audio", qos: .userInitiated)
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate, channels: 1, interleaved: false)!
    private var configObserver: NSObjectProtocol?

    // Only touched on `queue`.
    private var engine: AVAudioEngine?
    /// Which device the engine was built for ("default" or a UID, plus the device it resolved to).
    private var engineKey: String?
    /// The audio configuration changed while the engine was idle: build a new one for the next start.
    private var engineStale = false
    private var running = false
    private var currentUID: String?
    /// A Bluetooth start that waits for `startDeferred()`.
    private var deferred: (generation: Int, uid: String?, keepSamples: Bool, onFailure: @MainActor () -> Void)?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var keepSamples = false
    /// Bumped by every start and stop: a queued start that finds it changed was overtaken by a stop.
    private var generation = 0

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
            self.queue.async { self.configurationChanged(source) }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func setSampleHandler(_ handler: (([Float]) -> Void)?) {
        lock.lock()
        sampleHandler = handler
        lock.unlock()
    }

    /// Starts recording in the background and returns at once. `keepSamples`: also collect the whole
    /// recording for `stop()` (only rewrite needs it; dictation gets the chunks). `deferBluetooth`:
    /// a Bluetooth microphone only opens with `startDeferred()`, once it is clearly a dictation and
    /// not a ⌥ shortcut, because opening it degrades the headset's sound. A built-in microphone starts
    /// at once, so the first word is not lost. `onFailure` runs on the main thread.
    func start(deviceUID: String?, keepSamples: Bool, deferBluetooth: Bool, onFailure: @escaping @MainActor () -> Void) {
        lock.lock()
        generation += 1
        let current = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(current) else { return }
            deferred = nil
            if deferBluetooth, let device = Self.resolve(deviceUID).device, AudioDevices.isBluetooth(device) {
                Debug.log("bluetooth microphone: start waits for the confirmation")
                deferred = (current, deviceUID, keepSamples, onFailure)
                return
            }
            startOnQueue(uid: deviceUID, keepSamples: keepSamples, onFailure: onFailure)
        }
    }

    /// Opens a Bluetooth microphone that `start` held back. Does nothing otherwise.
    func startDeferred() {
        queue.async { [self] in
            guard let pending = deferred, isCurrent(pending.generation) else { return }
            deferred = nil
            startOnQueue(uid: pending.uid, keepSamples: pending.keepSamples, onFailure: pending.onFailure)
        }
    }

    /// Stops recording and returns what was kept since `start` (empty unless `keepSamples`).
    func stop() async -> [Float] {
        invalidate()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: stopOnQueue()) }
        }
    }

    /// Stops recording and throws the audio away.
    func discard() {
        invalidate()
        queue.async { [self] in _ = stopOnQueue() }
    }

    private func invalidate() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }

    /// The device a recording would use: the chosen one if present, else the system default.
    private static func resolve(_ uid: String?) -> (device: AudioDeviceID?, explicit: Bool) {
        if let uid, let device = AudioDevices.deviceID(forUID: uid) { return (device, true) }
        return (AudioDevices.defaultInputID(), false)
    }

    private func startOnQueue(uid: String?, keepSamples: Bool, onFailure: @escaping @MainActor () -> Void) {
        guard !running else { return }
        // Set here, behind any stop still queued, which resets both.
        lock.lock()
        samples = []
        self.keepSamples = keepSamples
        lock.unlock()
        // The engine is kept between recordings (building one costs time on every press), but a
        // new one is built when the device changed: switching back to "System default", a device
        // plugged in since the last recording, or a configuration change while idle.
        let (device, explicit) = Self.resolve(uid)
        let key = "\(explicit ? uid ?? "" : "default"):\(device.map(String.init) ?? "none")"
        if engine == nil || engineStale || key != engineKey {
            engine = AVAudioEngine()
            engineKey = key
            engineStale = false
        }
        currentUID = uid
        do {
            try startEngine()
        } catch {
            // A kept engine can fail after changes nobody announced: one more try with a fresh one.
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = AVAudioEngine()
            do {
                try startEngine()
            } catch {
                Debug.log("microphone start failed: \(error)")
                engine = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { onFailure() } }
                return
            }
        }
        running = true
    }

    private func configurationChanged(_ source: ObjectIdentifier?) {
        guard let engine, source == ObjectIdentifier(engine) else { return }
        guard running else {
            engineStale = true
            return
        }
        // Headphones connected or the default input changed: continue with the new device instead
        // of silently losing the rest of the dictation.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = AVAudioEngine()
        do {
            try startEngine()
        } catch {
            running = false
            DispatchQueue.main.async { [weak self] in self?.onDeviceLost?() }
        }
    }

    private func startEngine() throws {
        guard let engine else { return }
        let input = engine.inputNode
        if let uid = currentUID, var deviceID = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Saywrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Mikrofon gefunden"])
        }
        // Each tap owns its converter: after a device change the old engine may still deliver a
        // buffer in the old format while the new one starts, so a shared converter would be raced
        // and fed the wrong format.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "Saywrite", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audioformat nicht unterstützt"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopOnQueue() -> [Float] {
        deferred = nil
        if running, let engine {
            engine.inputNode.removeTap(onBus: 0)
            // stop, not pause: only a stopped engine closes the microphone (and its menu bar dot).
            engine.stop()
        }
        running = false
        lock.lock()
        defer { lock.unlock() }
        let kept = samples
        // A long recording is not held in memory until the next one starts.
        samples = []
        keepSamples = false
        return kept
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
        if keepSamples { samples.append(contentsOf: chunk) }
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
