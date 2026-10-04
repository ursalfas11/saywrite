import Foundation

/// The last dictations (raw and final), stored as JSON on this Mac only.
public final class HistoryStore: @unchecked Sendable {
    public static let limit = 20

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [DictationResult]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let items = try? JSONDecoder.history.decode([DictationResult].self, from: data) {
            cache = items
        } else {
            cache = []
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Saywrite", isDirectory: true).appendingPathComponent("history.json")
    }

    /// Newest first.
    public var items: [DictationResult] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func append(_ result: DictationResult) {
        lock.lock()
        cache.insert(result, at: 0)
        if cache.count > Self.limit { cache.removeLast(cache.count - Self.limit) }
        let snapshot = cache
        lock.unlock()
        save(snapshot)
    }

    public func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        save([])
    }

    private func save(_ items: [DictationResult]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.history.encode(items)
            try data.write(to: fileURL, options: .atomic)
            // Dictations can be private: readable by this user only.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // History is a convenience; failing to save must never break dictation.
        }
    }
}

extension JSONEncoder {
    static let history: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()
}

extension JSONDecoder {
    static let history: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
