import Foundation

public enum LLMError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case http(Int)
    case badResponse
    case rejectedOutput
    /// The selection does not fit the model's context (the built-in model has 4096 tokens).
    case tooLong
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

    /// Records a failed call. Only an unavailable model trips the breaker: a timeout, an unreachable
    /// server, a missing model (404) or a failing server (5xx, unreadable answer). A rejected answer
    /// says nothing about the next sentence.
    public func record(_ error: Error) {
        guard let error = error as? LLMError else { return }
        switch error {
        case .timeout, .unreachable, .badResponse: break
        case .http(let status) where status == 404 || status >= 500: break
        default: return
        }
        lock.lock()
        tripped = true
        lock.unlock()
    }
}

public enum LLMOutputGuard {

    /// `input` is the text the model was given: quotes that the dictation itself opened with stay.
    public static func sanitize(_ output: String, input: String = "") -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["diktat", "vorher", "text", "anweisung", "dictation", "instruction"] {
            result = result.replacingOccurrences(of: "<\(tag)>", with: "")
            result = result.replacingOccurrences(of: "</\(tag)>", with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("->") { result = String(result.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("„", "“"), ("»", "«"), ("'", "'")]
        let inputStart = input.trimmingCharacters(in: .whitespacesAndNewlines).first
        for (open, close) in quotePairs where result.count >= 2 && result.first == open && result.last == close {
            // One quotation around the whole answer is the model's habit; two quotations, or a quote
            // the dictation started with, belong to the text.
            let inner = result.dropFirst().dropLast()
            guard inputStart != open, !inner.contains(open), !inner.contains(close) else { continue }
            result = String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    /// Returns the cleaned output if it plausibly is a correction of `input`, otherwise nil.
    public static func acceptCleanup(input: String, output: String, style: Style) -> String? {
        let cleaned = sanitize(output, input: input)
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

    // MARK: Corrections

    /// Phrases that introduce a correction, longest first.
    static let markerPhrases: [[String]] = [
        ["besser", "gesagt"], ["oder", "besser"], ["ich", "meine"], ["ich", "meinte"], ["ich", "mein"],
        ["i", "mean"], ["or", "rather"], ["make", "that"], ["make", "it"], ["no", "wait"],
        ["nein", "warte"], ["moment"], ["warte"], ["wait"], ["quatsch"], ["sorry"], ["pardon"],
        ["entschuldigung"], ["korrektur"], ["correction"], ["actually"], ["rather"], ["nein"], ["nee"], ["ne"], ["no"],
        ["vergiss", "das"], ["vergiss", "es"], ["streich", "das"], ["lösch", "das"], ["scratch", "that"],
        ["never", "mind"], ["forget", "that"], ["forget", "it"],
    ]
    /// Markers that throw the sentence before away instead of replacing a part of it.
    static let discardPhrases: Set<[String]> = [
        ["vergiss", "das"], ["vergiss", "es"], ["streich", "das"], ["lösch", "das"], ["scratch", "that"],
        ["never", "mind"], ["forget", "that"], ["forget", "it"],
    ]
    /// Words that may stand in front of a marker ("ach nein", "nein warte", "oh no").
    static let markerPrefixes: Set<String> = ["oder", "also", "ach", "aber", "oh", "äh", "or", "nein", "nee", "no", "sorry", "actually"]

    /// The input cut at its correction markers: the text before the first one, then each marker with the
    /// words after it. Nil when no marker with something after it is found.
    struct CorrectionSplit {
        /// Words before the last marker, the last marker, and the new version after it.
        var head: [String]
        var marker: [String]
        var tail: [String]
        /// The text between the markers: `segments[0]` is before the first one.
        var segments: [[String]]
        var discards: Bool { LLMOutputGuard.discardPhrases.contains { marker.suffix($0.count) == $0[...] } }
    }

    static func splitAtCorrection(_ input: String) -> CorrectionSplit? {
        let all = words(input)
        var segments: [[String]] = [[]]
        var markers: [[String]] = []
        var index = 0
        while index < all.count {
            if index + 1 < all.count, let phrase = markerPhrases.first(where: { phrase in
                index + phrase.count < all.count && Array(all[index..<index + phrase.count]) == phrase
            }) {
                if segments[segments.count - 1].isEmpty, !markers.isEmpty {
                    // "Sorry, ich meine …", "nein, Entschuldigung, …": one marker in two parts.
                    markers[markers.count - 1] += phrase
                    index += phrase.count
                    continue
                }
                // "ach nein", "nein warte", "oh no": the lead-in belongs to the marker.
                var lead: [String] = []
                while let last = segments[segments.count - 1].last, markerPrefixes.contains(last), segments.count > 1 || segments[0].count > 1 {
                    lead.insert(segments[segments.count - 1].removeLast(), at: 0)
                }
                markers.append(lead + phrase)
                segments.append([])
                index += phrase.count
            } else {
                segments[segments.count - 1].append(all[index])
                index += 1
            }
        }
        guard let marker = markers.last else { return nil }
        let tail = segments[segments.count - 1]
        let head = segments.dropLast().enumerated().flatMap { offset, segment in offset == 0 ? segment : markers[offset - 1] + segment }
        return CorrectionSplit(head: head, marker: marker, tail: tail, segments: segments)
    }

    static let spokenNumbers: [String: String] = [
        "null": "0", "zero": "0", "eins": "1", "one": "1", "zwei": "2", "two": "2", "drei": "3", "three": "3",
        "vier": "4", "four": "4", "fünf": "5", "five": "5", "sechs": "6", "six": "6", "sieben": "7", "seven": "7",
        "acht": "8", "eight": "8", "neun": "9", "nine": "9", "zehn": "10", "ten": "10", "elf": "11", "eleven": "11",
        "zwölf": "12", "twelve": "12",
    ]

    /// "three" and "drei" are the digit 3 for comparing; other words stay as they are.
    static func canonicalNumber(_ word: String) -> String { spokenNumbers[word] ?? word }

    /// Number words and digits in `words`, as digits.
    static func numberValues(_ words: [String]) -> Set<String> {
        Set(words.compactMap { word in
            if let value = spokenNumbers[word] { return value }
            return word.allSatisfy(\.isNumber) ? word : nil
        })
    }

    /// Structure checks for an answer to a text with a self-correction. The model may drop the old
    /// version and the marker; it must not lose the rest, reorder it, keep the marker or the old
    /// value, or invent words.
    public static func keepsCorrectionStructure(input: String, output: String) -> Bool {
        let inputWords = words(input)
        let outputWords = words(output)
        guard !outputWords.isEmpty else { return false }

        // Words that are not in the input at all (invented), and words that are there but in another place.
        // The new version may move into the slot of the old one ("roten Pullover, oder besser den blauen"
        // -> "den blauen Pullover"), so a few moved words are fine; a swapped text is not.
        func matches(_ a: String, _ b: String) -> Bool { a == b || sharesStem(a, b) || canonicalNumber(a) == canonicalNumber(b) }
        var cursor = 0
        var invented = 0
        var moved = 0
        for word in outputWords {
            if let index = inputWords[cursor...].firstIndex(where: { matches($0, word) }) {
                cursor = index + 1
            } else if inputWords.contains(where: { matches($0, word) }) {
                moved += 1
            } else {
                invented += 1
            }
        }
        // Short sentences have no room for an invented word.
        guard invented <= (inputWords.count <= 8 ? 0 : 1) else { return false }

        guard let split = splitAtCorrection(input) else { return moved <= 1 }
        guard moved <= max(2, split.tail.count) else { return false }
        func has(_ word: String, in list: [String]) -> Bool {
            list.contains { $0 == word || sharesStem($0, word) || canonicalNumber($0) == canonicalNumber(word) }
        }

        // The marker itself must be gone (unless the new version says the same words again).
        let tailText = split.tail.joined(separator: " ")
        let markerText = split.marker.joined(separator: " ")
        let outputText = outputWords.joined(separator: " ")
        if split.marker.count >= 2, outputText.contains(markerText), !tailText.contains(markerText) { return false }
        if split.marker.count == 1, split.marker[0].count >= 5, has(split.marker[0], in: outputWords), !has(split.marker[0], in: split.tail) {
            return false
        }

        // Numbers of the new version must be there, whether spoken or written as digits.
        if !numberValues(split.tail).isSubset(of: numberValues(outputWords)) { return false }

        // The old number must not stay next to the new one ("Two coffees, make that three" -> "Two coffees,
        // make it three" kept "two" only by luck). Words are not checked: which of them is the old value
        // is not clear without parsing ("roten Pullover, oder besser den blauen").
        let isNumber: (String) -> Bool = { spokenNumbers[$0] != nil || $0.allSatisfy(\.isNumber) }
        if split.tail.contains(where: isNumber), let old = split.head.last(where: isNumber), !has(old, in: split.tail),
           has(old, in: outputWords), numberValues(split.tail).isSubset(of: numberValues(outputWords)) {
            return false
        }

        guard !split.discards else { return true }
        // The beginning stays: the new version replaces about as many words as it has, the rest before
        // each marker must survive in order ("Bring bitte 2 Flaschen, Moment, 3 Flaschen" keeps "Bring").
        // Checked per marker, so a second correction in the same text does not demand the old version of the first.
        for (offset, segment) in split.segments.dropLast().enumerated() {
            // The start is what a model drops: two words are enough to tell (where the new version replaces the old one is not known, so more would reject
            // "Ruf mich morgen an, nein, übermorgen" for dropping "morgen").
            // A longer new version still must not swallow the first word of a segment that has more
            // than one ("Übersetze das ins Englische, nein, ins Französische: Guten Morgen").
            let keepCount = min(2, max(segment.count > 1 ? 1 : 0, segment.count - split.segments[offset + 1].count))
            var position = 0
            // A number the next version replaces ("Two coffees, make that three") may be gone.
            let replacesNumber = split.segments[offset + 1].contains(where: isNumber)
            for word in segment.prefix(keepCount) where !(replacesNumber && isNumber(word)) {
                guard let index = outputWords[position...].firstIndex(where: { matches($0, word) }) else { return false }
                position = index + 1
            }
        }
        // The new version stays nearly whole: one dropped content word is a filler ("natürlich"), two or more
        // change the meaning ("..., ich meine, dass wir es annehmen sollten" -> "..., annehmen sollten").
        let lostTail = split.tail.filter { $0.count >= 4 && !has($0, in: outputWords) }
        if lostTail.count >= 2 { return false }
        // The end of the new version stays ("… 3 Flaschen Wasser mit": "mit" is not dropped).
        if let last = split.tail.last, !has(last, in: outputWords) { return false }
        return true
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
