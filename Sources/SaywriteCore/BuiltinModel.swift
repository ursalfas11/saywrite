import Foundation

/// Which engine answers cleanup and rewrite requests.
public enum LLMBackend: String, Sendable, CaseIterable {
    /// The model that ships with the app (llama.cpp, downloaded once).
    case builtin
    /// A local or remote Ollama server.
    case ollama

    /// The stored setting, or the default (built-in) when nothing valid is stored.
    public static func resolve(stored: String?) -> LLMBackend {
        stored.flatMap(LLMBackend.init(rawValue:)) ?? .builtin
    }

    /// The backend at app start. A stored choice wins. Without one, the built-in model is the default,
    /// except for someone who used the app before the built-in model existed (it needed Ollama) and has
    /// not downloaded the model yet: their working Ollama setup keeps being used instead of silently
    /// falling back to rules-only cleanup.
    public static func resolveAtLaunch(stored: String?, modelInstalled: Bool, usedEarlierVersion: Bool) -> LLMBackend {
        if let backend = stored.flatMap(LLMBackend.init(rawValue:)) { return backend }
        return !modelInstalled && usedEarlierVersion ? .ollama : .builtin
    }

    /// The command line tools pick a backend without a stored setting: the built-in model when its
    /// file is there, Ollama otherwise.
    public static func evalDefault(modelInstalled: Bool) -> LLMBackend {
        modelInstalled ? .builtin : .ollama
    }
}

/// What the settings window shows for the built-in model.
public enum BuiltinModelState: Sendable, Equatable {
    case notDownloaded
    /// An interrupted download is on disk and can be continued.
    case partial(bytes: Int64)
    case downloading(Double)
    case verifying
    /// Loading the model once, which also compiles the Metal kernels for this Mac.
    case optimizing
    case ready
    case failed(String)

    public static func initial(for status: ModelDiskStatus) -> BuiltinModelState {
        switch status {
        case .missing: return .notDownloaded
        case .partial(let bytes): return .partial(bytes: bytes)
        case .installed: return .ready
        }
    }

    /// True while the app is busy with the model file, so a second download must not start.
    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .optimizing: return true
        default: return false
        }
    }
}

/// The chat format of the Qwen2.5 models (ChatML), the same as the template Ollama applies.
public enum ChatTemplate {
    public static func qwen(system: String, user: String) -> String {
        prefix(system: system) + "\(plain(user))<|im_end|>\n<|im_start|>assistant\n"
    }

    /// The part of the prompt that only depends on the system prompt.
    public static func prefix(system: String) -> String {
        "<|im_start|>system\n\(plain(system))<|im_end|>\n<|im_start|>user\n"
    }

    /// The engine tokenizes the whole string with control tokens enabled, so a literal `<|im_end|>` in a
    /// dictation or a selected text would end the turn. Ollama keeps such text as plain text; here the
    /// `<|` and `|>` brackets are removed from the content, which leaves "im_end" as harmless words.
    static func plain(_ text: String) -> String {
        var result = text
        while result.contains("<|") || result.contains("|>") {
            result = result.replacingOccurrences(of: "<|", with: "<").replacingOccurrences(of: "|>", with: ">")
        }
        return result
    }
}

/// How much of the cached prompt a new request can reuse.
public enum KVCachePlan {
    /// The length of the common prefix of `cached` and `tokens`, but at least one token short of the
    /// whole prompt, because the last token must be decoded to get logits.
    public static func keep(cached: [Int32], tokens: [Int32]) -> Int {
        var keep = 0
        while keep < min(cached.count, tokens.count), cached[keep] == tokens[keep] { keep += 1 }
        if keep == tokens.count { keep -= 1 }
        return max(0, keep)
    }
}

/// Saved cache states of prompt prefixes (the constant system prompts). The context holds one prompt at
/// a time; switching between German and English or from a cleanup to a rewrite would decode the other
/// system prompt again (450–750 ms). Restoring its saved state takes milliseconds.
public struct PrefixSnapshots<State> {
    public let capacity: Int
    /// Least recently used first.
    private var entries: [(tokens: [Int32], state: State)] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    public func contains(_ tokens: [Int32]) -> Bool {
        entries.contains { $0.tokens == tokens }
    }

