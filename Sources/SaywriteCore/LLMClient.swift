import Foundation

public enum LLMError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case http(Int)
    case badResponse
    case rejectedOutput
}

/// A language model that can clean up dictations and rewrite selections.
public protocol LLMClient: Sendable {
    /// Start loading the model so the next request does not pay the cold start. Fire and forget.
    func prewarm(forRewrite: Bool) async
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String
    func rewrite(selection: String, instruction: String) async throws -> String
}

/// Guards against a small model answering, summarizing or hallucinating instead of correcting.
public enum LLMOutputGuard {

    public static func sanitize(_ output: String) -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["diktat", "vorher", "text", "anweisung", "dictation", "instruction"] {
            result = result.replacingOccurrences(of: "<\(tag)>", with: "")
            result = result.replacingOccurrences(of: "</\(tag)>", with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("->") { result = String(result.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("„", "“"), ("»", "«"), ("'", "'")]
        for (open, close) in quotePairs where result.count >= 2 && result.first == open && result.last == close {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Returns the cleaned output if it plausibly is a correction of `input`, otherwise nil.
    public static func acceptCleanup(input: String, output: String, style: Style) -> String? {
        let cleaned = sanitize(output)
        guard !cleaned.isEmpty else { return nil }
        let inputCount = max(1, wordCount(input))
        let outputCount = wordCount(cleaned)
        let ratio = Double(outputCount) / Double(inputCount)
        let upper = style == .formal ? 1.8 : 1.5
        // Most output words must come from the input; catches answers and made-up text.
        let inputSet = Set(words(input))
        let outputWords = words(cleaned)
        guard !outputWords.isEmpty else { return nil }
        let shared = outputWords.filter { word in inputSet.contains(word) || inputSet.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
        let share = Double(shared.count) / Double(outputWords.count)
        let minimumShare = style == .formal ? 0.6 : 0.75
        guard share >= minimumShare else { return nil }
        guard ratio <= upper || abs(outputCount - inputCount) <= 3 else { return nil }
        // A self-correction legitimately drops many words. Allow strong shrinking only when the
        // output is (almost) purely made of input words, i.e. the model deleted and did not invent.
        let minimumRatio = share >= 0.9 ? 0.1 : 0.5
        guard ratio >= minimumRatio || abs(outputCount - inputCount) <= 3 else { return nil }
        return cleaned
    }

    /// True when both texts have the same words in the same order (ignoring case and punctuation):
    /// the model only changed punctuation or capitalization.
    public static func sameWords(_ a: String, _ b: String) -> Bool {
        words(a) == words(b)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
