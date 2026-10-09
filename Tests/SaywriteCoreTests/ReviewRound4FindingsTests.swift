import XCTest
@testable import SaywriteCore

/// Findings of review round 4.
final class ReviewRound4FindingsTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    // MARK: "ich meine, dass ..." is an opinion filler

    func testIchMeineWithClauseAfterCommaIsNoCorrection() {
        for text in ["Das Angebot ist okay, ich meine, dass wir es annehmen sollten.",
                     "Ich finde den Entwurf gelungen, ich meine, er ist schlüssig und klar aufgebaut.",
                     "Das klingt gut, ich meine, ob wir das schaffen."] {
            XCTAssertFalse(CleanupGate.decide(raw: text, style: .neutral).usesLLM, text)
        }
        XCTAssertTrue(CleanupGate.decide(raw: "Wir treffen uns am Dienstag, ich meine, am Mittwoch.", style: .neutral).usesLLM)
    }

    // MARK: Guard keeps the middle

    func testGuardRejectsLostWordsOfTheNewVersion() {
        XCTAssertFalse(LLMOutputGuard.keepsCorrectionStructure(
            input: "Wir treffen uns am Montag, nein, am Dienstag in der großen Halle.", output: "Wir treffen uns am Dienstag."))
        XCTAssertFalse(LLMOutputGuard.keepsCorrectionStructure(
            input: "Das Angebot ist okay, ich meine, dass wir es annehmen sollten.", output: "Das Angebot ist okay."))
    }

    // MARK: Corrections after a symbol or an ordinal period

    func testCorrectionAfterSymbolOrOrdinalReachesTheModel() {
        for text in ["Der Preis ist 5 €, nein, 6 €.", "Die Rabatte liegen bei 10 %, nein, bei 15 %.",
                     "Das Meeting ist am 12., nein, am 13. Mai.", "Der Termin ist am 3.10., nein, am 4.10."] {
            XCTAssertTrue(CleanupGate.decide(raw: text, style: .neutral).usesLLM, text)
        }
        XCTAssertTrue(CleanupGate.decide(raw: "The discount is 10%, no, 15%.", style: .neutral, language: .english).usesLLM)
    }

    // MARK: History file mode

    func testHistoryFileAndFolderArePrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saywrite-hist-\(UUID().uuidString)/sub")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: file)
        for text in ["a", "b"] {
            store.append(DictationResult(
                raw: text, final: text, style: .neutral, appBundleID: nil,
                summary: ChangeSummarizer.summarize(raw: text, final: text, usedLLM: false, llmFailed: false), latency: 1))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirMode, 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
        XCTAssertEqual(HistoryStore(fileURL: file).items.count, 2)
    }

    // MARK: Download errors

    func testResumeWithoutNewBytesShowsTheRealNetworkError() async throws {
        let payload = Data(repeating: 7, count: 4_000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saywrite-dl4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = ModelSpec(
            fileName: "t.gguf", url: URL(string: "https://example.invalid/t.gguf")!, size: Int64(payload.count), sha256: "00",
            displayName: "T", licenseName: "T", licenseURL: URL(string: "https://example.invalid/l")!)
        let store = ModelStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(1_000).write(to: store.partURL(spec))
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .notConnectedToInternet] {
            StubURLProtocol.reset { _ in
                var answer = StubURLProtocol.Answer()
                answer.status = 206
                answer.headers["Content-Range"] = "bytes 1000-3999/4000"
                answer.cutAfter = 0
                answer.failCode = code
                return answer
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            let downloader = ModelDownloader(spec: spec, store: store, configuration: configuration, availableDiskSpace: { _ in .max })
            do {
                _ = try await downloader.run()
                XCTFail("must fail")
            } catch let error as ModelDownloadError {
                if case .network = error {} else { XCTFail("\(code): \(error)") }
            }
        }
        StubURLProtocol.handler = nil
    }

    // MARK: Breaker

    func testTooLongDoesNotTripTheBreaker() {
        let breaker = LLMCircuitBreaker()
        breaker.record(LLMError.tooLong)
        XCTAssertFalse(breaker.isOpen)
    }
}
