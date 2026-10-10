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
        // Earlier versions stored a rewrite as "[instruction] selected text": drop those once.
        let kept = cache.filter { !Self.isRewriteEntry($0) }
        if kept.count != cache.count {
            cache = kept
            save(kept)
        }
    }

    /// An entry written for a rewrite by an earlier version: "[instruction]" plus the selected text.
    /// Rewrites are no longer stored at all, the selection and its result are the user's own document.
    static func isRewriteEntry(_ result: DictationResult) -> Bool {
        // Rewrites were stored with latency 0; a dictation always has a measured latency, so "[Applause] thanks"
        // from a recognizer stays.
        result.latency == 0 && result.raw.hasPrefix("[") && result.raw.contains("] ")
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

    /// Drops entries older than `interval`, so dictations do not stay on disk indefinitely.
    public func removeOlder(than interval: TimeInterval, now: Date = Date()) {
        lock.lock()
        let kept = cache.filter { now.timeIntervalSince($0.date) <= interval }
        let changed = kept.count != cache.count
        cache = kept
        lock.unlock()
        if changed { save(kept) }
    }

    public func clear() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        save([])
    }

    private func save(_ items: [DictationResult]) {
        do {
            // Dictations can be private: readable by this user only, from the first byte on.
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.history.encode(items)
            let temp = fileURL.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: temp)
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return
            }
            // rename(2) replaces the old file atomically and keeps the mode of the temporary one.
            if rename(temp.path, fileURL.path) != 0 { try? FileManager.default.removeItem(at: temp) }
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
