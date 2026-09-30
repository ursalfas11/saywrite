import AppKit
import FluidAudio
import SaywriteCore

/// Observable app status for the menu and settings window.
@MainActor
final class AppState: ObservableObject {
    enum ModelState: Equatable {
        case loading(Double)
        case ready
        case failed(String)
    }

    enum OllamaState: Equatable {
        case unknown
        case unreachable
        case modelMissing
        case ready
    }

    @Published var modelState: ModelState = .loading(0)
    @Published var ollamaState: OllamaState = .unknown
    @Published var accessibilityGranted = Permissions.accessibilityGranted
    @Published var microphoneGranted = Permissions.microphoneStatus == .granted
    @Published var history: [DictationResult] = []
    @Published var installedModels: [String] = []
}

/// Runs dictation and rewrite sessions: hotkey -> audio -> segments -> text -> insertion.
@MainActor
final class DictationController {
    let settings: AppSettings
    let state: AppState
    let overlay: OverlayController
    let history: HistoryStore
    let hotkeys: HotkeyMonitor

    private let transcriber = ParakeetTranscriber()
    private var vad: VadManager?
    private let audio = AudioCapture()
    private let sounds = Sounds()
    private var startSoundPlayed = false
    private var pendingStartSound = false
    private var audioFlowing = false
    private var peakLevel: Float = 0

    private enum Phase { case idle, recording(HotkeyAction), processing }
    private var phase: Phase = .idle
    /// Identifies the current session so late async work from an old one is ignored.
    private var sessionID = UUID()
    private var session: DictationSession?
    private var segmenter: Segmenter?
    private var chunkStream: AsyncStream<[Float]>.Continuation?
    private var chunkConsumer: Task<Void, Never>?
    private var selectionTask: Task<String?, Never>?
    private var errorAction: (() -> Void)?
    private var prepared = false
    private var previewTask: Task<Void, Never>?
    private var sessionApp: String?
    private var recordingStart = Date()
    private var lastVoice = Date()
    /// Last inserted dictation that has a rules-only alternative, for the "Original" button.
    private var undoCandidate: DictationResult?

    /// Hands-free recordings stop by themselves after this much silence, or at the latest here.
    private let silenceStop: TimeInterval = 60
    private let maximumRecording: TimeInterval = 10 * 60

