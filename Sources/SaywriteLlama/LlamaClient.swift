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
        await LlamaEngine.shared.prewarm(modelURL: modelURL, language: prewarmLanguage, forRewrite: forRewrite)
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
        guard engine.isLoaded else {
            // The model is not in memory (first use, or unloaded after idle or memory pressure). Loading
            // takes seconds, so this dictation goes without AI (the rules answer) while it loads.
            let url = modelURL
            let language = prewarmLanguage
            Task.detached { await engine.prewarm(modelURL: url, language: language, forRewrite: false) }
            throw LLMError.timeout
        }
        let abort = AbortFlag()
        return try await withTimeout(seconds: timeout) {
            try await withTaskCancellationHandler {
                try await engine.generate(system: system, user: user, maxTokens: maxTokens, abort: abort)
            } onCancel: {
                abort.set()
            }
        }
    }
}
