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

    public init(configuration: Configuration, session: URLSession = .shared) {
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
        let output = try await chat(
            system: Prompts.cleanupSystem(language),
            user: Prompts.cleanupUser(text: text, language: language),
            maxTokens: text.count / 2 + 64,
            timeout: configuration.cleanupTimeout
        )
        guard let accepted = LLMOutputGuard.acceptCleanup(input: text, output: output, style: style) else {
            throw LLMError.rejectedOutput
        }
        return accepted
    }

    public func rewrite(selection: String, instruction: String) async throws -> String {
        let language = DictationLanguage.detect(selection) ?? DictationLanguage.detect(instruction) ?? .german
        let output = try await chat(
            system: Prompts.rewriteSystem(language),
            user: Prompts.rewriteUser(selection: selection, instruction: instruction, language: language),
            model: configuration.rewriteModel,
            maxTokens: max(512, selection.count),
            timeout: configuration.rewriteTimeout
        )
        guard !LLMOutputGuard.sanitize(output).isEmpty else { throw LLMError.badResponse }
        guard let accepted = LLMOutputGuard.acceptRewrite(selection: selection, instruction: instruction, output: output) else {
            throw LLMError.rejectedOutput
        }
        return accepted
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
        let body: [String: Any] = [
            "model": model ?? configuration.model,
            "stream": false,
            "keep_alive": configuration.keepAlive,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.1, "num_predict": maxTokens],
        ]
        let data = try await post(path: "api/chat", body: body, timeout: timeout)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.badResponse }
        return content
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

/// Runs `operation` and throws `LLMError.timeout` if it does not finish within `seconds`.
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
