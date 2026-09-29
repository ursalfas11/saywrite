import Foundation

public enum GateDecision: Equatable, Sendable {
    case rulesOnly
    case llm(reason: String)

    public var usesLLM: Bool {
        if case .llm = self { return true }
        return false
    }
}

/// Decides, without any model, whether a segment is messy enough to need the LLM.
public enum CleanupGate {

    /// Phrases that signal the speaker corrected themselves mid-sentence. They require the commas the
    /// recognizer puts around a spoken correction, so "Die Antwort war nein", "im Moment" or
    /// "ich meine, das passt" do not trigger the model.
    /// Words after "nein," that mean it is an answer or part of the sentence, not a correction
    /// ("Er sagte, nein, das mache ich nicht", "super, ne, dass du kommst").
    static let notACorrection = #"(?!(?:das|der|die|dem|den|ich|du|er|sie|es|wir|ihr|so|nicht|danke|bitte|dass|oder|nein|nee|ne|und|aber|wirklich)\b)"#

    static let correctionPatterns: [String] = [
        #"[\p{L}\p{N}],\s*(?:(?:also|oder|ach)\s+)?(?:nein|nee|ne)(?:\s+warte)?\s*,\s*"# + notACorrection + #"\S"#,
        #",\s*ich mein(?:e|te)?\b(?!\s+(?:das|es)\s+(?:ernst|so)\b)"#,
        #",\s*besser gesagt\b"#,
        #",\s*oder besser\b"#,
        #",\s*moment\s*,"#,
        #",\s*warte\s*,"#,
        #",\s*quatsch\s*,"#,
        #",\s*(?:sorry|pardon|entschuldigung)\s*,\s*(?:an|am|um|in|im|zu|zum|zur|bei|mit|nach|für|bis|ab|\d)"#,
        // "um 5 nein um 6" without commas
        #"\b(?:um|am|an|bis|ab|in|im)\s+\S+\s+(?:nein|nee)\s+(?:um|am|an|bis|ab|in|im)\b"#,
        #"\bvergiss (?:das|es)\s*[,.!]"#,
        #"\b(?:streich|lösch) das\s*[,.!]"#,
        #"\bkorrektur\s*:"#,
    ]

    /// Sentence start that corrects or throws away the sentence before it. Deliberately narrow:
    /// "Vergiss das Ladekabel nicht", "Warte kurz", "Ich meine, dass …", "Moment mal" stay untouched.
    static let leadingPatterns: [String] = [
        #"^(?:aber|also|ach|oh|äh|oder)\s+(?:nein|nee|ne)\b\s*,"#,
        #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?(?:vergiss (?:das|es)|(?:streich|lösch) das)\s*[,.!]"#,
        #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?(?:ich meine|besser gesagt|oder besser)\b(?!\s*,?\s*(?:dass|ob|das|es|wir|ich|du|er|sie|man|damit)\b)\s*,?\s*[\p{L}\p{N}]"#,
        #"^(?:sorry|entschuldigung|pardon)\s*,\s*(?:an|am|um|in|im|zu|zum|zur|bei|mit|nach|für|bis|ab|\d)"#,
        #"^(?:warte|moment)(?!\s+mal)\s*,\s*(?:um|am|an|im|in|zum|zur|bis|ab|nach|bei|mit|für|eher|lieber|besser|doch|nein|nee|\d)"#,
        #"^(?:quatsch|korrektur)\b\s*[,:!]"#,
    ]

    /// "Nein, um sechs." after a pause: only short fragments count, a full sentence starting with
    /// "Nein, am Montag kann ich leider nicht" is an answer.
    static let bareNein = #"^(?:nein|nee|ne)\b\s*,?\s*(?:um|am|an|im|in|zum|zur|bis|ab|nach|bei|mit|für|eher|lieber|besser|doch|erst|\d+|null|eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf)\b"#