    /// Saves `state` for `tokens`, replacing an older state of the same prefix and dropping the least
    /// recently used one beyond `capacity`.
    public mutating func store(_ tokens: [Int32], _ state: State) {
        entries.removeAll { $0.tokens == tokens }
        entries.append((tokens, state))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The longest saved prefix of `tokens` that is worth restoring: longer than the `keep` tokens the
    /// cache shares with them already, and shorter than `tokens` (the last token must be decoded for logits).
    public mutating func restorable(for tokens: [Int32], keep: Int) -> (tokens: [Int32], state: State)? {
        guard let index = entries.indices
            .filter({ entries[$0].tokens.count > keep && entries[$0].tokens.count < tokens.count && tokens.starts(with: entries[$0].tokens) })
            .max(by: { entries[$0].tokens.count < entries[$1].tokens.count })
        else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

/// After an app or macOS update llama.cpp compiles its Metal kernels again on the first load (5–7 s),
/// and the first dictation would run into the cleanup timeout. The app loads the model once in the
/// background at launch instead, and remembers for which build it did.
public enum UpdatePrewarm {
    public static let defaultsKey = "builtinPrewarmedBuild"

    /// The app version and the macOS version: either one changing invalidates the compiled kernels.
    public static func build(appVersion: String?, systemVersion: String) -> String? {
        appVersion.map { "\($0) / \(systemVersion)" }
    }

    public static func isNeeded(enabled: Bool, modelInstalled: Bool, build: String?, prewarmedBuild: String?) -> Bool {
        guard enabled, modelInstalled, let build else { return false }
        return build != prewarmedBuild
    }
}

/// Settings of the built-in engine that depend on the Mac.
public enum EngineTuning {
    /// Seconds llama.cpp keeps the model's GPU memory resident after the last request, or nil for its
    /// default (a few minutes). On a Mac with 8 GB or less the memory goes back to the system sooner.
    public static func residencyKeepAlive(physicalMemory: UInt64) -> Int? {
        physicalMemory <= 8 << 30 ? 30 : nil
    }
}

/// Prompt-lookup decoding for cleanup. The answer is nearly a copy of the dictation, so the tokens that
/// followed the last few answer tokens in the dictation are a good guess for the next ones. The model
/// checks a whole guess in one decode step and keeps the part it would have produced itself; with greedy
/// decoding the answer matches decoding one token at a time, only faster, up to ties: where two tokens
/// score (nearly) the same, the batched logits may differ in the last bits and pick the other one.
public enum PromptLookup {
    /// Tokens guessed per step. Measured on an M5 with Qwen2.5-3B: 2.1–2.8× faster decoding at 8.
    public static let draftLength = 8

    /// The tokens of `source` that followed the last `n` tokens of `generated` there, at most `limit`.
    /// Tries n = 3, 2, 1 and, for each, the latest match in `source` first. Empty when nothing matches.
    public static func draft(generated: [Int32], source: [Int32], limit: Int) -> [Int32] {
        guard limit > 0 else { return [] }
        for n in stride(from: 3, through: 1, by: -1) where generated.count >= n && source.count > n {
            let tail = generated[(generated.count - n)...]
            for start in stride(from: source.count - n - 1, through: 0, by: -1) where source[start..<start + n] == tail {
                let from = start + n
                return Array(source[from..<min(source.count, from + limit)])
            }
        }
        return []
    }

    /// How many tokens of `draft` the model confirmed, and the token it predicts after them.
    /// `prediction(i)` is the model's greedy token at batch position `i`: position 0 follows the last
    /// accepted token, position `i + 1` follows `draft[i]`. Asked only up to the first mismatch.
    public static func accept(draft: [Int32], isEnd: (Int32) -> Bool, prediction: (Int) -> Int32) -> (accepted: Int, next: Int32) {
        var index = 0
        while true {
            let predicted = prediction(index)
            guard index < draft.count, predicted == draft[index], !isEnd(predicted) else { return (index, predicted) }
            index += 1
        }
    }
}

/// Runs `onIdle` once `delay` has passed without a `touch()`. Every request calls `touch()`, so the
/// model is unloaded after that much idle time (Ollama's keep_alive, 15 minutes).
public final class IdleTimer: @unchecked Sendable {
    private let delay: TimeInterval
    private let onIdle: @Sendable () async -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(delay: TimeInterval, onIdle: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.onIdle = onIdle
    }

    /// (Re)starts the countdown.
    public func touch() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        let delay = delay
        let onIdle = onIdle
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await onIdle()
        }
    }

    public func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }

    deinit { task?.cancel() }
}

/// A flag one task sets and another reads, for aborting a request that runs in a blocking C call.
public final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func set() { lock.lock(); value = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// The request glue both backends share: the prompts, the token budgets and what counts as an answer.
public enum LLMRequests {
    public static func cleanupMaxTokens(for text: String) -> Int { text.count / 2 + 64 }
    public static func rewriteMaxTokens(for selection: String) -> Int { max(512, selection.count) }

    public static func cleanup(
        text: String, style: Style, language: DictationLanguage,
        generate: (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    ) async throws -> String {
        let output = try await generate(
            Prompts.cleanupSystem(language), Prompts.cleanupUser(text: text, language: language), cleanupMaxTokens(for: text))
        guard let accepted = LLMOutputGuard.acceptCleanup(input: text, output: output, style: style) else {
            throw LLMError.rejectedOutput
        }
        return accepted
    }

    public static func rewrite(
        selection: String, instruction: String,
        generate: (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    ) async throws -> String {
        let language = DictationLanguage.detect(selection) ?? DictationLanguage.detect(instruction) ?? .german
        let output = try await generate(
            Prompts.rewriteSystem(language), Prompts.rewriteUser(selection: selection, instruction: instruction, language: language),
            rewriteMaxTokens(for: selection))
        guard !LLMOutputGuard.sanitize(output).isEmpty else { throw LLMError.badResponse }
        guard let accepted = LLMOutputGuard.acceptRewrite(selection: selection, instruction: instruction, output: output) else {
            throw LLMError.rejectedOutput
        }
        return accepted
    }
}
