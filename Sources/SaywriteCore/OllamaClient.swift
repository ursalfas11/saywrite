import Foundation

/// Talks to a local Ollama server over its HTTP API.
public final class OllamaClient: LLMClient, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var baseURL: URL
        public var model: String
        /// Model for rewriting selections; rewriting is harder than cleanup, so a bigger model can pay off.
        public var rewriteModel: String
        public var keepAlive: String
        public var cleanupTimeout: TimeInterval
        public var rewriteTimeout: TimeInterval
        /// Language whose prompt is primed on prewarm (the usual dictation language).
        public var prewarmLanguage: DictationLanguage = .german

        public init(
            baseURL: URL = URL(string: "http://localhost:11434")!,
            model: String = "qwen2.5:3b",
            rewriteModel: String? = nil,
            keepAlive: String = "15m",
            cleanupTimeout: TimeInterval = 4,
            rewriteTimeout: TimeInterval = 30
        ) {
            self.baseURL = baseURL
            self.model = model
            self.rewriteModel = rewriteModel ?? model
            self.keepAlive = keepAlive
            self.cleanupTimeout = cleanupTimeout
            self.rewriteTimeout = rewriteTimeout
        }
    }

    public let configuration: Configuration
    private let session: URLSession

    /// A session that follows redirects only within the same host: a remote server must not be able
    /// to send the dictation POST on to somewhere else.
    /// One session for the whole process: clients are created often, and a URLSession holds on to its
    /// delegate and connections until it is invalidated.
    public static let sharedSession = URLSession(configuration: .ephemeral, delegate: SameHostRedirects(), delegateQueue: nil)

    public init(configuration: Configuration, session: URLSession = OllamaClient.sharedSession) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - LLMClient

    private var prewarmLanguage: DictationLanguage { configuration.prewarmLanguage }

    public func prewarm(forRewrite: Bool) async {
        // Load the model and process the (long, constant) system prompt once, so Ollama's prompt
        // cache makes the first real request fast.
        if forRewrite {
            _ = try? await chat(
                system: Prompts.rewriteSystem(prewarmLanguage), user: Prompts.rewriteUser(selection: "Hallo.", instruction: "kürzer", language: prewarmLanguage),
                model: configuration.rewriteModel, maxTokens: 1, timeout: 120)
        } else {
            _ = try? await chat(
                system: Prompts.cleanupSystem(prewarmLanguage), user: Prompts.cleanupUser(text: "Hallo.", language: prewarmLanguage),
                maxTokens: 1, timeout: 120)
        }
    }

    public func cleanup(text: String, style: Style, language: DictationLanguage = .german) async throws -> String {
        try await LLMRequests.cleanup(text: text, style: style, language: language) { system, user, maxTokens in
            try await chat(system: system, user: user, maxTokens: maxTokens, timeout: configuration.cleanupTimeout)
        }
    }

    public func rewrite(selection: String, instruction: String) async throws -> String {
        try await LLMRequests.rewrite(selection: selection, instruction: instruction) { system, user, maxTokens in
            try await chat(system: system, user: user, model: configuration.rewriteModel, maxTokens: maxTokens, timeout: configuration.rewriteTimeout)
        }
    }

    // MARK: - Status

    /// Names of locally installed models, or nil when the server is not reachable.
    public func installedModels() async -> [String]? {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - HTTP

    func chat(system: String, user: String, model: String? = nil, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        // Ollama silently cuts the start of a prompt that exceeds its context (and with it the
        // instructions), and the answer would replace the whole selection. So the context is sized to
        // the request, and a request that does not fit is refused like the built-in engine does.
        guard let numCtx = Self.contextSize(promptCharacters: system.count + user.count, maxTokens: maxTokens) else {
            throw LLMError.tooLong
        }
        let body: [String: Any] = [
            "model": model ?? configuration.model,
            "stream": false,
            "keep_alive": configuration.keepAlive,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.1, "num_predict": maxTokens, "num_ctx": numCtx],
        ]
        let data = try await post(path: "api/chat", body: body, timeout: timeout)
        return try Self.parseChatResponse(data, contextSize: numCtx)
    }

    /// The answer text of an /api/chat reply. An answer cut off by the token limit (done_reason "length")
    /// is rejected: a rewrite would otherwise replace the whole selection with a truncated text.
    static func parseChatResponse(_ data: Data, contextSize: Int? = nil) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.badResponse }
        if json["done_reason"] as? String == "length" { throw LLMError.rejectedOutput }
        // A prompt that filled the whole context was cut at the start.
        if let contextSize, let evaluated = json["prompt_eval_count"] as? Int, evaluated >= contextSize - 64 {
            throw LLMError.tooLong
        }
        return content
    }

    /// Context sizes Ollama is asked for: a few fixed steps, because every other value reloads the model.
    static let contextSizes = [4096, 8192, 16384, 32768]

    /// The smallest context that holds the prompt and the answer (estimated at two characters per
    /// token, the answer at most as long as the prompt), nil when none does.
    static func contextSize(promptCharacters: Int, maxTokens: Int) -> Int? {
        let prompt = promptCharacters / 2 + 64
        let needed = prompt + min(maxTokens, prompt)
        return contextSizes.first { $0 >= needed }
    }

    private func post(path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let session = self.session
        let finalRequest = request
        return try await withTimeout(seconds: timeout) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: finalRequest)
            } catch let error as URLError where error.code == .timedOut {
                throw LLMError.timeout
            } catch is CancellationError {
                throw LLMError.timeout
            } catch let error as URLError where error.code == .cancelled {
                throw LLMError.timeout
            } catch {
                throw LLMError.unreachable
            }
            guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
            guard http.statusCode == 200 else { throw LLMError.http(http.statusCode) }
            return data
        }
    }
}

public extension OllamaClient.Configuration {
    /// True when the server runs on this Mac. Any other address receives every dictation (and
    /// selected text for rewriting), over plain HTTP unless it is an https URL.
    var isLocal: Bool { Self.isLocal(baseURL) }

    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        // 127.0.0.0/8, but not a host name like "127.example.com".
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}

final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let from, let to, let host = from.host?.lowercased(), to.host?.lowercased() == host else { return false }
        // Never from https down to http.
        return !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https")
    }
}

/// Validation of the address typed in the settings.
public enum OllamaEndpoint {
    /// Trims, assumes http:// when no scheme was typed ("localhost:11434", "192.168.0.5:11434") and
    /// accepts only http(s) with a host. Nil for anything else.
    public static func parse(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }
}

/// Runs `operation` and throws `LLMError.timeout` if it does not finish within `seconds`.
public func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw LLMError.timeout }
        return result
    }
}
