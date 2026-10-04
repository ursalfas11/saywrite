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
/// Stops asking the model for the rest of a dictation once it timed out or was unreachable, so a
/// hung Ollama costs one timeout per dictation instead of one per sentence.
public final class LLMCircuitBreaker: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    public init() {}

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tripped
    }

    /// Records a failed call. Only an unavailable model trips the breaker; a rejected answer
    /// says nothing about the next sentence.
    public func record(_ error: Error) {
        guard let error = error as? LLMError, error == .timeout || error == .unreachable else { return }
        lock.lock()
        tripped = true
        lock.unlock()
    }
}

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
        let shared = outputWords.filter { word in inputSet.contains(word) || inputSet.contains { sharesStem($0, word) } }
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

    /// "komme"/"kommen" count as the same word. Short words must match exactly, otherwise "i" or
    /// "d" would make almost any output word look like an input word.
    static func sharesStem(_ a: String, _ b: String) -> Bool {
        guard min(a.count, b.count) >= 3 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Lines a chat model puts in front of its answer ("Here is the more formal version:"). Only
    /// phrases about "the text/version" count; "Gerne komme ich …" is a legitimate rewrite.
    static let preambleMarkers = [
        "here is", "here's", "revised", "rewritten", "version", "translation",
        "hier ist", "hier die", "hier der", "überarbeitet", "umformuliert", "fassung", "übersetzung",
    ]

    static func isPreamble(_ line: String) -> Bool {
        let lower = line.lowercased()
        return preambleMarkers.contains { lower.contains($0) }
    }

    /// Checks a rewrite of `selection`. Word overlap cannot be required here ("in English" changes
    /// every word), so this catches what is clearly not a rewrite: a chat preamble with nothing
    /// after it, an answer far longer than any rewrite, or the instruction echoed back.
    public static func acceptRewrite(selection: String, instruction: String, output: String) -> String? {
        var cleaned = sanitize(output)
        // "Here is the more formal version:\n\nDear …" -> only the text after the preamble line.
        let lines = cleaned.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let selectionStart = selection.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if let first = lines.first, first.hasSuffix(":"), isPreamble(String(first)), !isPreamble(selectionStart) {
            guard lines.count == 2 else { return nil }
            cleaned = sanitize(String(lines[1]))
        }
        guard !cleaned.isEmpty else { return nil }
        guard words(cleaned) != words(instruction) else { return nil }
        let inputCount = max(1, wordCount(selection))
        // "more formal" or "in more detail" may grow a text, but not into an essay.
        guard wordCount(cleaned) <= inputCount * 3 + 30 else { return nil }
        return cleaned
    }

    /// Words that mark a correction. If the model removed only these, it did not correct anything.
    static let markerWords: Set<String> = [
        "actually", "i", "mean", "sorry", "wait", "or", "rather", "no", "nein", "nee", "ne", "ich", "meine", "moment",
        "warte", "besser", "gesagt", "also",
    ]

    /// True when the output is the input minus correction marker words only ("Actually, in March …"
    /// -> "In March …"): the sentence was not a correction and must stay as spoken.
    public static func removedOnlyMarkers(input: String, output: String) -> Bool {
        let inputWords = words(input)
        let outputWords = words(output)
        guard outputWords.count < inputWords.count else { return false }
        return inputWords.filter { !markerWords.contains($0) } == outputWords.filter { !markerWords.contains($0) }
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
