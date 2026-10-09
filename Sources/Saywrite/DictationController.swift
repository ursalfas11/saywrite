import AppKit
import FluidAudio
import SaywriteCore
import SaywriteLlama

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
    @Published var builtinState: BuiltinModelState = .initial(for: ModelStore().status(.qwen25_3b))
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
    private let modelStore = ModelStore()
    private let modelSpec = ModelSpec.qwen25_3b
    private var downloadTask: Task<Void, Never>?
    private var vad: VadManager?
    private let audio = AudioCapture()
    private let sounds = Sounds()
    private var startSoundPlayed = false
    private var pendingStartSound = false
    private var panelShown = false
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
    /// Cheap check for a password field at the start, so nothing is recorded into one.
    private var secureProbeTask: Task<Void, Never>?
    private var recordingStart = Date()
    private var lastVoice = Date()
    /// Last inserted dictation that has a rules-only alternative, for the "Original" button.
    private var undoCandidate: DictationResult?

    /// Hands-free recordings stop by themselves after this much silence, or at the latest here.
    private let silenceStop: TimeInterval = 60
    private let maximumRecording: TimeInterval = 10 * 60
    private static let historyRetention: TimeInterval = 30 * 86_400

    init(settings: AppSettings, state: AppState, overlay: OverlayController, history: HistoryStore) {
        self.settings = settings
        self.state = state
        self.overlay = overlay
        self.history = history
        self.hotkeys = HotkeyMonitor(dictateKey: settings.dictateKey, rewriteKey: settings.rewriteKey)
        // Dictations do not stay on disk indefinitely.
        history.removeOlder(than: Self.historyRetention)
        state.history = history.items

        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        overlay.onStop = { [weak self] in self?.stopFromOverlay() }
        overlay.onUndo = { [weak self] in self?.insertOriginal() }
        audio.onDeviceLost = { [weak self] in
            guard let self, case .recording(let action) = self.phase else { return }
            self.hotkeys.reset()
            self.requestFinish(action) // keep what was said so far
            let id = self.sessionID
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Not over a new recording or the next dictation's panel.
                guard self.sessionID == id, case .idle = self.phase else { return }
                self.showError(L("Microphone disconnected", "Mikrofon getrennt"), action: nil)
            }
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
        refreshBuiltinState()
        if settings.llmBackend == .ollama { Task { await refreshOllamaStatus() } }
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
        ollamaRefreshGeneration += 1
        let generation = ollamaRefreshGeneration
        let client = OllamaClient(configuration: settings.ollamaConfiguration)
        let models = await client.installedModels()
        // A newer refresh (the address changed meanwhile) owns the status; ignore this late answer.
        guard generation == ollamaRefreshGeneration else { return }
        guard let models else {
            state.ollamaState = .unreachable
            state.installedModels = []
            return
        }
        state.installedModels = models
        let wanted = settings.ollamaModel
        let present = models.contains { $0 == wanted || $0 == wanted + ":latest" }
        state.ollamaState = present ? .ready : .modelMissing
    }

    private var ollamaRefreshGeneration = 0

    // MARK: - Built-in model

    /// Reads the model file's state from disk, unless a download or the first load is running.
    func refreshBuiltinState() {
        guard !state.builtinState.isBusy else { return }
        state.builtinState = .initial(for: modelStore.status(modelSpec))
    }

    /// Downloads the model (or continues an interrupted download). Only ever started by a click.
    func downloadBuiltinModel() {
        guard !state.builtinState.isBusy else { return }
        let spec = modelSpec
        let store = modelStore
        let start = store.partialBytes(spec)
        state.builtinState = .downloading(Double(start) / Double(spec.size))
        downloadTask = Task { [weak self] in
            do {
                let url = try await ModelDownloader(spec: spec, store: store).run { phase in
                    Task { @MainActor [weak self] in
                        switch phase {
                        case .downloading(let progress):
                            if case .downloading = self?.state.builtinState { self?.state.builtinState = .downloading(progress.fraction) }
                        case .verifying:
                            self?.state.builtinState = .verifying
                        }
                    }
                }
                guard let self else { return }
                // Load the model once now: the first run on a Mac compiles the Metal kernels, which
                // would otherwise delay the first dictation.
                self.state.builtinState = .optimizing
                await LlamaEngine.shared.prewarm(modelURL: url, language: self.prewarmLanguage, forRewrite: false)
                self.state.builtinState = LlamaEngine.shared.isLoaded ? .ready : .failed(L("The model could not be loaded", "Das Modell konnte nicht geladen werden"))
            } catch is CancellationError {
                self?.state.builtinState = .initial(for: store.status(spec))
            } catch {
                Debug.log("model download failed: \(error)")
                let partial = store.status(spec)
                // An interrupted connection leaves the partial file: show it as paused, with the reason.
                if case .partial = partial, (error as? ModelDownloadError) == .incomplete {
                    self?.state.builtinState = .failed(L("Download interrupted – continue to resume", "Download unterbrochen – Fortsetzen macht weiter"))
                } else {
                    self?.state.builtinState = .failed(error.localizedDescription)
                }
            }
            self?.downloadTask = nil
        }
    }

    /// Stops a running download; the partial file stays, so it can be continued.
    func pauseBuiltinDownload() {
        downloadTask?.cancel()
    }

    /// Deletes the model file and what is left of a download.
    func deleteBuiltinModel() {
        downloadTask?.cancel()
        downloadTask = nil
        let spec = modelSpec
        let store = modelStore
        state.builtinState = .notDownloaded
        Task {
            await LlamaEngine.shared.unload()
            store.delete(spec)
        }
    }

    /// Called when the backend setting changes: the built-in model leaves memory when Ollama takes over.
    func backendChanged() {
        switch settings.llmBackend {
        case .builtin:
            refreshBuiltinState()
        case .ollama:
            Task { await LlamaEngine.shared.unload() }
            Task { await refreshOllamaStatus() }
        }
    }

    private var prewarmLanguage: DictationLanguage {
        // Prime the prompt of the language that was dictated last (or the fixed setting).
        switch settings.language {
        case "de": return .german
        case "en": return .english
        default: return DictationLanguage.lastDetected ?? (UILanguage.isGerman ? .german : .english)
        }
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
        switch settings.llmBackend {
        case .builtin:
            return LlamaClient(modelURL: modelStore.fileURL(modelSpec), cleanupTimeout: settings.llmTimeout, prewarmLanguage: prewarmLanguage)
        case .ollama:
            var configuration = settings.ollamaConfiguration
            configuration.prewarmLanguage = prewarmLanguage
            return OllamaClient(configuration: configuration)
        }
    }

    /// Runs once per session, as soon as it is clear the user really dictates.
    private func prepare(_ action: HotkeyAction) {
        guard !prepared else { return }
        prepared = true
        if let llm { Task.detached { await llm.prewarm(forRewrite: action == .rewrite) } }
        if action == .rewrite { selectionTask = Task { await TextInserter.selectedText() } }
        // Nothing is recorded, transcribed or sent to the AI server for a password field.
        let id = sessionID
        secureProbeTask = Task { [weak self] in
            guard await TextInserter.focusIsSecureField() else { return }
            guard let self, !Task.isCancelled, self.sessionID == id, case .recording = self.phase else { return }
            self.hotkeys.reset()
            self.cancel()
            self.showError(L("Password field – not recorded", "Passwortfeld – nicht aufgenommen"), action: nil)
        }
    }

    private func begin(_ action: HotkeyAction, handsFree: Bool) {
        guard case .idle = phase else {
            // Still busy with the previous text: ignore this press, but say so instead of
            // letting the user talk into nothing.
            Debug.log("press ignored: still inserting the previous text")
            if settings.playSounds { NSSound.beep() }
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

        sessionID = UUID()
        sessionApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let style = settings.styleMap.style(for: sessionApp)
        // Where a password field may be invisible to Accessibility, secure input is the only hint:
        // then the text stays in this process (rules only) instead of going to the AI server.
        let isElectron = NSWorkspace.shared.frontmostApplication.map(TextInserter.isElectron) ?? false
        let withholdAI = TextInserter.secureInputActive
            && PasteTargetRules.secureFieldMayBeInvisible(bundleID: sessionApp ?? "", isElectron: isElectron)
        let session = DictationSession(
            transcriber: transcriber, llm: withholdAI ? nil : llm, style: style, appBundleID: sessionApp,
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
        startPreview(session: session, segmenter: segmenter, id: sessionID)
    }

    private func showRecordingOverlay(_ action: HotkeyAction, handsFree: Bool) {
        if !panelShown {
            // Only now it is certain this is a dictation, not a ⌥ shortcut: replace the last panel.
            panelShown = true
            undoCandidate = nil
            overlay.model.reset()
            overlay.model.isRewrite = action == .rewrite
        }
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

    /// Watches a running recording and stops a forgotten one after a long silence or at the maximum
    /// length. The panel shows no live transcript, so nothing is transcribed here.
    private func startPreview(session: DictationSession, segmenter: Segmenter, id: UUID) {
        previewTask = Task { [weak self] in
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
        secureProbeTask?.cancel()
        if let session { Task { await session.cancel() } }
        let wasShown = panelShown
        teardown()
        // A cancelled ⌥ shortcut must not close the panel of the previous dictation.
        if wasShown { overlay.show(.hidden) }
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
        panelShown = false
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
        let outcome = await TextInserter.insert(result.final, expectedApp: sessionApp, onPasted: { [weak self] in
            // Sound and panel react the moment the text lands, not after the clipboard restore.
            guard let self else { return }
            if self.settings.playSounds { self.sounds.playStop() }
            let undo = hasOriginal && TextInserter.lastPasteSupportsUndo
            if !undo { self.undoCandidate = nil }
            self.overlay.show(.done(result.summary.text, undo: undo))
            self.readyForNext(id)
        })
        // Something dictated into a password field is not written to the history file.
        if outcome != .secureField { appendToHistory(result) }
        switch outcome {
        case .pasted:
            break
        case .copiedToClipboard:
            overlay.show(.done(L("No text field – copied, press ⌘V", "Kein Textfeld – kopiert, ⌘V drücken"), undo: false))
        case .appChanged:
            undoCandidate = nil
            overlay.show(.done(Self.appChangedMessage, undo: false))
        case .copiedSecureInput:
            undoCandidate = nil
            overlay.show(.done(Self.secureInputMessage, undo: false))
        case .secureField:
            undoCandidate = nil
            showError(L("Password field – not inserted and not saved", "Passwortfeld – nicht eingefügt und nicht gespeichert"), action: nil)
        }
    }

    private func appendToHistory(_ result: DictationResult) {
        guard settings.keepHistory else { return }
        history.removeOlder(than: Self.historyRetention)
        history.append(result)
        state.history = history.items
    }

    /// Replace the text just inserted with the version without AI.
    private func insertOriginal() {
        guard let result = undoCandidate, let original = result.withoutAI else { return }
        undoCandidate = nil
        overlay.model.committedText = original
        // ⌘Z only makes sense in the app that received the text; otherwise just offer the original.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == result.appBundleID else {
            TextInserter.copy(original)
            overlay.show(.done(L("Original copied – press ⌘V", "Original kopiert – ⌘V drücken"), undo: false))
            return
        }
        TextInserter.undo()
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            switch await TextInserter.insert(original, expectedApp: result.appBundleID, recordsUndo: false) {
            case .pasted: overlay.show(.done(L("Original inserted", "Original eingefügt"), undo: false))
            case .copiedToClipboard, .appChanged, .copiedSecureInput: overlay.show(.done(L("Original copied – press ⌘V", "Original kopiert – ⌘V drücken"), undo: false))
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    private func finishRewrite(samples: [Float], id: UUID) async {
        let app = sessionApp
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
            // The selection may have changed while the model worked: then the paste would overwrite
            // other text, so the rewrite is copied instead.
            let stillSelected = PasteTargetRules.rewriteMayReplace(captured: selection, current: await TextInserter.currentSelection())
            let outcome: InsertOutcome
            var selectionChanged = false
            if stillSelected {
                outcome = await TextInserter.insert(rewritten, expectedApp: app, onPasted: { [weak self] in
                    guard let self else { return }
                    if self.settings.playSounds { self.sounds.playStop() }
                    self.overlay.show(.done(L("Rewritten", "Umformuliert"), undo: false))
                    self.readyForNext(id)
                })
            } else {
                TextInserter.copy(rewritten)
                selectionChanged = true
                outcome = .copiedToClipboard
            }
            let summary = ChangeSummarizer.summarize(raw: selection, final: rewritten, usedLLM: true, llmFailed: false)
            let result = DictationResult(
                raw: HistoryStore.rewriteRaw(instruction: instruction), final: rewritten, style: .neutral,
                appBundleID: app, summary: summary, latency: 0)
            if outcome != .secureField { appendToHistory(result) }
            switch outcome {
            case .pasted: break
            case .copiedToClipboard where selectionChanged:
                overlay.show(.done(L("Selection changed – rewrite copied, press ⌘V", "Markierung geändert – Umformulierung kopiert, ⌘V drücken"), undo: false))
            case .copiedToClipboard: overlay.show(.done(L("Rewritten – copied, press ⌘V", "Umformuliert – kopiert, ⌘V drücken"), undo: false))
            case .copiedSecureInput: overlay.show(.done(Self.secureInputMessage, undo: false))
            case .appChanged: overlay.show(.done(Self.appChangedMessage, undo: false))
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        } catch LLMError.rejectedOutput {
            showError(L("AI answer did not look like a rewrite – text unchanged", "KI-Antwort war keine Umformulierung – Text unverändert"), action: nil)
        } catch {
            showError(L("AI not reachable – text unchanged", "KI nicht erreichbar – Text unverändert"), action: nil)
        }
    }

    private static var secureInputMessage: String {
        L("Secure input active – copied, press ⌘V", "Gesicherte Eingabe aktiv – kopiert, ⌘V drücken")
    }

    private static var appChangedMessage: String {
        L("Other app in front – copied, press ⌘V", "Andere App im Vordergrund – kopiert, ⌘V drücken")
    }

    private func teardown() {
        phase = .idle
        prepared = false
        startSoundPlayed = false
        pendingStartSound = false
        panelShown = false
        session = nil
        segmenter = nil
        chunkStream = nil
        chunkConsumer = nil
        selectionTask = nil
        secureProbeTask = nil
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
        guard let last = history.items.first else {
            overlay.show(.done(L("Nothing to paste (history empty or off)", "Nichts einzufügen (Verlauf leer oder aus)"), undo: false))
            return
        }
        // Not while a dictation is recording or being inserted: it would paste in between and mix up
        // the clipboard handling of that session.
        guard case .idle = phase else {
            overlay.show(.done(L("Busy – try again in a moment", "Gerade beschäftigt – gleich nochmal versuchen"), undo: false))
            return
        }
        Task {
            // Give the menu time to close so the previous app has focus again.
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch await TextInserter.insert(last.final, recordsUndo: false) {
            case .pasted: break
            case .copiedSecureInput: overlay.show(.done(Self.secureInputMessage, undo: false))
            case .copiedToClipboard, .appChanged: overlay.show(.done(L("No text field – copied, press ⌘V", "Kein Textfeld – kopiert, ⌘V drücken"), undo: false))
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    func clearHistory() {
        history.clear()
        state.history = []
    }
}
