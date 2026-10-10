import Foundation
import SaywriteCore

/// `LLMClient` backed by the built-in model. A thin value: the model and its state live in the
/// shared `LlamaEngine`, so it is cheap to create one per request.
public struct LlamaClient: LLMClient {
    public var modelURL: URL
    public var cleanupTimeout: TimeInterval
    public var rewriteTimeout: TimeInterval
    /// Language whose prompt is primed on prewarm (the usual dictation language).
    public var prewarmLanguage: DictationLanguage

    public init(modelURL: URL, cleanupTimeout: TimeInterval = 4, rewriteTimeout: TimeInterval = 30, prewarmLanguage: DictationLanguage = .german) {
        self.modelURL = modelURL
        self.cleanupTimeout = cleanupTimeout
        self.rewriteTimeout = rewriteTimeout
        self.prewarmLanguage = prewarmLanguage
    }

    public func prewarm(forRewrite: Bool) async {
        await LlamaEngine.shared.startLoading(modelURL: modelURL, language: prewarmLanguage, forRewrite: forRewrite).value
    }

    public func cleanup(text: String, style: Style, language: DictationLanguage = .german) async throws -> String {
        try await LLMRequests.cleanup(text: text, style: style, language: language) { system, user, maxTokens in
            try await generate(system: system, user: user, maxTokens: maxTokens, timeout: cleanupTimeout)
        }
    }

    public func rewrite(selection: String, instruction: String) async throws -> String {
        try await LLMRequests.rewrite(selection: selection, instruction: instruction) { system, user, maxTokens in
            try await generate(system: system, user: user, maxTokens: maxTokens, timeout: rewriteTimeout)
        }
    }

    private func generate(system: String, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw LLMError.unreachable }
        let engine = LlamaEngine.shared
        let started = Date()
        if !engine.isLoaded {
            // Not in memory (first use, or unloaded after idle or memory pressure): wait for the load
            // (shared with a prewarm that already runs) within the timeout. Past it the rules answer.
            let load = engine.startLoading(modelURL: modelURL, language: prewarmLanguage, forRewrite: false)
            guard await Self.wait(for: load, seconds: timeout), engine.isLoaded else { throw LLMError.timeout }
        }
        let remaining = timeout - Date().timeIntervalSince(started)
        guard remaining > 0.2 else { throw LLMError.timeout }
        let abort = AbortFlag()
        return try await withTimeout(seconds: remaining) {
            try await withTaskCancellationHandler {
                try await engine.generate(system: system, user: user, maxTokens: maxTokens, abort: abort)
            } onCancel: {
                abort.set()
            }
        }
    }

    /// Waits for `task` for at most `seconds`; false when the time ran out first.
    private static func wait(for task: Task<Void, Never>, seconds: TimeInterval) async -> Bool {
        let once = OnceResume()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task { await task.value; once.resume(true) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); once.resume(false) }
        }
    }
}

private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    func set(_ c: CheckedContinuation<Bool, Never>) { lock.lock(); continuation = c; lock.unlock() }
    func resume(_ value: Bool) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
