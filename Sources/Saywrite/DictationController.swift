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
    private var phase: Phase = .idle {
        didSet { phaseChanged() }
    }
    /// The work after the release, kept so Esc (or a cancel) can stop it before anything is inserted.
    private var finishTask: Task<Void, Never>?
    /// Keeps the display awake during a recording (see `prepare`).
    private var recordingActivity: NSObjectProtocol?
    /// Debug timing of the current finish, from the release of the key.
    private var timing: FinishTiming?
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
    /// The probe of this session found a password field.
    private var secureFieldSeen = false
    /// Secure input hides a possible password field from Accessibility: the AI server gets nothing.
    private var sessionWithholdAI = false
    private var recordingStart = Date()
    private var lastVoice = Date()
    /// Last inserted dictation that has a rules-only alternative, for the "Original" button.
    private var undoCandidate: DictationResult?
    /// Keys the user pressed since the last paste: after typing, ⌘Z would undo the typing.
    private var keysSinceInsert = 0
    /// The session that stopped by itself (silence or maximum length): its text is not inserted.
    private var autoStoppedSession: UUID?
    /// The text of the last automatically stopped dictation, for the "Insert" button of its pill.
    private var pendingAutoStop: PendingInsert?
    /// Opens the settings window (set by the app delegate), for errors whose fix is there.
    var openSettings: (() -> Void)?

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
        hotkeys.onProcessingEscape = { [weak self] in self?.cancelProcessing() }
        hotkeys.onKeyDown = { [weak self] event in self?.userPressedKey(event) }
        overlay.onStop = { [weak self] in self?.stopFromOverlay() }
        overlay.onUndo = { [weak self] in self?.insertOriginal() }
        overlay.onCancel = { [weak self] in self?.cancelFromOverlay() }
        overlay.onInsertPending = { [weak self] in self?.insertPendingAutoStop() }
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
        state.builtinState = .downloading(Double(store.partialBytes(spec)) / Double(spec.size))
        let pendingDelete = deleteTask
        let retired = retiredDownload
        downloadGeneration += 1
        let generation = downloadGeneration
        downloadTask = Task {
            // A delete that is still queued behind the engine must finish first, or it would remove
            // the files of this download. So must a download that a delete cancelled: it may still
            // be winding down on the same .part file.
            await retired?.value
            await pendingDelete?.value
            // Whatever this task writes below counts only while it is the current download.
            let isCurrent = { self.downloadGeneration == generation }
            guard isCurrent() else { return }
            do {
                let url = try await ModelDownloader(spec: spec, store: store).run { phase in
                    Task { @MainActor in if isCurrent() { self.applyDownload(phase) } }
                }
                guard isCurrent() else { return }
                // Load the model once now: the first run on a Mac compiles the Metal kernels, which
                // would otherwise delay the first dictation.
                if settings.llmBackend == .builtin {
                    state.builtinState = .optimizing
                    let loaded = await LlamaEngine.shared.prewarm(modelURL: url, language: prewarmLanguage, forRewrite: false)
                    // Deleted while the model was being optimized: the delete owns the state now.
                    guard isCurrent() else { return }
                    if settings.llmBackend != .builtin {
                        // Switched to Ollama during the prewarm: the engine unloads the model again.
                        state.builtinState = .initial(for: store.status(spec))
                    } else {
                        // Failed only when the load itself failed; an unload by memory pressure after a
                        // successful load leaves a valid model that loads again on demand.
                        state.builtinState = loaded ? .ready : .failed(L("The model could not be loaded", "Das Modell konnte nicht geladen werden"))
                    }
                } else {
                    // Switched to Ollama meanwhile: the model stays on disk, not in memory.
                    state.builtinState = .initial(for: store.status(spec))
                }
            } catch is CancellationError {
                if isCurrent() { state.builtinState = .initial(for: store.status(spec)) }
            } catch {
                Debug.log("model download failed: \(error)")
                guard isCurrent() else { return }
                // An interrupted connection leaves the partial file: say so, the button continues it.
                if (error as? ModelDownloadError) == .incomplete {
                    state.builtinState = .failed(L("Download interrupted – Resume continues it", "Download unterbrochen – Fortsetzen macht weiter"))
                } else {
                    state.builtinState = .failed(error.localizedDescription)
                }
            }
            if isCurrent() { downloadTask = nil }
        }
    }

    /// Bumped by every download and every delete: a task that finds it changed is outdated and
    /// must not touch the state or `downloadTask`.
    private var downloadGeneration = 0
    /// The download a delete cancelled, until the next download has waited for it.
    private var retiredDownload: Task<Void, Never>?

    private func applyDownload(_ phase: ModelDownloader.Phase) {
        switch phase {
        case .downloading(let progress):
            if case .downloading = state.builtinState { state.builtinState = .downloading(progress.fraction) }
        case .verifying:
            // Late updates must not overwrite .optimizing or a finished state.
            if case .downloading = state.builtinState { state.builtinState = .verifying }
        }
    }

    /// Stops a running download; the partial file stays, so it can be continued.
    func pauseBuiltinDownload() {
        downloadTask?.cancel()
    }

    /// Deletes the model file and what is left of a download.
    private var deleteTask: Task<Void, Never>?

    func deleteBuiltinModel() {
        downloadTask?.cancel()
        if let running = downloadTask { retiredDownload = running }
        downloadTask = nil
        downloadGeneration += 1
        let spec = modelSpec
        let store = modelStore
        state.builtinState = .notDownloaded
        let previous = deleteTask
        deleteTask = Task {
            await previous?.value
            await LlamaEngine.shared.unloadThenRun { store.delete(spec) }
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
            if case .recording(let current) = phase, current == action, !rewriteBlocked(action) {
                showRecordingOverlay(action, handsFree: true)
                prepare(action)
                watchSelection(action)
            }
        case .confirmed(let action):
            if case .recording(let current) = phase, current == action, !rewriteBlocked(action) {
                showRecordingOverlay(action, handsFree: false)
                prepare(action)
                watchSelection(action)
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

    /// A rewrite that cannot run is stopped as soon as it is clearly a rewrite, before the user speaks
    /// the instruction. Not earlier: right ⌘ alone is also every right-⌘ shortcut.
    private func rewriteBlocked(_ action: HotkeyAction) -> Bool {
        guard action == .rewrite, let blocker = RewriteBlocker.check(
            aiEnabled: settings.aiEnabled, builtinBackend: settings.llmBackend == .builtin,
            modelInstalled: modelStore.isInstalled(modelSpec), withholdAI: sessionWithholdAI) else { return false }
        hotkeys.reset()
        cancel()
        let settingsAction: () -> Void = { [weak self] in self?.openSettings?() }
        switch blocker {
        case .aiOff:
            showError(L("Rewriting needs the AI – it is off in settings", "Umformulieren braucht die KI – sie ist in den Einstellungen aus"),
                      action: settingsAction, actionTitle: L("Settings", "Einstellungen"))
        case .modelMissing:
            showError(L("Rewriting needs the AI model – download it in settings", "Umformulieren braucht das KI-Modell – in den Einstellungen laden"),
                      action: settingsAction, actionTitle: L("Settings", "Einstellungen"))
        case .secureInput:
            showError(L("Secure input active – AI off", "Gesicherte Eingabe aktiv – KI aus"), action: nil)
        }
        return true
    }

    /// Without a selection there is nothing to rewrite: say so while the user is still about to speak.
    private func watchSelection(_ action: HotkeyAction) {
        guard action == .rewrite, let task = selectionTask else { return }
        let id = sessionID
        Task { [weak self] in
            let selection = await task.value
            guard selection == nil, let self, self.sessionID == id, case .recording = self.phase else { return }
            self.hotkeys.reset()
            self.cancel()
            self.showError(L("No text selected – select text, then try again", "Kein Text markiert – erst Text markieren"), action: nil)
        }
    }

    /// Runs once per session, as soon as it is clear the user really dictates.
    private func prepare(_ action: HotkeyAction) {
        guard !prepared else { return }
        prepared = true
        if case .recording = phase {
            // A Bluetooth microphone opens only now (see AudioCapture.start).
            audio.startDeferred()
            // The Neural Engine sleeps after some idle time; wake it while the user still talks.
            let transcriber = transcriber
            Task.detached { await transcriber.prewarm() }
            // A long hands-free dictation without touching the Mac must not run into display sleep,
            // which cancels the recording (see cancelRecording).
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "Dictation recording")
        }
        if let llm {
            // Switching the engine in the settings meanwhile must not load the built-in model again.
            let backend = settings.llmBackend
            Task.detached { [weak self] in
                let current = await MainActor.run { self?.settings.llmBackend }
                guard current == backend else { return }
                await llm.prewarm(forRewrite: action == .rewrite)
            }
        }
        if action == .rewrite { selectionTask = Task { await TextInserter.selectedText() } }
        // Nothing is recorded, transcribed or sent to the AI server for a password field.
        let id = sessionID
        secureProbeTask = Task { [weak self] in
            guard await TextInserter.focusIsSecureField() else { return }
            guard let self, !Task.isCancelled, self.sessionID == id else { return }
            self.secureFieldSeen = true
            // A short press is already processing: finish() waits for this probe and stops there.
            guard case .recording = self.phase else { return }
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
                // A failed load (no network on first launch, a full disk) is retried on the press
                // instead of failing the same way until the app restarts.
                retryModelLoad()
                showError(L("Speech model not available – loading again", "Sprachmodell nicht verfügbar – wird neu geladen"),
                          action: { [weak self] in self?.openSettings?() }, actionTitle: L("Settings", "Einstellungen"))
            }
            hotkeys.reset()
            return
        }
        // Known before anything starts: a denied microphone would only fail in audio.start().
        switch Permissions.microphoneStatus {
        case .granted:
            break
        case .denied:
            showError(L("No microphone access", "Mikrofon-Zugriff fehlt"), action: Permissions.openMicrophoneSettings,
                      actionTitle: L("Open settings", "Einstellungen öffnen"))
            hotkeys.reset()
            return
        case .undetermined:
            hotkeys.reset()
            Task {
                let granted = await Permissions.requestMicrophone()
                state.microphoneGranted = granted
                if granted {
                    overlay.show(.notice(L("Microphone allowed – tap again to dictate", "Mikrofon erlaubt – nochmal tippen zum Diktieren"), symbol: "mic.badge.plus"))
                } else {
                    showError(L("No microphone access", "Mikrofon-Zugriff fehlt"), action: Permissions.openMicrophoneSettings,
                              actionTitle: L("Open settings", "Einstellungen öffnen"))
                }
            }
            return
        }

        sessionID = UUID()
        secureFieldSeen = false
        sessionApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let style = settings.styleMap.style(for: sessionApp)
        // Where a password field may be invisible to Accessibility, secure input is the only hint:
        // then the text stays in this process (rules only) instead of going to the AI server.
        let isElectron = NSWorkspace.shared.frontmostApplication.map(TextInserter.isElectron) ?? false
        let withholdAI = TextInserter.secureInputActive
            && PasteTargetRules.secureFieldMayBeInvisible(bundleID: sessionApp ?? "", isElectron: isElectron)
        sessionWithholdAI = withholdAI
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
        // Starts in the background: this runs inside the key handling, which every key press of the
        // user waits for. Only rewrite needs the whole recording at the end.
        let id = sessionID
        audio.start(
            deviceUID: settings.inputDeviceUID.isEmpty ? nil : settings.inputDeviceUID,
            keepSamples: action == .rewrite, deferBluetooth: true
        ) { [weak self] in self?.audioStartFailed(id) }
        phase = .recording(action)
        recordingStart = Date()
        lastVoice = Date()
        audioFlowing = false
        peakLevel = 0

        // Right ⌥ is also used for @, € and brackets: the panel and sound only appear once it is
        // clearly a dictation (tap for hands-free, or held past the shortcut window).
        startPreview(session: session, segmenter: segmenter, id: sessionID)
    }

    private func audioStartFailed(_ id: UUID) {
        guard sessionID == id, case .recording = phase else { return }
        hotkeys.reset()
        cancel()
        if Permissions.microphoneStatus != .granted {
            showError(L("No microphone access", "Mikrofon-Zugriff fehlt"), action: Permissions.openMicrophoneSettings,
                      actionTitle: L("Open settings", "Einstellungen öffnen"))
        } else {
            showError(L("Microphone could not start", "Mikrofon konnte nicht starten"), action: nil)
        }
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
                let elapsed = now.timeIntervalSince(self.recordingStart)
                let silent = now.timeIntervalSince(self.lastVoice)
                self.overlay.model.elapsed = elapsed
                self.overlay.model.countdown = RecordingClock.countdown(
                    elapsed: elapsed, silent: silent, maximum: self.maximumRecording, silenceLimit: self.silenceStop)
                if silent > self.silenceStop || elapsed > self.maximumRecording {
                    // Nobody may be at the Mac any more: the text is kept, not pasted wherever the focus is now.
                    Debug.log("auto stop: silence or maximum length")
                    self.autoStoppedSession = id
                    self.hotkeys.reset()
                    self.requestFinish(action)
                    return
                }
            }
        }
    }

    /// The × of the recording pill: discard, like Esc.
    private func cancelFromOverlay() {
        guard case .recording = phase else { return }
        hotkeys.reset()
        cancel()
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
        timing = FinishTiming(released: Date())
        previewTask?.cancel()
        if !prepared { prepare(action) }
        finishTask = Task { await finish(action) }
    }

    private func cancel() {
        previewTask?.cancel()
        audio.discard()
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

    /// Esc while the text is being prepared (transcription, AI, up to 30 s for a rewrite): nothing
    /// is inserted.
    func cancelProcessing() {
        guard case .processing = phase else { return }
        Debug.log("processing cancelled")
        finishTask?.cancel()
        audio.discard()
        audio.setSampleHandler(nil)
        chunkStream?.finish()
        chunkConsumer?.cancel()
        selectionTask?.cancel()
        secureProbeTask?.cancel()
        if let session { Task { await session.cancel() } }
        // Whatever the cancelled finish still delivers belongs to an old session and is dropped.
        sessionID = UUID()
        teardown()
        overlay.show(.done(L("Cancelled", "Abgebrochen"), undo: false))
    }

    /// Sleep, screen lock or a user switch: a running recording is thrown away, so it is not
    /// inserted later into whatever is in front then.
    func cancelRecording(because reason: String) {
        guard case .recording = phase else { return }
        Debug.log("recording cancelled: \(reason)")
        hotkeys.reset()
        cancel()
    }

    private func phaseChanged() {
        if case .processing = phase { hotkeys.escapeCancelsProcessing = true } else { hotkeys.escapeCancelsProcessing = false }
        if case .recording = phase { return }
        if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
        recordingActivity = nil
    }

    /// The VAD says nobody speaks and the last 100 ms are quiet: the grace period after the release
    /// would only add delay.
    private func tailIsSilent() async -> Bool {
        guard let segmenter else { return false }
        let tail = await segmenter.tail(RecordingTail.window)
        return RecordingTail.canStopNow(isSpeaking: tail.speaking, recent: tail.samples)
    }

    private func finish(_ action: HotkeyAction) async {
        let id = sessionID
        let stream = chunkStream, consumer = chunkConsumer, probe = secureProbeTask
        overlay.show(.processing)
        // Keep recording a moment so the last syllable is not cut off – unless all is quiet already.
        if await !tailIsSilent() {
            try? await Task.sleep(nanoseconds: UInt64(RecordingTail.grace * 1_000_000_000))
        }
        // Cancelled meanwhile (Esc, sleep): cancelProcessing cleaned up, and a new recording may run.
        guard sessionID == id, !Task.isCancelled else { return }
        let allSamples = await audio.stop()
        timing?.audioStopped = Date()
        audio.setSampleHandler(nil)
        stream?.finish()
        await consumer?.value

        // A short press reaches this point before the password-field probe answered: wait for it, so
        // nothing is transcribed or sent to the AI server for a password field.
        await probe?.value
        guard sessionID == id else { return }
        if secureFieldSeen {
            if let session { await session.cancel() }
            hotkeys.reset()
            showError(L("Password field – not recorded", "Passwortfeld – nicht aufgenommen"), action: nil)
            teardown()
            return
        }

        switch action {
        case .dictate:
            await finishDictation(id: id)
        case .rewrite:
            await finishRewrite(samples: allSamples, id: id)
        }
        if var timing, Debug.enabled {
            timing.lastTranscription = await transcriber.lastRun
            Debug.log("timing: \(timing.summary())")
        }
        // A new dictation may already have started right after the paste.
        if sessionID == id { teardown() }
    }

    /// Ready for the next dictation as soon as the text landed (the clipboard restore runs on).
    private func readyForNext(_ id: UUID) {
        guard sessionID == id, case .processing = phase else { return }
        timing?.inserted = Date()
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
        let autoStopped = autoStoppedSession == id
        // Probe the paste target and save the clipboard while the text is still being prepared.
        let preparation = autoStopped ? nil : Task { await TextInserter.prepare() }
        if let rest = await segmenter.flush() {
            await session.addSegment(rest)
        }
        let finished = await session.finish()
        // Cancelled while the text was prepared: insert nothing, show nothing.
        guard sessionID == id else { return }
        timing?.textReady = Date()
        guard let result = finished else {
            if peakLevel < 0.05 {
                showError(L("No sound from the microphone – check the input device", "Kein Ton vom Mikrofon – Eingabegerät prüfen"),
                          action: Permissions.openMicrophoneSettings)
            } else {
                overlay.show(.notice(L("Nothing heard – try again", "Nichts gehört – nochmal versuchen"), symbol: "ear"))
            }
            return
        }
        if autoStopped {
            // Nobody may be at the Mac any more and the focus may be anywhere: keep the text instead of
            // pasting it, in the history and behind the "Insert" button of the pill.
            appendToHistory(result)
            pendingAutoStop = PendingInsert(text: result.final, selection: nil)
            undoCandidate = nil
            if settings.playSounds { sounds.playStop() }
            overlay.show(.autoStopped(L("Stopped automatically", "Automatisch beendet")))
            readyForNext(id)
            return
        }
        overlay.model.committedText = result.final
        overlay.model.partialText = ""
        let hasOriginal = result.withoutAI != nil
        if hasOriginal { undoCandidate = result }
        let prepared = await preparation?.value
        let outcome = await TextInserter.insert(result.final, expectedApp: sessionApp, prepared: prepared, onPasted: { [weak self] in
            // Sound and panel react the moment the text lands, not after the clipboard restore.
            guard let self else { return }
            self.keysSinceInsert = 0
            if self.settings.playSounds { self.sounds.playStop() }
            let undo = hasOriginal && TextInserter.lastPasteSupportsUndo
            if !undo { self.undoCandidate = nil }
            self.overlay.show(.done(result.summary.text, undo: undo))
            self.readyForNext(id)
        })
        // A password field, or a possible one (secure input, focus unknown), never goes to the history file.
        if outcome != .secureField && outcome != .copiedSecureInput { appendToHistory(result) }
        if outcome != .pasted { undoCandidate = nil }
        switch outcome {
        case .pasted:
            break
        case .copiedToClipboard:
            overlay.show(Self.copiedNotice)
        case .appChanged:
            overlay.show(Self.appChangedNotice)
        case .copiedSecureInput:
            overlay.show(Self.secureInputNotice)
        case .secureField:
            showError(L("Password field – not inserted and not saved", "Passwortfeld – nicht eingefügt und nicht gespeichert"), action: nil)
        }
    }

    private func appendToHistory(_ result: DictationResult) {
        guard settings.keepHistory else { return }
        history.removeOlder(than: Self.historyRetention)
        history.append(result)
        state.history = history.items
    }

    /// Every key the user types (from the hotkey monitor's event tap; must stay cheap).
    private func userPressedKey(_ event: NSEvent) {
        keysSinceInsert += 1
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" || event.keyCode == 9 {
            TextInserter.userPressedPaste()
        }
    }

    /// Replace the text just inserted with the version without AI.
    private func insertOriginal() {
        guard let result = undoCandidate, let original = result.withoutAI else { return }
        undoCandidate = nil
        overlay.model.committedText = original
        // ⌘Z only hits the inserted text in the app that received it, and only while nothing was typed since.
        let swap = OriginalSwap.decide(
            frontmostApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            insertedInto: result.appBundleID, keysSinceInsert: keysSinceInsert)
        guard swap == .undoAndPaste else {
            TextInserter.copyTemporarily(original)
            overlay.show(Self.originalCopiedNotice)
            return
        }
        TextInserter.undo()
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            switch await TextInserter.insert(original, expectedApp: result.appBundleID, recordsUndo: false) {
            case .pasted:
                keysSinceInsert = 0
                overlay.show(.done(L("Original inserted", "Original eingefügt"), undo: false))
            case .copiedToClipboard, .appChanged, .copiedSecureInput: overlay.show(Self.originalCopiedNotice)
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    /// Text of an automatically stopped session, inserted only by a click on its pill. `selection` is
    /// the text a rewrite replaces; it must still be selected then.
    private struct PendingInsert {
        let text: String
        let selection: String?
    }

    /// "Insert" on the pill of an automatically stopped recording. The panel never takes focus, so the
    /// click leaves the cursor where the user has it now: that is where the text goes.
    private func insertPendingAutoStop() {
        guard let pending = pendingAutoStop else { return }
        guard case .idle = phase else {
            overlay.show(Self.busyNotice)
            return
        }
        pendingAutoStop = nil
        overlay.show(.hidden)
        Task {
            if let selection = pending.selection,
               !PasteTargetRules.rewriteMayReplace(captured: selection, current: await TextInserter.currentSelection()) {
                TextInserter.copyTemporarily(pending.text)
                overlay.show(.notice(L("Selection changed – rewrite copied, press ⌘V", "Markierung geändert – Umformulierung kopiert, ⌘V drücken"), symbol: "doc.on.clipboard"))
                return
            }
            switch await TextInserter.insert(pending.text, recordsUndo: false) {
            case .pasted:
                keysSinceInsert = 0
                overlay.show(.done(L("Inserted", "Eingefügt"), undo: false))
            case .copiedSecureInput: overlay.show(Self.secureInputNotice)
            case .copiedToClipboard, .appChanged: overlay.show(Self.copiedNotice)
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    private func finishRewrite(samples: [Float], id: UUID) async {
        let app = sessionApp
        let autoStopped = autoStoppedSession == id
        let selection = await selectionTask?.value
        guard let selection else {
            showError(L("No text selected – select text, then try again", "Kein Text markiert – erst Text markieren"), action: nil)
            return
        }
        guard let llm else {
            showError(L("Rewriting needs the AI – it is off in settings", "Umformulieren braucht die KI – sie ist in den Einstellungen aus"),
                      action: { [weak self] in self?.openSettings?() }, actionTitle: L("Settings", "Einstellungen"))
            return
        }
        // The selection must not reach the AI server where a password field may be invisible.
        guard !sessionWithholdAI else {
            showError(L("Secure input active – AI off", "Gesicherte Eingabe aktiv – KI aus"), action: nil)
            return
        }
        // Probe the paste target and save the clipboard while the instruction is transcribed and applied.
        let preparation = autoStopped ? nil : Task { await TextInserter.prepare() }
        var instruction: String?
        if samples.count >= 16_000 / 3 { instruction = try? await transcriber.transcribe(samples) }
        guard sessionID == id else { return }
        guard let instruction, !instruction.trimmingCharacters(in: .whitespaces).isEmpty else {
            overlay.show(.notice(L("Instruction not understood – please say it again", "Anweisung nicht verstanden – nochmal sprechen"), symbol: "questionmark.bubble"))
            return
        }
        do {
            overlay.model.committedText = instruction
            overlay.model.partialText = ""
            let rewritten = try await llm.rewrite(selection: selection, instruction: instruction)
            guard sessionID == id else { return }
            timing?.textReady = Date()
            if autoStopped {
                // Not pasted over the selection while nobody may be at the Mac; the pill offers it.
                pendingAutoStop = PendingInsert(text: rewritten, selection: selection)
                overlay.show(.autoStopped(L("Stopped automatically", "Automatisch beendet")))
                return
            }
            // The selection may have changed while the model worked: then the paste would overwrite
            // other text, so the rewrite is copied instead.
            let stillSelected = PasteTargetRules.rewriteMayReplace(captured: selection, current: await TextInserter.currentSelection())
            let outcome: InsertOutcome
            var selectionChanged = false
            if stillSelected {
                let prepared = await preparation?.value
                outcome = await TextInserter.insert(rewritten, expectedApp: app, prepared: prepared, onPasted: { [weak self] in
                    guard let self else { return }
                    self.keysSinceInsert = 0
                    if self.settings.playSounds { self.sounds.playStop() }
                    self.overlay.show(.done(L("Rewritten", "Umformuliert"), undo: false))
                    self.readyForNext(id)
                })
            } else {
                TextInserter.copyTemporarily(rewritten)
                selectionChanged = true
                outcome = .copiedToClipboard
            }
            // A rewrite is not written to the history: its result is the user's own document.
            switch outcome {
            case .pasted: break
            case .copiedToClipboard where selectionChanged:
                overlay.show(.notice(L("Selection changed – rewrite copied, press ⌘V", "Markierung geändert – Umformulierung kopiert, ⌘V drücken"), symbol: "doc.on.clipboard"))
            case .copiedToClipboard:
                overlay.show(.notice(L("Rewritten – copied, press ⌘V", "Umformuliert – kopiert, ⌘V drücken"), symbol: "doc.on.clipboard"))
            case .copiedSecureInput: overlay.show(Self.secureInputNotice)
            case .appChanged: overlay.show(Self.appChangedNotice)
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        } catch where sessionID != id {
            return // cancelled: the aborted request is no error to show
        } catch LLMError.tooLong {
            showError(L("Selection too long for the built-in AI – text unchanged", "Markierung zu lang für die eingebaute KI – Text unverändert"), action: nil)
        } catch LLMError.rejectedOutput {
            showError(L("AI answer did not look like a rewrite – text unchanged", "KI-Antwort war keine Umformulierung – Text unverändert"), action: nil)
        } catch LLMError.unreachable where settings.llmBackend == .builtin {
            // The built-in client says "unreachable" when the model file is missing.
            showError(L("AI model missing – text unchanged", "KI-Modell fehlt – Text unverändert"),
                      action: { [weak self] in self?.openSettings?() }, actionTitle: L("Settings", "Einstellungen"))
        } catch LLMError.timeout where settings.llmBackend == .builtin && !LlamaEngine.shared.isLoaded {
            showError(L("AI model could not be loaded – text unchanged", "KI-Modell konnte nicht geladen werden – Text unverändert"),
                      action: { [weak self] in self?.openSettings?() }, actionTitle: L("Settings", "Einstellungen"))
        } catch LLMError.timeout {
            showError(L("AI took too long – text unchanged", "KI hat zu lange gebraucht – Text unverändert"), action: nil)
        } catch {
            showError(L("AI not reachable – text unchanged", "KI nicht erreichbar – Text unverändert"),
                      action: { [weak self] in self?.openSettings?() }, actionTitle: L("Settings", "Einstellungen"))
        }
    }

    // Hints that ask the user to act: shown longer and in orange, unlike the green "done".
    private static var copiedNotice: OverlayState {
        .notice(L("No text field – copied, press ⌘V", "Kein Textfeld – kopiert, ⌘V drücken"), symbol: "doc.on.clipboard")
    }

    private static var originalCopiedNotice: OverlayState {
        .notice(L("Original copied – press ⌘V", "Original kopiert – ⌘V drücken"), symbol: "doc.on.clipboard")
    }

    private static var secureInputNotice: OverlayState {
        .notice(L("Secure input active – copied, press ⌘V", "Gesicherte Eingabe aktiv – kopiert, ⌘V drücken"), symbol: "lock.fill")
    }

    private static var appChangedNotice: OverlayState {
        .notice(L("Other app in front – copied, press ⌘V", "Andere App im Vordergrund – kopiert, ⌘V drücken"), symbol: "macwindow.on.rectangle")
    }

    private static var busyNotice: OverlayState {
        .notice(L("Busy – try again in a moment", "Gerade beschäftigt – gleich nochmal versuchen"), symbol: "hourglass")
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
        finishTask = nil
    }

    private func showError(_ message: String, action: (() -> Void)?, actionTitle: String? = nil) {
        errorAction = action
        overlay.model.errorActionable = action != nil
        overlay.model.actionTitle = action != nil ? actionTitle : nil
        overlay.show(.error(message))
    }

    // MARK: - Menu actions

    /// Paste the most recent dictation again at the cursor.
    func pasteLast() {
        // Without a history the last automatically stopped dictation is still kept in memory.
        let fallback = pendingAutoStop?.selection == nil ? pendingAutoStop?.text : nil
        guard let last = history.items.first?.final ?? fallback else {
            overlay.show(.notice(L("Nothing to paste (history empty or off)", "Nichts einzufügen (Verlauf leer oder aus)"), symbol: "tray"))
            return
        }
        // Not while a dictation is recording or being inserted: it would paste in between and mix up
        // the clipboard handling of that session.
        guard case .idle = phase else {
            overlay.show(Self.busyNotice)
            return
        }
        Task {
            // Give the menu time to close so the previous app has focus again.
            try? await Task.sleep(nanoseconds: 250_000_000)
            switch await TextInserter.insert(last, recordsUndo: false) {
            case .pasted: keysSinceInsert = 0
            case .copiedSecureInput: overlay.show(Self.secureInputNotice)
            case .copiedToClipboard, .appChanged: overlay.show(Self.copiedNotice)
            case .secureField: showError(L("Password field – not inserted", "Passwortfeld – nicht eingefügt"), action: nil)
            }
        }
    }

    func clearHistory() {
        history.clear()
        state.history = []
    }

    /// Deletes one dictation from the history (History tab).
    func removeHistory(id: UUID) {
        history.remove(id: id)
        state.history = history.items
    }

    /// An interrupted download left a partial file: the button continues it.
    var hasPartialDownload: Bool { modelStore.partialBytes(modelSpec) > 0 }
}
