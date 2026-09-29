import Foundation

/// The user's dictionary: how certain words or phrases should be written ("gitt hab" -> "GitHub").
/// Applied as a fixed rule after cleanup, never through the model.
public struct Replacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heard: String
    public var written: String

    public init(id: UUID = UUID(), heard: String, written: String) {
        self.id = id
        self.heard = heard
        self.written = written
    }
}

public enum ReplacementEngine {
    /// Returns the text with all replacements applied and how many were made.
    public static func apply(_ replacements: [Replacement], to text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        // Longer phrases first, so "fluid audio" wins over "audio".
        for entry in replacements.sorted(by: { $0.heard.count > $1.heard.count }) {
            let heard = entry.heard.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty else { continue }
            let words = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s,]+"#) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.numberOfMatches(in: result, range: range)
            guard matches > 0 else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: entry.written))
            count += matches
        }
        return (result, count)
    }
}
