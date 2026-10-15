import Accelerate
import Foundation
import SaywriteCore
import llama

/// The built-in model: one process-wide actor around a llama.cpp model and context. A llama_context
/// is not thread-safe, and loading the model costs seconds, so all clients share this one engine;
/// the model is loaded on first use and freed after `idleSeconds` without a request or when the
/// system reports memory pressure.
public actor LlamaEngine {
    public static let shared = LlamaEngine()

    /// Same as Ollama's keep_alive.
    public static let idleSeconds: TimeInterval = 15 * 60

    /// Sampling for rewrites, like the options Ollama applies to qwen2.5 (temperature 0.1 from
    /// OllamaClient, its defaults for the rest), with a fixed seed so a run is repeatable. Cleanup is
    /// greedy (`Decoding.copy`), which prompt lookup needs to keep the answer unchanged.
    enum Sampling {
        static let temperature: Float = 0.1
        static let topK: Int32 = 40
        static let topP: Float = 0.9
        static let repeatPenalty: Float = 1.1
        static let repeatLastN: Int32 = 64
        static let seed: UInt32 = 42
    }

    static let contextSize: UInt32 = 4096
    static let batchSize: Int32 = 512

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedPath: String?
    /// Tokens whose keys and values are in the context, so a request that starts with the same
    /// (long, constant) system prompt does not decode it again.
    private var cachedTokens: [llama_token] = []
    /// The cache states of the system prompts used so far (cleanup and rewrite, German and English), so
    /// switching between them restores the prompt instead of decoding it again.
    private var snapshots = PrefixSnapshots<[UInt8]>(capacity: 4)
    private var lastUse = Date()
    private let abortBox = AbortBox()
    private let loaded = LockedFlag()
    /// Set by `shutdown()`: a prewarm or request queued behind the final unload must not load the model again.
    private nonisolated let closed = LockedFlag()
    private var idleTimer: IdleTimer?
    private var pressureSource: DispatchSourceMemoryPressure?

    private static let backendReady: Void = {
        // Before the Metal device is created, which reads it.
        if let seconds = EngineTuning.residencyKeepAlive(physicalMemory: ProcessInfo.processInfo.physicalMemory) {
            setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", String(seconds), 0)
        }
        llama_backend_init()
        // llama.cpp logs a lot to stderr; the app has its own debug log.
        llama_log_set({ _, _, _ in }, nil)
    }()

    private init() {}

    /// True once a model is loaded. Readable without waiting for a request that runs right now.
    public nonisolated var isLoaded: Bool { loaded.value }

    // MARK: - Loading

    /// Loads the model from `url` unless it is loaded already. Loading also compiles the Metal
    /// kernels the first time on a Mac, which can take a few seconds.
    public func load(from url: URL) throws {
        if closed.value { throw LLMError.unreachable }
        if context != nil, loadedPath == url.path { return }
        unload()
        _ = Self.backendReady

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(url.path, modelParams) else { throw LLMError.unreachable }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextSize
        contextParams.n_batch = UInt32(Self.batchSize)
        contextParams.n_ubatch = UInt32(Self.batchSize)
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        // An 8-bit cache halves its memory (~72 MiB less) at no measurable cost in the eval. It needs
        // Flash Attention, which llama.cpp turns on by itself on Apple GPUs; without it, a 16-bit cache.
        contextParams.type_k = GGML_TYPE_Q8_0
        contextParams.type_v = GGML_TYPE_Q8_0
        var created = llama_init_from_model(model, contextParams)
        if created == nil {
            Debug.log("built-in model: no 8-bit cache, using 16 bits")
            contextParams.type_k = GGML_TYPE_F16
            contextParams.type_v = GGML_TYPE_F16
            created = llama_init_from_model(model, contextParams)
        }
        guard let context = created else {
            llama_model_free(model)
            throw LLMError.unreachable
        }
        // Aborts a decode that runs on the CPU; on the GPU a request stops between two tokens.
        llama_set_abort_callback(context, { data in
            guard let data else { return false }
            return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().isSet
        }, Unmanaged.passUnretained(abortBox).toOpaque())

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.loadedPath = url.path
        self.cachedTokens = []
        self.snapshots.removeAll()
        self.lastUse = Date()
        loaded.value = true
        startWatching()
    }

    /// Loads the model and runs the constant system prompt of `language` through it, so the first
    /// real request only has the dictated text left to process. Does not throw: a missing model
    /// shows in the settings, and the dictation falls back to the rules.
    /// Returns whether the model could be loaded and run (it may be unloaded again right after).
    @discardableResult
    public func prewarm(modelURL: URL, language: DictationLanguage, forRewrite: Bool) -> Bool {
        do {
            try load(from: modelURL)
            let system = forRewrite ? Prompts.rewriteSystem(language) : Prompts.cleanupSystem(language)
            // Every dictation prewarms. With the prompt in the cache (or saved) there is nothing to run:
            // only the idle countdown starts again.
            if isPrimed(system: system) {
                lastUse = Date()
                idleTimer?.touch()
                return true
            }
            let user = forRewrite
                ? Prompts.rewriteUser(selection: "Hallo.", instruction: "kürzer", language: language)
                : Prompts.cleanupUser(text: "Hallo.", language: language)
            _ = try generate(system: system, user: user, maxTokens: 1, abort: AbortFlag(), requireFinished: false)
            return true
        } catch {
            Debug.log("built-in model prewarm failed: \(error)")
            return false
        }
    }

    /// True when the cache holds the system prompt, or its state is saved for a restore.
    private func isPrimed(system: String) -> Bool {
        guard context != nil, let vocab, let prefix = try? tokenize(ChatTemplate.prefix(system: system), vocab: vocab) else { return false }
        return cachedTokens.starts(with: prefix) || snapshots.contains(prefix)
    }

    /// Frees the model and its context. The next request loads it again.
    public func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        loadedPath = nil
        cachedTokens = []
        snapshots.removeAll()
        loaded.value = false
        idleTimer?.cancel()
        idleTimer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// Unloads the model and then runs `body` (which deletes the model file) in the same actor step,
    /// so no request can load the file in between. A prewarm queued after this finds no file.
    public func unloadThenRun(_ body: @Sendable () -> Void) {
        unload()
        body()
    }

    private nonisolated let pending = PendingLoad()

    /// Starts loading in the background, or returns the load that is already running, so a burst of
    /// requests while the model loads shares one load.
    public nonisolated func startLoading(
        modelURL: URL, language: DictationLanguage, forRewrite: Bool, priority: TaskPriority? = nil
    ) -> Task<Void, Never> {
        pending.lock.lock(); defer { pending.lock.unlock() }
        if let task = pending.task { return task }
        let task = Task.detached(priority: priority) { [self] in
            await prewarm(modelURL: modelURL, language: language, forRewrite: forRewrite)
            pending.clear()
        }
        pending.task = task
        return task
    }

    /// At launch: loads the model in the background when this app and macOS build have not loaded it yet
    /// (`UpdatePrewarm`), so the Metal kernels are compiled before the first dictation. A dictation that
    /// starts meanwhile shares the load. `enabled`: the AI is on and the built-in model is the backend.
    public nonisolated func prewarmAfterUpdate(modelURL: URL, language: DictationLanguage, enabled: Bool) {
        let build = UpdatePrewarm.build(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        guard UpdatePrewarm.isNeeded(
            enabled: enabled, modelInstalled: FileManager.default.fileExists(atPath: modelURL.path),
            build: build, prewarmedBuild: UserDefaults.standard.string(forKey: UpdatePrewarm.defaultsKey)),
            let build
        else { return }
        let load = startLoading(modelURL: modelURL, language: language, forRewrite: false, priority: .utility)
        Task.detached(priority: .utility) { [self] in
            await load.value
            if isLoaded { UserDefaults.standard.set(build, forKey: UpdatePrewarm.defaultsKey) }
        }
    }

    /// Frees the model before the process exits, blocking the caller for at most `timeout` seconds.
    /// ggml asserts in a static destructor when a Metal model is still alive at exit.
    /// Also covers a load or a request that is running: the unload is queued behind it, and a running
    /// request is told to stop so the queue moves on.
    public nonisolated func shutdown(timeout: TimeInterval = 5) {
        closed.value = true
        abortBox.flag?.set()
        let done = DispatchSemaphore(value: 0)
        Task.detached { await self.unload(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func startWatching() {
        let timer = IdleTimer(delay: Self.idleSeconds) { [weak self] in await self?.unloadIfIdle() }
        idleTimer = timer
        timer.touch()
        // Only .critical: loading the 2 GB model can itself raise a warning on an 8 GB Mac, and
        // unloading on that would make every dictation reload the model.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            // Runs after a request in progress: the actor never frees a model that is in use.
            Task { await self?.unload() }
        }
        source.resume()
        pressureSource = source
    }

    private func unloadIfIdle() {
        guard Date().timeIntervalSince(lastUse) >= Self.idleSeconds - 1 else { idleTimer?.touch(); return }
        unload()
    }

    // MARK: - Generation

    /// How the answer is decoded.
    public enum Decoding: Sendable {
        /// Sampling (`Sampling`): a rewrite is new text.
        case sample
        /// Greedy, with prompt lookup against `source` (`PromptLookup`): a cleanup answer is nearly a copy
        /// of the dictation. `wordGuard` stops an answer that leaves the source's words (`LLMError.rejectedOutput`).
        case copy(source: String, wordGuard: WordPrefixGuard? = nil)
    }

    /// Answers one chat request. Throws `LLMError.timeout` when `abort` is set or the task is cancelled.
    /// `requireFinished: false` is for the prewarm only: it wants the decoded prompt in the cache and
    /// throws the one sampled token away, so a cut-off answer is not an error there.
    public func generate(
        system: String, user: String, maxTokens: Int, abort: AbortFlag, requireFinished: Bool = true, decoding: Decoding = .sample
    ) throws -> String {
        guard let context, let vocab else { throw LLMError.unreachable }
        if abort.isSet || Task.isCancelled { throw LLMError.timeout }
        abortBox.flag = abort
        defer {
            abortBox.flag = nil
            lastUse = Date()
            idleTimer?.touch()
        }

        let tokens = try tokenize(ChatTemplate.qwen(system: system, user: user), vocab: vocab)
        let contextSize = Int(llama_n_ctx(context))
        guard tokens.count + 8 <= contextSize else { throw LLMError.tooLong }
        let budget = max(1, min(maxTokens, contextSize - tokens.count))

        let memory = llama_get_memory(context)
        var keep = KVCachePlan.keep(cached: cachedTokens, tokens: tokens)
        if keep > 0, !llama_memory_seq_rm(memory, 0, Int32(keep), -1) { keep = 0 }
        if keep == 0 { llama_memory_clear(memory, true) }
        cachedTokens = []
        // Another system prompt than the one in the cache: restore its saved state if there is one.
        if let saved = snapshots.restorable(for: tokens, keep: keep) {
            llama_memory_clear(memory, true)
            let read = saved.state.withUnsafeBufferPointer { llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0) }
            if read > 0 {
                keep = saved.tokens.count
            } else {
                llama_memory_clear(memory, true)
                keep = 0
            }
        }
        // The system prompt's part of the prompt, to save once it is decoded.
        let prefix = (try? tokenize(ChatTemplate.prefix(system: system), vocab: vocab)).flatMap { prefix in
            tokens.starts(with: prefix) && keep < prefix.count && !snapshots.contains(prefix) ? prefix : nil
        }

        do {
            // The prompt, in batches.
            var position = keep
            while position < tokens.count {
                var end = min(tokens.count, position + Int(Self.batchSize))
                if let prefix, position < prefix.count { end = min(end, prefix.count) }
                var chunk = Array(tokens[position..<end])
                let status = chunk.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
                if status != 0 { throw decodeFailure(abort) }
                if abort.isSet || Task.isCancelled { throw LLMError.timeout }
                position = end
                if let prefix, position == prefix.count { saveSnapshot(of: prefix, context: context) }
            }
            cachedTokens = tokens

            let answer: Answer
            switch decoding {
            case .sample:
                answer = try sampleAnswer(context: context, vocab: vocab, budget: budget, abort: abort)
            case .copy(let source, let wordGuard):
                let sourceTokens = (try? tokenize(source, vocab: vocab, special: false)) ?? []
                answer = try copyAnswer(
                    context: context, vocab: vocab, past: tokens.count, source: sourceTokens, budget: budget, abort: abort, wordGuard: wordGuard)
            }
            // An answer cut off by the token or context limit must not replace a selection (the catch clears the cache).
            // Cut off because the context was full (not because the answer ran past its own budget): the selection is too long.
            guard answer.finished || !requireFinished else { throw budget < maxTokens ? LLMError.tooLong : LLMError.rejectedOutput }
            // Keep the prompt, drop the answer.
            _ = llama_memory_seq_rm(memory, 0, Int32(tokens.count), -1)
            return String(decoding: answer.bytes, as: UTF8.self)
        } catch is LeftTheWords {
            // Stopped between two decodes: the cache is consistent, only the answer goes.
            _ = llama_memory_seq_rm(memory, 0, Int32(tokens.count), -1)
            throw LLMError.rejectedOutput
        } catch {
            llama_memory_clear(memory, true)
            cachedTokens = []
            throw error
        }
    }

    /// The answer left the input's words (`WordPrefixGuard`).
    private struct LeftTheWords: Error {}

    private struct Answer {
        var bytes: [UInt8] = []
        /// The model ended the answer itself (not cut off by the budget).
        var finished = false
    }

    /// One sampled token per decode.
    private func sampleAnswer(context: OpaquePointer, vocab: OpaquePointer, budget: Int, abort: AbortFlag) throws -> Answer {
        let sampler = makeSampler(vocab: vocab)
        defer { llama_sampler_free(sampler) }
        var answer = Answer()
        var piece = [CChar](repeating: 0, count: 128)
        for _ in 0..<budget {
            if abort.isSet || Task.isCancelled { throw LLMError.timeout }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { answer.finished = true; break }
            append(token, to: &answer.bytes, vocab: vocab, piece: &piece)
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            if status != 0 { throw decodeFailure(abort) }
        }
        return answer
    }

    /// Greedy decoding with prompt lookup: each decode checks the pending token plus up to
    /// `PromptLookup.draftLength` tokens guessed from `source`, with logits for every position. The
    /// guessed tokens the model confirms are kept; the cache is cut back after the first one it does not.
    /// `past` is the number of tokens in the cache (the prompt); its last logits give the first token.
    private func copyAnswer(
        context: OpaquePointer, vocab: OpaquePointer, past start: Int, source: [llama_token], budget: Int, abort: AbortFlag,
        wordGuard: WordPrefixGuard?
    ) throws -> Answer {
        let memory = llama_get_memory(context)
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var batch = llama_batch_init(Int32(PromptLookup.draftLength + 1), 0, 1)
        defer { llama_batch_free(batch) }
        var answer = Answer()
        var generated: [llama_token] = []
        var piece = [CChar](repeating: 0, count: 128)
        var past = start
        var pending = Self.argmax(llama_get_logits_ith(context, -1), count: vocabSize)
        while true {
            if abort.isSet || Task.isCancelled { throw LLMError.timeout }
            // Same limit as one token per decode: the token at index `budget` would not have been sampled.
            guard generated.count < budget else { break }
            if llama_vocab_is_eog(vocab, pending) { answer.finished = true; break }
            generated.append(pending)
            append(pending, to: &answer.bytes, vocab: vocab, piece: &piece)
            guard generated.count < budget else { break }

            let draft = PromptLookup.draft(generated: generated, source: source, limit: min(PromptLookup.draftLength, budget - generated.count))
            batch.n_tokens = Int32(draft.count + 1)
            for (index, token) in ([pending] + draft).enumerated() {
                batch.token[index] = token
                batch.pos[index] = llama_pos(past + index)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = 0
                batch.logits[index] = 1
            }
            let status = llama_decode(context, batch)
            if status != 0 { throw decodeFailure(abort) }
            let (accepted, next) = PromptLookup.accept(draft: draft, isEnd: { llama_vocab_is_eog(vocab, $0) }) { index in
                Self.argmax(llama_get_logits_ith(context, Int32(index)), count: vocabSize)
            }
            for token in draft.prefix(accepted) {
                generated.append(token)
                append(token, to: &answer.bytes, vocab: vocab, piece: &piece)
            }
            past += 1 + accepted
            if let wordGuard, !wordGuard.allows(String(decoding: answer.bytes, as: UTF8.self)) { throw LeftTheWords() }
            // The rejected guesses are not part of the answer.
            if accepted < draft.count, !llama_memory_seq_rm(memory, 0, llama_pos(past), -1) { throw LLMError.badResponse }
            pending = next
        }
        return answer
    }

    private func append(_ token: llama_token, to bytes: inout [UInt8], vocab: OpaquePointer, piece: inout [CChar]) {
        let length = Int(llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false))
        if length > 0 { bytes.append(contentsOf: piece[0..<length].map { UInt8(bitPattern: $0) }) }
    }

    private static func argmax(_ logits: UnsafeMutablePointer<Float>?, count: Int) -> llama_token {
        guard let logits else { return 0 }
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &value, &index, vDSP_Length(count))
        return llama_token(index)
    }

    /// Saves the cache state of sequence 0, which holds exactly `prefix` right now.
    private func saveSnapshot(of prefix: [llama_token], context: OpaquePointer) {
        let size = llama_state_seq_get_size(context, 0)
        guard size > 0 else { return }
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, 0) }
        if written == size { snapshots.store(prefix, state) }
    }

    private func decodeFailure(_ abort: AbortFlag) -> LLMError {
        abort.isSet || Task.isCancelled ? .timeout : .badResponse
    }

    /// `special: false` reads control tokens as plain text (for the dictation alone).
    private func tokenize(_ text: String, vocab: OpaquePointer, special: Bool = true) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, special)
        }
        guard count > 0 else { throw LLMError.badResponse }
        return Array(tokens[0..<Int(count)])
    }

    private func makeSampler(vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), Sampling.repeatLastN, Sampling.repeatPenalty, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Sampling.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Sampling.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Sampling.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(Sampling.seed))
        return chain
    }
}

/// Hands the abort flag of the request that runs right now to the C callback.
final class AbortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AbortFlag?
    var flag: AbortFlag? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var isSet: Bool { flag?.isSet ?? false }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class PendingLoad: @unchecked Sendable {
    let lock = NSLock()
    var task: Task<Void, Never>?
    func clear() { lock.lock(); task = nil; lock.unlock() }
}
