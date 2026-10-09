import CryptoKit
import XCTest
@testable import SaywriteCore

/// A URL protocol that serves a scripted answer, so the download logic runs without a network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Send only this many bytes, then drop the connection.
        var cutAfter: Int?
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Answer)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (URLRequest) -> Answer) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }

    static var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let answer = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = answer.cutAfter.map { answer.body.prefix($0) } ?? answer.body[...]
        var index = body.startIndex
        while index < body.endIndex {
            let end = min(body.endIndex, index + 700)
            client?.urlProtocol(self, didLoad: Data(body[index..<end]))
            index = end
        }
        if answer.cutAfter != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class ModelDownloadTests: XCTestCase {
    private var directory: URL!
    private let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

    private var spec: ModelSpec {
        ModelSpec(
            fileName: "test.gguf", url: URL(string: "https://example.invalid/test.gguf")!, size: Int64(payload.count),
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            displayName: "Test", licenseName: "Test", licenseURL: URL(string: "https://example.invalid/license")!)
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("saywrite-dl-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        StubURLProtocol.handler = nil
    }

    private func downloader(space: Int64 = .max) -> ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ModelDownloader(spec: spec, store: ModelStore(directory: directory), configuration: configuration, availableDiskSpace: { _ in space })
    }

    /// Serves `payload`, honouring a Range header like Hugging Face does.
    private func rangeServer(cutFirstAfter: Int? = nil) -> (URLRequest) -> StubURLProtocol.Answer {
        let payload = payload
        nonisolated(unsafe) var first = true
        return { request in
            var answer = StubURLProtocol.Answer()
            if let range = request.value(forHTTPHeaderField: "Range"), let start = Int(range.dropFirst("bytes=".count).dropLast()) {
                answer.status = 206
                answer.headers["Content-Range"] = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
                answer.body = payload.suffix(from: start)
            } else {
                answer.body = payload
            }
            if first, let cut = cutFirstAfter { answer.cutAfter = cut }
            first = false
            return answer
        }
    }

    func testFullDownloadVerifiesAndMovesToFinalName() async throws {
        StubURLProtocol.reset(rangeServer())
        let url = try await downloader().run()
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let store = ModelStore(directory: directory)
        XCTAssertEqual(store.status(spec), .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(spec).path))
        XCTAssertNil(StubURLProtocol.recorded[0].value(forHTTPHeaderField: "Range"))
    }

    func testInterruptedDownloadResumesWithRangeRequest() async throws {
        StubURLProtocol.reset(rangeServer(cutFirstAfter: 3_000))
        let store = ModelStore(directory: directory)
        do {
            _ = try await downloader().run()
            XCTFail("the first attempt is cut")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .incomplete)
        }
        XCTAssertEqual(store.status(spec), .partial(bytes: 3_000))

        let url = try await downloader().run()
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertEqual(StubURLProtocol.recorded[1].value(forHTTPHeaderField: "Range"), "bytes=3000-")
    }

    func testCorruptedDownloadIsDeleted() async throws {
        var wrong = payload
        wrong[5_000] ^= 0xFF
        StubURLProtocol.reset { _ in .init(body: wrong) }
        do {
            _ = try await downloader().run()
            XCTFail("the hash must not match")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .hashMismatch)
        }
        XCTAssertEqual(ModelStore(directory: directory).status(spec), .missing)
    }

    func testCorruptedPartialFileIsRejectedAfterResume() async throws {
        // A bad prefix on disk makes the final hash fail, and the file is removed.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: ModelStore(directory: directory).partURL(spec))
        StubURLProtocol.reset(rangeServer())
        do {
            _ = try await downloader().run()
            XCTFail("the hash must not match")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .hashMismatch)
        }
        XCTAssertEqual(StubURLProtocol.recorded[0].value(forHTTPHeaderField: "Range"), "bytes=2000-")
        XCTAssertEqual(ModelStore(directory: directory).status(spec), .missing)
    }

    func testServerIgnoringRangeRestartsTheFile() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(4_000).write(to: ModelStore(directory: directory).partURL(spec))
        StubURLProtocol.reset { [payload] _ in .init(status: 200, body: payload) }
        let url = try await downloader().run()
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testRangeNotSatisfiableStartsOverOnce() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(4_000).write(to: ModelStore(directory: directory).partURL(spec))
        let payload = payload
        StubURLProtocol.reset { request in
            request.value(forHTTPHeaderField: "Range") != nil ? .init(status: 416) : .init(body: payload)
        }
        let url = try await downloader().run()
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertNil(StubURLProtocol.recorded[1].value(forHTTPHeaderField: "Range"))
    }

    func testServerErrorIsReported() async throws {
        StubURLProtocol.reset { _ in .init(status: 503) }
        do {
            _ = try await downloader().run()
            XCTFail("503 must fail")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .http(503))
        }
    }

    func testNotEnoughDiskSpaceStopsBeforeAnyRequest() async throws {
        StubURLProtocol.reset(rangeServer())
        do {
            _ = try await downloader(space: 5_000).run()
            XCTFail("no room")
        } catch let error as ModelDownloadError {
            guard case .notEnoughDiskSpace = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testInstalledModelIsNotDownloadedAgain() async throws {
        let store = ModelStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: store.fileURL(spec))
        StubURLProtocol.reset(rangeServer())
        _ = try await downloader().run()
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testOversizedPartialFileIsDiscarded() async throws {
        let store = ModelStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 9, count: payload.count + 10).write(to: store.partURL(spec))
        XCTAssertEqual(store.status(spec), .missing)
        StubURLProtocol.reset(rangeServer())
        let url = try await downloader().run()
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertNil(StubURLProtocol.recorded[0].value(forHTTPHeaderField: "Range"))
    }

    func testCompletePartialFileIsVerifiedWithoutNetwork() async throws {
        let store = ModelStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: store.partURL(spec))
        StubURLProtocol.reset(rangeServer())
        _ = try await downloader().run()
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
        XCTAssertEqual(store.status(spec), .installed)
    }

    func testStoreStatusAndDelete() throws {
        let store = ModelStore(directory: directory)
        XCTAssertEqual(store.status(spec), .missing)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(100).write(to: store.partURL(spec))
        XCTAssertEqual(store.status(spec), .partial(bytes: 100))
        try payload.write(to: store.fileURL(spec))
        XCTAssertEqual(store.status(spec), .installed)
        store.delete(spec)
        XCTAssertEqual(store.status(spec), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(spec).path))
    }

    func testPinnedSpec() {
        let spec = ModelSpec.qwen25_3b
        XCTAssertEqual(spec.sha256.count, 64)
        XCTAssertEqual(spec.size, 1_929_903_264)
        XCTAssertTrue(spec.url.absoluteString.contains("f302c64a2269a69fb27b2f9473b362f5bb8e78d8"), "pinned to a commit, not a branch")
        XCTAssertTrue(ModelStore.defaultDirectory.path.hasSuffix("Saywrite/Models"))
    }

    func testStateFromDisk() {
        XCTAssertEqual(BuiltinModelState.initial(for: .missing), .notDownloaded)
        XCTAssertEqual(BuiltinModelState.initial(for: .partial(bytes: 5)), .partial(bytes: 5))
        XCTAssertEqual(BuiltinModelState.initial(for: .installed), .ready)
        XCTAssertTrue(BuiltinModelState.downloading(0.5).isBusy)
        XCTAssertTrue(BuiltinModelState.optimizing.isBusy)
        XCTAssertFalse(BuiltinModelState.partial(bytes: 5).isBusy)
        XCTAssertFalse(BuiltinModelState.failed("x").isBusy)
    }
}
