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
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
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
