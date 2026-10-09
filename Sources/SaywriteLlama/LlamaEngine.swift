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

    /// Sampling like the options Ollama applies to qwen2.5 (temperature 0.1 from OllamaClient, its
    /// defaults for the rest), with a fixed seed so a run is repeatable.
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
    private var lastUse = Date()
    private let abortBox = AbortBox()
    private let loaded = LockedFlag()
    private var idleTimer: IdleTimer?
    private var pressureSource: DispatchSourceMemoryPressure?

    private static let backendReady: Void = {
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
        guard let context = llama_init_from_model(model, contextParams) else {
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
        self.lastUse = Date()
        loaded.value = true
        startWatching()
    }

    /// Loads the model and runs the constant system prompt of `language` through it, so the first
    /// real request only has the dictated text left to process. Does not throw: a missing model
    /// shows in the settings, and the dictation falls back to the rules.
    public func prewarm(modelURL: URL, language: DictationLanguage, forRewrite: Bool) {
        do {
            try load(from: modelURL)
            let system = forRewrite ? Prompts.rewriteSystem(language) : Prompts.cleanupSystem(language)
            let user = forRewrite
                ? Prompts.rewriteUser(selection: "Hallo.", instruction: "kürzer", language: language)
                : Prompts.cleanupUser(text: "Hallo.", language: language)
            _ = try generate(system: system, user: user, maxTokens: 1, abort: AbortFlag())
        } catch {
            Debug.log("built-in model prewarm failed: \(error)")
        }
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
    public nonisolated func startLoading(modelURL: URL, language: DictationLanguage, forRewrite: Bool) -> Task<Void, Never> {
        pending.lock.lock(); defer { pending.lock.unlock() }
        if let task = pending.task { return task }
        let task = Task.detached { [self] in
            await prewarm(modelURL: modelURL, language: language, forRewrite: forRewrite)
            pending.clear()
        }
        pending.task = task
        return task
    }

    /// Frees the model before the process exits, blocking the caller for at most `timeout` seconds.
    /// ggml asserts in a static destructor when a Metal model is still alive at exit.
    /// Also covers a load or a request that is running: the unload is queued behind it, and a running
    /// request is told to stop so the queue moves on.
    public nonisolated func shutdown(timeout: TimeInterval = 5) {
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

    /// Answers one chat request. Throws `LLMError.timeout` when `abort` is set or the task is cancelled.
    public func generate(system: String, user: String, maxTokens: Int, abort: AbortFlag) throws -> String {
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
        guard tokens.count + 8 <= contextSize else { throw LLMError.rejectedOutput }
        let budget = max(1, min(maxTokens, contextSize - tokens.count))

        let memory = llama_get_memory(context)
        var keep = KVCachePlan.keep(cached: cachedTokens, tokens: tokens)
        if keep > 0, !llama_memory_seq_rm(memory, 0, Int32(keep), -1) { keep = 0 }
        if keep == 0 { llama_memory_clear(memory, true) }
        cachedTokens = []

        do {
            // The prompt, in batches.
            var position = keep
            while position < tokens.count {
                let end = min(tokens.count, position + Int(Self.batchSize))
                var chunk = Array(tokens[position..<end])
                let status = chunk.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
                if status != 0 { throw decodeFailure(abort) }
                if abort.isSet || Task.isCancelled { throw LLMError.timeout }
                position = end
            }
            cachedTokens = tokens

            let sampler = makeSampler(vocab: vocab)
            defer { llama_sampler_free(sampler) }
            var bytes: [UInt8] = []
            var piece = [CChar](repeating: 0, count: 128)
            for _ in 0..<budget {
                if abort.isSet || Task.isCancelled { throw LLMError.timeout }
                var token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                let length = Int(llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false))
                if length > 0 { bytes.append(contentsOf: piece[0..<length].map { UInt8(bitPattern: $0) }) }
                let status = llama_decode(context, llama_batch_get_one(&token, 1))
                if status != 0 { throw decodeFailure(abort) }
            }
            // Keep the prompt, drop the answer.
            _ = llama_memory_seq_rm(memory, 0, Int32(tokens.count), -1)
            return String(decoding: bytes, as: UTF8.self)
        } catch {
            llama_memory_clear(memory, true)
            cachedTokens = []
            throw error
        }
    }

    private func decodeFailure(_ abort: AbortFlag) -> LLMError {
        abort.isSet || Task.isCancelled ? .timeout : .badResponse
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
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
