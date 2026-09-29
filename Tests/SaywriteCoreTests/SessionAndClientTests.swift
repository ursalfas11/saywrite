import XCTest
@testable import SaywriteCore

// MARK: - Fakes

/// Maps the first sample value to a canned transcript so tests can control segment text.
struct FakeTranscriber: Transcriber {
    let texts: [Int: String]
    var delays: [Int: UInt64] = [:]
    func transcribe(_ samples: [Float]) async throws -> String {
        let key = Int(samples.first ?? 0)
        if let delay = delays[key] { try await Task.sleep(nanoseconds: delay) }
        guard let text = texts[key] else { throw URLError(.unknown) }
        return text
    }
}

actor CallLog {
    var cleanups: [String] = []
    func record(_ text: String) { cleanups.append(text) }
}

struct FakeLLM: LLMClient {
    let log = CallLog()
    var fail = false
    func prewarm(forRewrite: Bool) async {}
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String {
        await log.record(text)
        if fail { throw LLMError.timeout }
        return text.replacingOccurrences(of: "drei, nein, um ", with: "")
    }
    func rewrite(selection: String, instruction: String) async throws -> String { selection.uppercased() }
}

// MARK: - Session

final class DictationSessionTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    func testJoinsSegmentsInCaptureOrderEvenIfLaterFinishFirst() async {
        let transcriber = FakeTranscriber(
            texts: [1: "Erster Satz.", 2: "zweiter Satz."],
            delays: [1: 200_000_000])
        let session = DictationSession(transcriber: transcriber, llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Erster Satz. Zweiter Satz.")
        XCTAssertEqual(result?.summary.usedLLM, false)
    }

    func testCleanTextSkipsLLM() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "ähm das passt so."]), llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Das passt so.")
        let calls = await llm.log.cleanups
        XCTAssertTrue(calls.isEmpty)
    }

    func testCorrectionUsesLLMOnlyForThatSegment() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Wir treffen uns morgen.", 2: "um drei, nein, um vier."]),
            llm: llm, style: .neutral, appBundleID: "com.apple.Notes")
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Wir treffen uns morgen. Um vier.")
        XCTAssertEqual(result?.summary.usedLLM, true)
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["um drei, nein, um vier."])
    }

    func testLLMFailureFallsBackToRules() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "um drei, nein, um vier"]),
            llm: FakeLLM(fail: true), style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Um drei, nein, um vier.")
        XCTAssertEqual(result?.summary.llmFailed, true)
        XCTAssertTrue(result?.summary.text.contains("ohne KI") ?? false)
    }

    func testFailedTranscriptionSegmentIsSkipped() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [2: "nur das hier"]), llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Nur das hier.")
    }

    func testNothingSaidReturnsNil() async {
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "  "]), llm: nil, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertNil(result)
    }

    func testJoinRespectsLineBreaks() {
        XCTAssertEqual(DictationSession.join(["A.", "\n\nB.", "C."]), "A.\n\nB. C.")
    }
}

// MARK: - Ollama client against a stubbed HTTP layer

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data, TimeInterval))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let (status, data, delay) = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class OllamaClientTests: XCTestCase {

    private func makeClient(timeout: TimeInterval = 2) -> OllamaClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return OllamaClient(
            configuration: .init(cleanupTimeout: timeout, rewriteTimeout: timeout),
            session: URLSession(configuration: config))
    }

    private func chatResponse(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content]])
    }

    func testSuccessfulCleanupSendsExpectedRequest() async throws {
        var captured: [String: Any]?
        StubProtocol.handler = { request in
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                captured = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return (200, self.chatResponse("<diktat>Um vier.</diktat>"), 0)
        }
        let result = try await makeClient().cleanup(text: "um drei, nein, um vier", style: .neutral)
        XCTAssertEqual(result, "Um vier.")
        XCTAssertEqual(captured?["model"] as? String, "qwen2.5:3b")
        XCTAssertEqual(captured?["stream"] as? Bool, false)
        XCTAssertEqual(captured?["keep_alive"] as? String, "15m")
    }

    func testServerErrorThrows() async {
        StubProtocol.handler = { _ in (500, Data(), 0) }
        do {
            _ = try await makeClient().cleanup(text: "Hallo", style: .neutral)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .http(500))
        }
    }

    func testTimeoutThrows() async {
        StubProtocol.handler = { _ in (200, self.chatResponse("Hallo."), 3) }
        let start = Date()
        do {
            _ = try await makeClient(timeout: 0.5).cleanup(text: "Hallo", style: .neutral)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? LLMError, .timeout)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        }
    }

    func testMalformedJSONThrows() async {
        StubProtocol.handler = { _ in (200, Data("nope".utf8), 0) }
        do {
            _ = try await makeClient().cleanup(text: "Hallo", style: .neutral)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .badResponse)
        }
    }

    func testAnswerInsteadOfCorrectionIsRejected() async {
        let answer = "Ein Integral beschreibt die Fläche unter einer Kurve und wird in der Analysis verwendet, um kontinuierliche Größen aufzusummieren und vieles mehr."
        StubProtocol.handler = { _ in (200, self.chatResponse(answer), 0) }
        do {
            _ = try await makeClient().cleanup(text: "Was ist ein Integral?", style: .neutral)
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? LLMError, .rejectedOutput)
        }
    }
}

final class SentenceLevelTests: XCTestCase {
    func testOnlyTheMessySentenceGoesToTheLLM() async {
        let llm = FakeLLM()
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: [1: "Hallo Thomas. Wir treffen uns um drei, nein, um vier. Bis dann."]),
            llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Hallo Thomas. Wir treffen uns um vier. Bis dann.")
        let calls = await llm.log.cleanups
        XCTAssertEqual(calls, ["Wir treffen uns um drei, nein, um vier."])
    }
}