    public static func startsWithCorrection(_ sentence: String, language: DictationLanguage = .german) -> Bool {
        let lower = sentence.lowercased()
        let leading = language == .english ? englishLeadingPatterns : leadingPatterns
        if leading.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return true }
        let bare = language == .english ? englishBareNo : bareNein
        return lower.range(of: bare, options: .regularExpression) != nil && wordCount(sentence) <= 6
    }

    // MARK: English

    /// Phrases after "actually," / "sorry," that are normal speech, not a correction.
    static let englishIdioms = #"(?!(?:at the moment|at least|at all|at first|in fact|in general|in my|in the end|in case|for now|for example|for sure|for real|to be honest|by the way|on the other hand)\b)"#

    static let englishNotACorrection = #"(?!(?:i|it|that|this|thanks|thank|problem|way|worries|not|no|and|but|you|we|they|he|she|really|please)\b)"#

    static let englishCorrectionPatterns: [String] = [
        #"[\p{L}\p{N}],\s*(?:(?:oh|or)\s+)?no(?:\s+wait)?\s*,\s*"# + englishNotACorrection + #"\S"#,
        #",\s*i mean\b(?!\s*,?\s*(?:it|that|this|we|i|you|they|he|she|seriously|honestly|really|come on)\b)"#,
        #",\s*or rather\b"#,
        #",\s*(?:rather|actually)\s*,?\s*"# + englishIdioms + #"(?:at|on|in|to|for|by|from|the|\d)"#,
        #",\s*make (?:that|it)\s+(?:\d|one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
        #",\s*wait\s*,"#,
        #",\s*(?:sorry|pardon)\s*,\s*(?:at|on|in|to|for|by|from|\d)"#,
        #"\b(?:at|on|in|by|from)\s+\S+\s+no\s+(?:at|on|in|by|from)\b"#,
        #"\bscratch that\b"#,
        #"\bnever mind\s*[,.!]"#,
        #"\bforget (?:that|it)\s*[,.!]"#,
        #"\bcorrection\s*:"#,
    ]

    static let englishLeadingPatterns: [String] = [
        #"^(?:oh|or|actually)\s*,?\s+no\b\s*,"#,
        #"^(?:(?:actually|sorry)\s*,?\s+)?(?:scratch that|never mind|forget (?:that|it))\s*[,.!]"#,
        #"^(?:(?:sorry)\s*,?\s+)?(?:i mean|or rather)\b(?!\s*,?\s*(?:that|it|this|i|we|you)\b)\s*,?\s*[\p{L}\p{N}]"#,
        #"^(?:sorry|actually)\s*,\s*"# + englishIdioms + #"(?:at|on|in|to|for|by|from|\d)"#,
        #"^wait\s*,\s*(?:at|on|in|to|for|by|from|no|\d)"#,
    ]

    static let englishBareNo = #"^no\b\s*,?\s*(?:at|on|in|to|for|by|from|rather|\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"#

    /// Numbers spoken after the last correction marker: the corrected values that must survive
    /// ("2 bottles, wait, 3 bottles" -> "3").
    public static func correctedNumbers(in text: String, language: DictationLanguage) -> [String] {
        let lower = text.lowercased()
        let patterns = (language == .english ? englishCorrectionPatterns + englishLeadingPatterns : correctionPatterns + leadingPatterns)
        var lastEnd: String.Index?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                guard let range = Range(match.range, in: lower) else { continue }
                if lastEnd == nil || range.upperBound > lastEnd! { lastEnd = range.upperBound }
            }
        }
        guard let lastEnd else { return [] }
        // Start right after the marker word itself, so the number that belongs to the new version counts.
        let start = lower.index(lastEnd, offsetBy: -1, limitedBy: lower.startIndex) ?? lastEnd
        let tail = lower[start...]
        return tail.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }

    static let maxWordsWithoutPunctuation = 25
    static let longSegmentWords = 60

    public static func decide(raw: String, style: Style, language: DictationLanguage = .german) -> GateDecision {
        let hasCorrection = containsCorrection(raw, language: language)

        if style == .casual {
            return hasCorrection ? .llm(reason: "Selbstkorrektur") : .rulesOnly
        }
        if hasCorrection {
            return .llm(reason: "Selbstkorrektur")
        }
        if longestRunWithoutPunctuation(raw) > maxWordsWithoutPunctuation {
            return .llm(reason: "lange Passage ohne Satzzeichen")
        }
        if wordCount(raw) > longSegmentWords {
            return .llm(reason: "langes Diktat")
        }
        return .rulesOnly
    }

    static func containsCorrection(_ text: String, language: DictationLanguage = .german) -> Bool {
        let lower = text.lowercased()
        let patterns = language == .english ? englishCorrectionPatterns : correctionPatterns
        if patterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return true }
        // "Send it to Mark, sorry, Mike": a correction marker followed by a name (checked on original case).
        let namePattern = language == .english
            ? #",\s*(?i:sorry|i mean|actually|no)\s*,?\s*\p{Lu}\p{Ll}+[.!?]?$"#
            : #",\s*(?i:sorry|ich meine|nein|nee)\s*,?\s*\p{Lu}\p{Ll}+[.!?]?$"#
        return text.range(of: namePattern, options: .regularExpression) != nil
    }

    static func longestRunWithoutPunctuation(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            current += 1
            longest = max(longest, current)
            if let last = token.last, ",.;:!?".contains(last) { current = 0 }
        }
        return longest
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
