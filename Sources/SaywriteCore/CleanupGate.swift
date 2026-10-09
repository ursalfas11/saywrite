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
        // The recognizer often sets the comma only after the marker: "… bauen ich meine, ich will …".
        #"[\p{L}\p{N}]\s+ich mein(?:e|te)\s*,\s*(?!(?:dass|ob|das|es)\b)\S"#,
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

    /// "Ich meine, …" / "I mean, …" at a sentence start, whatever follows. On its own that is mostly an
    /// opinion ("Ich meine, ich fand es trotzdem schön"); see `correctsPrevious`.
    static let echoMarker = #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?(?:ich meine|besser gesagt|oder besser)\s*,"#
    static let englishEchoMarker = #"^(?:(?:sorry|oh)\s*,?\s+)?(?:i mean|or rather)\s*,"#
    /// The same marker inside a joined text, for finding where the new version starts.
    static let echoTail = #"(?:^|[.!?]\s+)(?:ich meine|besser gesagt|oder besser)\s*,\s*\S"#
    static let englishEchoTail = #"(?:^|[.!?]\s+)(?:i mean|or rather)\s*,\s*\S"#

    /// Whether `sentence` corrects `previous`: a marker at its start, or "Ich meine, …" that repeats
    /// the sentence before ("Ich möchte fünf Systeme bauen." + "Ich meine, ich will sechs Systeme bauen.").
    /// Two shared content words tell a correction from an opinion that only starts the same way.
    public static func correctsPrevious(_ sentence: String, previous: String?, language: DictationLanguage = .german) -> Bool {
        if startsWithCorrection(sentence, language: language) { return true }
        guard language != .other, let previous, !previous.isEmpty else { return false }
        let lower = sentence.lowercased()
        guard let marker = lower.range(of: language == .english ? englishEchoMarker : echoMarker, options: .regularExpression) else {
            return false
        }
        let before = contentWords(previous.lowercased())
        let repeated = Set(contentWords(String(lower[marker.upperBound...]))).filter { word in
            before.contains { $0 == word || LLMOutputGuard.sharesStem($0, word) }
        }
        return repeated.count >= 2
    }

    static func contentWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 && !fillerWords.contains($0) }
    }

    /// "Nein, um sechs." after a pause: only short fragments count, a full sentence starting with
    /// "Nein, am Montag kann ich leider nicht" is an answer.
    static let bareNein = #"^(?:nein|nee|ne)\b\s*,?\s*(?:um|am|an|im|in|zum|zur|bis|ab|nach|bei|mit|für|eher|lieber|besser|doch|erst|\d+|null|eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf)\b"#

    public static func startsWithCorrection(_ sentence: String, language: DictationLanguage = .german) -> Bool {
        guard language != .other else { return false }
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
        #"[\p{L}\p{N}]\s+i mean\s*,\s*(?!(?:it|that|this|seriously|honestly|really|come on)\b)\S"#,
        #",\s*or rather\b"#,
        #",\s*(?:rather|actually)\s*,?\s*"# + englishIdioms + #"(?:at|on|in|to|for|by|from|\d)"#,
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
        guard let tail = correctedTail(in: text, language: language) else { return [] }
        return tail.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }

    /// Short and function words that a correct result may drop or change around the new version.
    static let fillerWords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "aber",
        "doch", "noch", "mal", "dann", "also", "bitte", "nein", "nee", "meine", "meinte", "warte", "moment",
        "besser", "gesagt", "sorry", "the", "and", "but", "then", "please", "mean", "meant", "wait", "rather",
        "actually", "scratch", "that", "make", "just", "only", "instead", "nur", "lieber", "eher", "stattdessen",
    ]

    /// The content words after the last correction marker: the new version that must survive
    /// ("am Montag nein am Dienstag" -> ["dienstag"]). A result without them kept the old version.
    public static func correctedWords(in text: String, language: DictationLanguage) -> [String] {
        guard let tail = correctedTail(in: text, language: language) else { return [] }
        return tail.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 && !fillerWords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// The corrected words that are new against the version before the marker ("fünf … bauen ich meine,
    /// ich will sechs … bauen" -> ["will", "sechs"]): what tells the new version from the old one.
    public static func changedWords(in text: String, language: DictationLanguage) -> [String] {
        guard let tail = correctedTail(in: text, language: language) else { return [] }
        let head = contentWords(String(text.lowercased().dropLast(tail.count)))
        return correctedWords(in: text, language: language).filter { word in
            !head.contains { $0 == word || LLMOutputGuard.sharesStem($0, word) }
        }
    }

    /// The lowercased text from the last correction marker on, nil without one.
    static func correctedTail(in text: String, language: DictationLanguage) -> Substring? {
        let lower = text.lowercased()
        let patterns = language == .english
            ? englishCorrectionPatterns + englishLeadingPatterns + [englishEchoTail]
            : correctionPatterns + leadingPatterns + [echoTail]
        var lastEnd: String.Index?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                guard let range = Range(match.range, in: lower) else { continue }
                if lastEnd == nil || range.upperBound > lastEnd! { lastEnd = range.upperBound }
            }
        }
        guard let lastEnd else { return nil }
        // Start right after the marker word itself, so the number that belongs to the new version counts.
        let start = lower.index(lastEnd, offsetBy: -1, limitedBy: lower.startIndex) ?? lastEnd
        return lower[start...]
    }

    static let maxWordsWithoutPunctuation = 25
    static let longSegmentWords = 60

    public static func decide(raw: String, style: Style, language: DictationLanguage = .german) -> GateDecision {
        guard language != .other else { return .rulesOnly }
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