    init(settings: AppSettings, state: AppState, overlay: OverlayController, history: HistoryStore) {
        self.settings = settings
        self.state = state
        self.overlay = overlay
        self.history = history
        self.hotkeys = HotkeyMonitor(dictateKey: settings.dictateKey, rewriteKey: settings.rewriteKey)
        state.history = history.items

        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        overlay.onStop = { [weak self] in self?.stopFromOverlay() }
        overlay.onUndo = { [weak self] in self?.insertOriginal() }
        audio.onDeviceLost = { [weak self] in
            guard let self, case .recording(let action) = self.phase else { return }
            self.hotkeys.reset()
            self.requestFinish(action) // keep what was said so far
            self.showError(L("Microphone disconnected", "Mikrofon getrennt"), action: nil)
        }
        overlay.onErrorClick = { [weak self] in
            self?.errorAction?()
            self?.overlay.show(.hidden)
        }
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                self.overlay.model.push(level: level)
                if level > 0.25 { self.lastVoice = Date() }
                self.peakLevel = max(self.peakLevel, level)
                if !self.audioFlowing {
                    self.audioFlowing = true
                    // The start sound waits for real audio, so nobody talks into a mic that is not open yet.
                    if self.pendingStartSound { self.playStartSound() }
                }
            }
        }
    }

    // MARK: - Startup

    func start() {
        hotkeys.start()
        Task { await loadModels() }
        Task { await refreshOllamaStatus() }
    }

    private func loadModels() async {
        Debug.log("loading speech model")
        state.modelState = .loading(0)
        await transcriber.setLanguage(settings.language)
        do {
            try await transcriber.load { [weak self] progress in
                Task { @MainActor in
                    if case .loading = self?.state.modelState { self?.state.modelState = .loading(progress) }
                }
            }
            state.modelState = .ready
            Debug.log("speech model ready")
        } catch {
            Debug.log("speech model failed: \(error)")
            state.modelState = .failed(error.localizedDescription)
        }
        // The VAD only enables instant text; without it everything is transcribed at the end.
        vad = try? await VadManager(config: VadConfig(defaultThreshold: 0.6))
    }

    func retryModelLoad() {
        Task { await loadModels() }
    }

    func refreshOllamaStatus() async {
        let client = OllamaClient(configuration: settings.ollamaConfiguration)
        guard let models = await client.installedModels() else {
            state.ollamaState = .unreachable
            state.installedModels = []
            return
        }
        state.installedModels = models
        let wanted = settings.ollamaModel
        let present = models.contains { $0 == wanted || $0 == wanted + ":latest" }
        state.ollamaState = present ? .ready : .modelMissing
    }

    func applySettings() {
        hotkeys.dictateKey = settings.dictateKey
        hotkeys.rewriteKey = settings.rewriteKey
        Task { await transcriber.setLanguage(settings.language) }
    }

    /// Re-create the event tap, e.g. after Accessibility was granted.
    func restartHotkeys() {
        hotkeys.start()
    }

    var hotkeysActive: Bool { hotkeys.isRunning }

    // MARK: - Events

    private func handle(_ event: HotkeyEvent) {
        Debug.log("hotkey \(event)")
        switch event {
        case .begin(let action):
            begin(action, handsFree: false)
        case .handsFree(let action):
            if case .recording(let current) = phase, current == action {
                showRecordingOverlay(action, handsFree: true)
                prepare(action)
            }
        case .confirmed(let action):
            if case .recording(let current) = phase, current == action {
                showRecordingOverlay(action, handsFree: false)
                prepare(action)
            }
        case .end(let action):
            requestFinish(action)
        case .cancel(let action):
            if case .recording(let current) = phase, current == action { cancel() }
        }
    }

    private var llm: LLMClient? {
        guard settings.aiEnabled else { return nil }
        var configuration = settings.ollamaConfiguration
        // Prime the prompt of the language that was dictated last (or the fixed setting).
        switch settings.language {
        case "de": configuration.prewarmLanguage = .german
        case "en": configuration.prewarmLanguage = .english
        default: configuration.prewarmLanguage = DictationLanguage.lastDetected ?? (UILanguage.isGerman ? .german : .english)
        }
        return OllamaClient(configuration: configuration)
    }

    /// Runs once per session, as soon as it is clear the user really dictates.
    private func prepare(_ action: HotkeyAction) {
        guard !prepared else { return }
        prepared = true
        if let llm { Task.detached { await llm.prewarm(forRewrite: action == .rewrite) } }
        if action == .rewrite { selectionTask = Task { await TextInserter.selectedText() } }
    }

    private func begin(_ action: HotkeyAction, handsFree: Bool) {
        guard case .idle = phase else {
            // Still busy with the previous text: ignore this press completely.
            hotkeys.reset()
            return
        }
        guard state.modelState == .ready else {
            if case .loading(let progress) = state.modelState {
                showError(L("Speech model is loading (\(Int(progress * 100))%) – almost ready", "Sprachmodell wird geladen (\(Int(progress * 100)) %) – gleich geht's los"), action: nil)
            } else {
                showError(L("Speech model not available", "Sprachmodell nicht verfügbar"), action: nil)
            }
            hotkeys.reset()
            return
        }

        undoCandidate = nil
        sessionID = UUID()
        sessionApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let style = settings.styleMap.style(for: sessionApp)
        let session = DictationSession(
            transcriber: transcriber, llm: llm, style: style, appBundleID: sessionApp,
            language: settings.language, replacements: settings.replacements)
        let segmenter = Segmenter(vad: action == .dictate ? vad : nil)
        self.session = session
        self.segmenter = segmenter

        // Chunks are consumed strictly in order by a single task.
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        chunkStream = continuation
        chunkConsumer = Task.detached {
            await segmenter.reset()
            for await chunk in stream {
                for segment in await segmenter.append(chunk) {
                    await session.addSegment(segment)
                }
            }
        }
        audio.setSampleHandler { chunk in continuation.yield(chunk) }
        audio.preferredDeviceUID = settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID

        do {
            try audio.start()
        } catch {
            audio.setSampleHandler(nil)
            continuation.finish()
            teardown()
            hotkeys.reset()
            if Permissions.microphoneStatus != .granted {
                showError(L("No microphone access", "Mikrofon-Zugriff fehlt"), action: Permissions.openMicrophoneSettings)
            } else {
                showError(L("Microphone could not start", "Mikrofon konnte nicht starten"), action: nil)
            }
            return
        }
        phase = .recording(action)
        recordingStart = Date()
        lastVoice = Date()
        audioFlowing = false
        peakLevel = 0

        // Right ⌥ is also used for @, € and brackets: the panel and sound only appear once it is
        // clearly a dictation (tap for hands-free, or held past the shortcut window).
        overlay.model.reset()
        overlay.model.isRewrite = action == .rewrite
        startPreview(session: session, segmenter: segmenter, id: sessionID)
    }

    private func showRecordingOverlay(_ action: HotkeyAction, handsFree: Bool) {
        overlay.show(.recording(handsFree: handsFree, rewrite: action == .rewrite))
        // The sound comes together with the panel, once per recording, and only with live audio.
        if audioFlowing { playStartSound() } else { pendingStartSound = true }
    }

    private func playStartSound() {
        pendingStartSound = false
        guard !startSoundPlayed, case .recording = phase else { return }
        startSoundPlayed = true
        if settings.playSounds { sounds.playStart() }
    }

    /// Shows what is being said while recording: finished segments in their cleaned form, plus a
    /// quick transcript of the recent audio since the last pause. Also stops forgotten recordings.
    private func startPreview(session: DictationSession, segmenter: Segmenter, id: UUID) {
        let transcriber = self.transcriber
        previewTask = Task { [weak self] in
            var lastTotal = 0
            var partial = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, self.sessionID == id, case .recording(let action) = self.phase else { return }

                let now = Date()
                if now.timeIntervalSince(self.lastVoice) > self.silenceStop || now.timeIntervalSince(self.recordingStart) > self.maximumRecording {
                    Debug.log("auto stop: silence or maximum length")
                    self.hotkeys.reset()
                    self.requestFinish(action)
                    return
                }

                let committed = await session.previewText()
                let open = await segmenter.openAudio()
                if open.totalCount < 8_000 {
                    partial = ""
                } else if open.totalCount != lastTotal, await segmenter.isSpeaking {
                    // Only re-transcribe while speech is going on; silence changes nothing.
                    lastTotal = open.totalCount
                    partial = (try? await transcriber.transcribe(open.samples)) ?? partial
                }
                guard !Task.isCancelled, self.sessionID == id, case .recording = self.phase else { return }
                self.overlay.model.committedText = committed
                self.overlay.model.partialText = partial
            }
        }
    }

    private func stopFromOverlay() {
        guard case .recording(let action) = phase else { return }
        hotkeys.reset()
        requestFinish(action)
    }

    /// Switches to processing synchronously, so a second stop (key + button) cannot finish twice.
    private func requestFinish(_ action: HotkeyAction) {
        guard case .recording(let current) = phase, current == action else { return }
        phase = .processing
        previewTask?.cancel()
        if !prepared { prepare(action) }
        Task { await finish(action) }
    }

    private func cancel() {
        previewTask?.cancel()
        audio.stop()
        audio.setSampleHandler(nil)
        chunkStream?.finish()
        chunkConsumer?.cancel()
        selectionTask?.cancel()
        if let session { Task { await session.cancel() } }
        teardown()
        overlay.show(.hidden)
    }

    private func finish(_ action: HotkeyAction) async {
        let id = sessionID
        overlay.show(.processing)
        // Keep recording a moment so the last syllable is not cut off.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let allSamples = audio.stop()
        audio.setSampleHandler(nil)
        chunkStream?.finish()
        await chunkConsumer?.value

        switch action {
        case .dictate:
            await finishDictation(id: id)
        case .rewrite:
            await finishRewrite(samples: allSamples, id: id)
        }
        // A new dictation may already have started right after the paste.
        if sessionID == id { teardown() }
    }

    /// Ready for the next dictation as soon as the text landed (the clipboard restore runs on).
    private func readyForNext(_ id: UUID) {
        guard sessionID == id, case .processing = phase else { return }
        phase = .idle
        prepared = false
        startSoundPlayed = false
    }

    private func finishDictation(id: UUID) async {
        guard let session, let segmenter else {
            overlay.show(.hidden)
            return
        }
        if let rest = await segmenter.flush() {
            await session.addSegment(rest)
        }
        guard let result = await session.finish() else {
            if peakLevel < 0.05 {
                showError(L("No sound from the microphone – check the input device", "Kein Ton vom Mikrofon – Eingabegerät prüfen"),
                          action: Permissions.openMicrophoneSettings)
            } else {
                overlay.show(.done(L("Nothing heard", "Nichts gehört"), undo: false))
            }
            return
        }
        overlay.model.committedText = result.final
        overlay.model.partialText = ""
        let hasOriginal = result.withoutAI != nil
        if hasOriginal { undoCandidate = result }
        let outcome = await TextInserter.insert(result.final, onPasted: { [weak self] in
            // Sound and panel react the moment the text lands, not after the clipboard restore.
            guard let self else { return }
            if self.settings.playSounds { self.sounds.playStop() }
            self.overlay.show(.done(result.summary.text, undo: hasOriginal))
            self.readyForNext(id)
        })
        history.append(result)
        state.history = history.items
        switch outcome {
        case .pasted:
            break
        case .copiedToClipboard:
            overlay.show(.done(L("No text field – copied, press ⌘V", "Kein Textfeld – kopiert, ⌘V drücken"), undo: false))
        case .secureField:
            showError(L("Password field – not inserted. The text is in the history.", "Passwortfeld – nicht eingefügt. Der Text steht im Verlauf."), action: nil)
        }
    }

    /// Replace the text just inserted with the version without AI.
    private func insertOriginal() {
        guard let result = undoCandidate, let original = result.withoutAI else { return }
        undoCandidate = nil
        overlay.model.committedText = original
        // ⌘Z only makes sense in the app that received the text; otherwise just offer the original.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == result.appBundleID else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(original, forType: .string)
            overlay.show(.done(L("Original copied – press ⌘V", "Original kopiert – ⌘V drücken"), undo: false))
            return
        }
        TextInserter.undo()
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            switch await TextInserter.insert(original) {
            case .pasted: overlay.show(.done(L("Original inserted", "Original eingefügt"), undo: false))
            case .copiedToClipboard: overlay.show(.done(L("Original copied – press ⌘V", "Original kopiert – ⌘V drücken"), undo: false))
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    private func finishRewrite(samples: [Float], id: UUID) async {
        let selection = await selectionTask?.value
        guard let selection else {
            showError(L("No text selected", "Kein Text markiert"), action: nil)
            return
        }
        guard let llm else {
            showError(L("AI is turned off in settings", "KI ist in den Einstellungen aus"), action: nil)
            return
        }
        guard samples.count >= 16_000 / 3,
              let instruction = try? await transcriber.transcribe(samples),
              !instruction.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            overlay.show(.hidden)
            return
        }
        do {
            overlay.model.committedText = instruction
            overlay.model.partialText = ""
            let rewritten = try await llm.rewrite(selection: selection, instruction: instruction)
            let outcome = await TextInserter.insert(rewritten, onPasted: { [weak self] in
                guard let self else { return }
                if self.settings.playSounds { self.sounds.playStop() }
                self.overlay.show(.done(L("Rewritten", "Umformuliert"), undo: false))
                self.readyForNext(id)
            })
            let summary = ChangeSummarizer.summarize(raw: selection, final: rewritten, usedLLM: true, llmFailed: false)
            let result = DictationResult(
                raw: "[\(instruction)] \(selection)", final: rewritten, style: .neutral,
                appBundleID: sessionApp, summary: summary, latency: 0)
            history.append(result)
            state.history = history.items
            switch outcome {
            case .pasted: break
            case .copiedToClipboard: overlay.show(.done(L("Rewritten – copied, press ⌘V", "Umformuliert – kopiert, ⌘V drücken"), undo: false))
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        } catch {
            showError(L("AI not reachable – text unchanged", "KI nicht erreichbar – Text unverändert"), action: nil)
        }
    }

    private func teardown() {
        phase = .idle
        prepared = false
        startSoundPlayed = false
        pendingStartSound = false
        session = nil
        segmenter = nil
        chunkStream = nil
        chunkConsumer = nil
        selectionTask = nil
        previewTask = nil
    }

    private func showError(_ message: String, action: (() -> Void)?) {
        errorAction = action
        overlay.model.errorActionable = action != nil
        overlay.show(.error(message))
    }

    // MARK: - Menu actions

    /// Paste the most recent dictation again at the cursor.
    func pasteLast() {
        guard let last = history.items.first else { return }
        Task {
            // Give the menu time to close so the previous app has focus again.
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = await TextInserter.insert(last.final)
        }
    }

    func clearHistory() {
        history.clear()
        state.history = []
    }
}
