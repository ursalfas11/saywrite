import Foundation

public struct ChangeSummary: Equatable, Codable, Sendable {
    public var fillersRemoved: Int
    public var punctuationChanged: Int
    public var wordsChanged: Int
    public var usedLLM: Bool
    public var llmFailed: Bool
    public var replacements: Int = 0

    public init(fillersRemoved: Int = 0, punctuationChanged: Int = 0, wordsChanged: Int = 0, usedLLM: Bool = false, llmFailed: Bool = false, replacements: Int = 0) {
        self.fillersRemoved = fillersRemoved
        self.punctuationChanged = punctuationChanged
        self.wordsChanged = wordsChanged
        self.usedLLM = usedLLM
        self.llmFailed = llmFailed
        self.replacements = replacements
    }

    enum CodingKeys: String, CodingKey {
        case fillersRemoved, punctuationChanged, wordsChanged, usedLLM, llmFailed, replacements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fillersRemoved = try c.decode(Int.self, forKey: .fillersRemoved)
        punctuationChanged = try c.decode(Int.self, forKey: .punctuationChanged)
        wordsChanged = try c.decode(Int.self, forKey: .wordsChanged)
        usedLLM = try c.decode(Bool.self, forKey: .usedLLM)
        llmFailed = try c.decode(Bool.self, forKey: .llmFailed)
        replacements = try c.decodeIfPresent(Int.self, forKey: .replacements) ?? 0
    }

    /// Whether the inserted text differs from what was said in wording (not just punctuation).
    public var changedWording: Bool { wordsChanged > 0 || replacements > 0 }

    /// Short line for the overlay, e.g. "3 filler words · 2 punctuation · AI: 1 correction".
    public var text: String {
        let de = UILanguage.isGerman
        var parts: [String] = []
        if fillersRemoved > 0 {
            parts.append(de ? "\(fillersRemoved) \(fillersRemoved == 1 ? "Füllwort" : "Füllwörter")"
                            : "\(fillersRemoved) \(fillersRemoved == 1 ? "filler" : "fillers")")
        }
        if punctuationChanged > 0 {
            parts.append(de ? "\(punctuationChanged) Satzzeichen"
                            : "\(punctuationChanged) punctuation \(punctuationChanged == 1 ? "fix" : "fixes")")
        }
        if replacements > 0 {
            parts.append(de ? "\(replacements) \(replacements == 1 ? "Ersetzung" : "Ersetzungen")"
                            : "\(replacements) \(replacements == 1 ? "replacement" : "replacements")")
        }
        if wordsChanged > 0 {
            let label = de ? (wordsChanged == 1 ? "Korrektur" : "Korrekturen") : (wordsChanged == 1 ? "correction" : "corrections")
            let prefix = usedLLM ? (de ? "KI: " : "AI: ") : ""
            parts.append("\(prefix)\(wordsChanged) \(label)")
        }
        var line = parts.isEmpty ? (de ? "unverändert" : "unchanged") : parts.joined(separator: " · ")
        if llmFailed { line += de ? " · ⚠ ohne KI" : " · ⚠ without AI" }
        return line
    }
}

/// Word-level diff between what was recognized and what was inserted.
public enum ChangeSummarizer {

    public static func summarize(
        raw: String, final: String, usedLLM: Bool, llmFailed: Bool, replacements: Int = 0,
        language: DictationLanguage = .german
    ) -> ChangeSummary {
        let fillers = Set(RuleCleaner.fillers(language))
        let rawTokens = tokens(raw)
        let finalTokens = tokens(final)
        let rawWords = rawTokens.map(word)
        let finalWords = finalTokens.map(word)

        let pairs = lcsPairs(rawWords, finalWords)
        var matchedRaw = Set<Int>()
        var matchedFinal = Set<Int>()
        var punctuation = 0
        for (r, f) in pairs {
            matchedRaw.insert(r)
            matchedFinal.insert(f)
            if trailingPunctuation(rawTokens[r]) != trailingPunctuation(finalTokens[f]) { punctuation += 1 }
        }

        var fillerCount = 0
        var deletedWords = 0
        for (i, w) in rawWords.enumerated() where !matchedRaw.contains(i) {
            if fillers.contains(w) { fillerCount += 1 } else if !w.isEmpty { deletedWords += 1 }
        }
        var insertedWords = 0
        var insertedPunctuationOnly = 0
        for (i, w) in finalWords.enumerated() where !matchedFinal.contains(i) {
            if w.isEmpty { insertedPunctuationOnly += 1 } else { insertedWords += 1 }
        }

        return ChangeSummary(
            fillersRemoved: fillerCount,
            punctuationChanged: punctuation + insertedPunctuationOnly,
            wordsChanged: max(deletedWords, insertedWords),
            usedLLM: usedLLM,
            llmFailed: llmFailed,
            replacements: replacements
        )
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercased token without surrounding punctuation. Capitalization changes are not counted.
    static func word(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func trailingPunctuation(_ token: String) -> String {
        String(token.reversed().prefix { $0.isPunctuation }.reversed())
    }

    /// Indices of matched tokens via longest common subsequence.
    static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
