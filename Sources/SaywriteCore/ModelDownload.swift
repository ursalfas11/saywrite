import CryptoKit
import Foundation

/// A model file the app downloads once: where from, how big, and which SHA-256 it must have.
public struct ModelSpec: Sendable, Equatable {
    public var fileName: String
    public var url: URL
    public var size: Int64
    public var sha256: String
    public var displayName: String
    public var licenseName: String
    public var licenseURL: URL

    public init(fileName: String, url: URL, size: Int64, sha256: String, displayName: String, licenseName: String, licenseURL: URL) {
        self.fileName = fileName
        self.url = url
        self.size = size
        self.sha256 = sha256.lowercased()
        self.displayName = displayName
        self.licenseName = licenseName
        self.licenseURL = licenseURL
    }

    /// Qwen2.5-3B-Instruct, Q4_K_M, the bartowski build (same size as Ollama's qwen2.5:3b within 256
    /// bytes), pinned by repository commit and SHA-256.
    public static let qwen25_3b = ModelSpec(
        fileName: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/f302c64a2269a69fb27b2f9473b362f5bb8e78d8/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
        size: 1_929_903_264,
        sha256: "9c9f56a391a3abbd5b89d0245bf6106081bcc3173119d4229235dd9d23253f94",
        displayName: "Qwen2.5-3B-Instruct (Q4_K_M)",
        licenseName: "Qwen Research License",
        licenseURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct/blob/main/LICENSE")!
    )
}

/// Where model files live and what state they are in on disk.
public struct ModelStore: Sendable {
    public var directory: URL

    public init(directory: URL = ModelStore.defaultDirectory) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Saywrite/Models
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Saywrite/Models", isDirectory: true)
    }

    public func fileURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName) }
    public func partURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName + ".part") }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Cheap check used at launch: the finished file exists and has the pinned size. The full hash is
    /// checked once, right after the download.
    public func isInstalled(_ spec: ModelSpec) -> Bool {
        Self.fileSize(fileURL(spec)) == spec.size
    }

    /// Bytes of an interrupted download, if any.
    public func partialBytes(_ spec: ModelSpec) -> Int64 {
        guard let size = Self.fileSize(partURL(spec)), size > 0, size <= spec.size else { return 0 }
        return size
    }

    public func status(_ spec: ModelSpec) -> ModelDiskStatus {
        if isInstalled(spec) { return .installed }
        let partial = partialBytes(spec)
        return partial > 0 ? .partial(bytes: partial) : .missing
    }

    /// Removes the model and any partial download.
    public func delete(_ spec: ModelSpec) {
        try? FileManager.default.removeItem(at: fileURL(spec))
        try? FileManager.default.removeItem(at: partURL(spec))
    }
}

public enum ModelDiskStatus: Sendable, Equatable {
    case missing
    case partial(bytes: Int64)
    case installed
}

public enum ModelDownloadError: Error, Equatable, Sendable {
    /// Less than the needed space is free.
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case http(Int)
    /// The connection ended before the whole file arrived; the partial file is kept for a resume.
    case incomplete
    /// The file does not have the pinned hash. The partial file has been deleted.
    case hashMismatch
    /// The server answered with something that cannot be the model (an HTML page, a wrong size). The partial file has been deleted.
    case unexpectedResponse
    case network(String)
}

extension ModelDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughDiskSpace(let needed, let available):
            return "Not enough disk space (\(needed / 1_000_000) MB needed, \(available / 1_000_000) MB free)"
        case .http(let status): return "The server answered with status \(status)"
        case .incomplete: return "The download was interrupted"
        case .hashMismatch: return "The downloaded file is corrupted"
        case .unexpectedResponse: return "The server did not send the model file"
        case .network(let message): return message
        }
    }
}

/// Downloads a `ModelSpec` into a `ModelStore`: resumes an interrupted download with an HTTP Range
/// request, hashes the bytes while they are written, and moves the file to its final name only after
/// the SHA-256 matches. A wrong file is deleted, an interrupted one is kept.
public final class ModelDownloader: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    }

    public enum Phase: Sendable, Equatable {
        case downloading(Progress)
        case verifying
    }

    private let spec: ModelSpec
    private let store: ModelStore
    private let configuration: URLSessionConfiguration
    private let availableDiskSpace: @Sendable (URL) -> Int64
    /// Extra room beyond the model itself (the hash pass and the rename need none, but a full disk is a poor place to stop).
    static let diskMargin: Int64 = 300_000_000

    public init(
        spec: ModelSpec,
        store: ModelStore = ModelStore(),
        configuration: URLSessionConfiguration = .ephemeral,
        availableDiskSpace: @escaping @Sendable (URL) -> Int64 = { ModelDownloader.systemAvailableSpace(at: $0) }
    ) {
        self.spec = spec
        self.store = store
        self.configuration = configuration
        self.availableDiskSpace = availableDiskSpace
    }

    public static func systemAvailableSpace(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    /// Runs the download to completion and returns the verified file. Cancelling the task keeps the
    /// partial file (a pause); the next run continues from it.
    @discardableResult
    public func run(onPhase: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let final = store.fileURL(spec)
        let part = store.partURL(spec)

        if store.isInstalled(spec) { return final }

        var attempt = 0
        while true {
            attempt += 1
            var offset = store.partialBytes(spec)
            if offset == 0 { try? fm.removeItem(at: part) }

            let needed = spec.size - offset + Self.diskMargin
            let available = availableDiskSpace(store.directory)
            guard available >= needed else { throw ModelDownloadError.notEnoughDiskSpace(needed: needed, available: available) }

            var hasher = SHA256()
            if offset > 0 {
                // The hash covers the whole file, so the bytes already on disk go through it first.
                try Self.hash(file: part, into: &hasher)
            } else {
                fm.createFile(atPath: part.path, contents: nil)
            }

            if offset < spec.size {
                let outcome: Outcome
                do {
                    outcome = try await transfer(from: offset, part: part, hasher: &hasher, onPhase: onPhase)
                } catch ModelDownloadError.unexpectedResponse {
                    try? fm.removeItem(at: part)
                    throw ModelDownloadError.unexpectedResponse
                }
                switch outcome {
                case .done: break
                case .restart:
                    // 416 or a server that ignored Range with a wrong answer: the partial file does not fit. Start over once.
                    try? fm.removeItem(at: part)
                    guard attempt < 2 else { throw ModelDownloadError.http(416) }
                    continue
                }
                offset = store.partialBytes(spec)
            }

            guard store.partialBytes(spec) == spec.size else { throw ModelDownloadError.incomplete }
            onPhase(.verifying)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == spec.sha256 else {
                try? fm.removeItem(at: part)
                throw ModelDownloadError.hashMismatch
            }
            try? fm.removeItem(at: final)
            try fm.moveItem(at: part, to: final)
            return final
        }
    }

    /// Full SHA-256 of a file, for checking an existing model.
    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        try hash(file: url, into: &hasher)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hash(file: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
    }

    private enum Outcome { case done, restart }

    private func transfer(from offset: Int64, part: URL, hasher: inout SHA256, onPhase: @escaping @Sendable (Phase) -> Void) async throws -> Outcome {
        var request = URLRequest(url: spec.url)
        request.timeoutInterval = 60
        request.setValue("Saywrite", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let sink = try ChunkSink(part: part, startOffset: offset, total: spec.size, hasher: hasher, onPhase: onPhase)
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: sink.queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        let result: ChunkSink.Result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sink.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        hasher = sink.hasher
        sink.close()
        switch result {
        case .finished: return .done
        case .restart: return .restart
        case .cancelled: throw CancellationError()
        case .failed(let error): throw error
        }
    }
}

/// Receives the chunks of one request, appends them to the partial file and feeds the hash.
private final class ChunkSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Result { case finished, restart, cancelled, failed(ModelDownloadError) }

    let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dev.saywrite.download"
        return queue
    }()

    private let part: URL
    private let total: Int64
    private let onPhase: @Sendable (ModelDownloader.Phase) -> Void
    private let startOffset: Int64
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Result, Never>?
    private var written: Int64
    private var lastReport = Date.distantPast
    private var verdict: Result?
    private(set) var hasher: SHA256

    init(part: URL, startOffset: Int64, total: Int64, hasher: SHA256, onPhase: @escaping @Sendable (ModelDownloader.Phase) -> Void) throws {
        self.part = part
        self.startOffset = startOffset
        self.total = total
        self.written = startOffset
        self.hasher = hasher
        self.onPhase = onPhase
        self.handle = try FileHandle(forWritingTo: part)
        try handle?.seekToEnd()
    }

    func start(_ continuation: CheckedContinuation<Result, Never>) { self.continuation = continuation }
    func close() { try? handle?.close(); handle = nil }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            verdict = .failed(.network("No HTTP response"))
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            // The server must continue exactly where the file ends.
            if startOffset > 0, let range = http.value(forHTTPHeaderField: "Content-Range"), !range.contains("bytes \(startOffset)-") {
                verdict = .restart
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case 200:
            let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            if type.contains("text/html") || (length != nil && length != total) {
                // A captive portal or an error page, not the model.
                verdict = .failed(.unexpectedResponse)
                completionHandler(.cancel)
                return
            }
            if startOffset > 0 {
                // Range ignored: the body is the whole file again. Start over without Range, which also
                // checks the disk space for the whole file.
                verdict = .restart
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        case 416:
            verdict = .restart
            completionHandler(.cancel)
        default:
            verdict = .failed(.http(http.statusCode))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if written + Int64(data.count) > total {
            // More than the model: never write without limit.
            verdict = .failed(.unexpectedResponse)
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            verdict = .failed(.network("Cannot write the model file: \(error.localizedDescription)"))
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        written += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.2 || written >= total {
            lastReport = now
            onPhase(.downloading(.init(bytesDone: written, bytesTotal: total)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let verdict { finish(verdict); return }
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.cancelled); return }
            // A dropped connection keeps the partial file: the next run resumes. Only bytes of this run count,
            // and a TLS or certificate failure is shown as it is, not as an interruption to retry.
            let code = (error as? URLError)?.code
            let tlsFailure = code.map { $0.rawValue <= URLError.secureConnectionFailed.rawValue && $0.rawValue >= URLError.clientCertificateRequired.rawValue } ?? false
            finish(.failed(written > startOffset && !tlsFailure ? .incomplete : .network(error.localizedDescription)))
            return
        }
        finish(.finished)
    }
}
