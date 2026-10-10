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
    static let notACorrection = #"(?!(?:das|der|die|dem|den|ich|du|er|sie|es|wir|ihr|so|nicht|danke|bitte|dass|oder|nein|nee|ne|und|aber|wirklich|vielleicht|mein|meine|dein|deine|unser|unsere|ein|eine|kein|keine|jetzt|schon|schade|wie|was|warum|wieso|wo|wer|da|hier|jemand|alles|nichts|man)\b)"#
    /// The same without the pronouns: after "Oder nein," a pronoun starts the corrected clause.
    static let notAnAnswer = #"(?!(?:so|nicht|danke|bitte|dass|oder|nein|nee|ne|und|aber|wirklich|vielleicht)\b)"#
    /// Words before a comma that make "nein," / "moment," an answer or an opener, not a correction.
    static let afterOpener = #"(?<!\b(?:ja|hallo|hi|hey|okay|ok|na|also|tja|naja|gut|danke))"#
    /// Verbs that introduce a quotation: "Er sagte, nein, das mache ich nicht".
    static let quoteVerbs = #"(?:sagte|sagt|sagen|gesagt|antwortete|antwortet|geantwortet|meinte|gemeint|fragte|fragt|gefragt|rief|gerufen|schrieb|geschrieben|erwiderte|erwidert|dachte|gedacht|denkt)"#

    static let correctionPatterns: [String] = [
        // A symbol or the period of an ordinal or date may stand before the comma: "5 €, nein, 6 €", "am 12., nein, am 13.".
        #"(?:[\p{L}\p{N}€$£%]|\d\.)"# + afterOpener + #",\s*(?:(?:also|oder|ach)\s+)?(?:(?:nein|nee|ne)\s*,\s*"# + notACorrection
            + #"|(?:nein|nee|ne)\s+warte\s*,\s*"# + notAnAnswer + #")\S"#,
        // "Der Termin ist am Dienstag, nein, es ist Mittwoch": a pronoun after the marker starts the new
        // clause, unless the clause before is a quotation ("Er sagte, nein, das mache ich nicht").
        #"(?:^|[.!?]\s+)(?![^.!?]*\b"# + quoteVerbs + #"\b)[^.!?]*[\p{L}\p{N}]"# + afterOpener
            + #",\s*(?:(?:also|oder|ach)\s+)?(?:nein|nee|ne)\s*,\s*(?=(?:ich|es|das|er|sie|wir|du|der|die|den|dem)\b)\S"#,
        // "ein Brot, nein, ein Brötchen": the article or possessive is repeated, so "nein," repeats the
        // phrase instead of answering. notACorrection leaves these out for a plain answer.
        #"\b(ein|kein|mein|dein|sein|unser|euer)(?:e|en|em|er|es)?\s+[^.!?,]{1,40}?,\s*(?:oder\s+)?(?:nein|nee|ne)\s*,\s*\1(?:e|en|em|er|es)?\s+\S"#,
        // "nicht vor 8 Uhr, nein, nicht vor 9 Uhr": the negation or a number comes back.
        #"(?:\bnicht\b|\d|\b(?:null|eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf)\b)[^.!?,]*,\s*(?:oder\s+)?(?:nein|nee|ne)\s*,\s*nicht\s+\S"#,
        #",\s*ich mein(?:e|te)?\b(?!\s+(?:das|es)\s+(?:ernst|so)\b)(?!\s*,\s*(?:dass|ob|das|es|er|sie|wir|man)\b)"#,
        // The recognizer often sets the comma only after the marker: "… bauen ich meine, ich will …".
        #"[\p{L}\p{N}]\s+ich mein(?:e|te)\s*,\s*(?!(?:dass|ob|das|es)\b)\S"#,
        #",\s*besser gesagt\b"#,
        #",\s*oder besser\b"#,
        // Not after an opener ("Hallo, Moment, ich komme gleich") and not before a new clause.
        afterOpener + #",\s*(?:moment|warte)\s*,\s*(?!(?:ich|du|er|sie|es|wir|ihr|man|gleich|kurz|mal|bitte|ja|okay|ok|also|vielleicht|das|dass|hier|jetzt)\b)\S"#,
        // "… Moment, ich rufe dich lieber an": a clause is a correction when it says "rather".
        #",\s*(?:moment|warte)\s*,\s*(?:ich|es|wir)\b(?=[^.!?]*\b(?:lieber|doch|eher|stattdessen|besser)\b)\S"#,
        #",\s*quatsch\s*,"#,
        #",\s*(?:sorry|pardon|entschuldigung)\s*,\s*(?:an|am|um|in|im|zu|zum|zur|bei|mit|nach|für|bis|ab|\d)(?![\p{L}])"#,
        // "um 5 nein um 6" without commas
        #"\b(?:um|am|an|bis|ab|in|im)\s+\S+(?:\s+\S+)?\s+(?:nein|nee)\s+(?:um|am|an|bis|ab|in|im)\b"#,
        // "12,99 Euro, nein 13,99 Euro": a number follows the marker, the comma after it is missing.
        #"\d[^.!?]*,\s*(?:nein|nee)\s+\d"#,
        #"\bvergiss (?:das|es)\s*[,.!]"#,
        #"\b(?:streich|lösch) das\s*[,.!]"#,
        #"\bkorrektur\s*:"#,
    ]

    /// One to three words that end the sentence and are no clause opener or filler.
    static let germanBareFragment = #"(?!(?:dass|ob|das|es|wir|ich|du|er|sie|ihr|man|damit|ja|doch|schon|nur|nicht|so|wirklich|ernsthaft|ehrlich|der|die|den|dem|ein|eine|mein|meine|dein|deine|unser|unsere)\b)[\p{L}\p{N}]+(?:\s+[\p{L}\p{N}]+){0,2}\s*[.!?]?$"#
    static let englishBareFragment = #"(?!(?:that|it|this|i|we|you|he|she|they|there|the|a|an|my|our|your|his|her|their|so|just|really|seriously|honestly|literally|not|no|yes|well|like)\b)[\p{L}\p{N}]+(?:\s+[\p{L}\p{N}]+){0,2}\s*[.!?]?$"#

    /// Sentence start that corrects or throws away the sentence before it. Deliberately narrow:
    /// "Vergiss das Ladekabel nicht", "Warte kurz", "Ich meine, dass …", "Moment mal" stay untouched.
    static let leadingPatterns: [String] = [
        // After "Oh nein," / "Ach nein," a clause is an exclamation ("Oh nein, das Backup fehlt auch").
        #"^(?:aber|also|ach|oh)\s+(?:nein|nee|ne)\b\s*,\s*"# + notACorrection + #"\S"#,
        #"^(?:äh|oder)\s+(?:nein|nee|ne)\b\s*,\s*"# + notAnAnswer + #"\S"#,
        #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?(?:vergiss (?:das|es)|(?:streich|lösch) das)\s*[,.!]"#,
        #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?(?:besser gesagt|oder besser)\b(?!\s*,?\s*(?:dass|ob|das|es|wir|ich|du|er|sie|man|damit)\b)\s*,?\s*[\p{L}\p{N}]"#,
        // "Ich meine, …" opens an opinion as often as a correction ("Ich meine, die Lösung ist gut"): only
        // a preposition or number ("Ich meine am Dienstag") or a bare fragment ("Ich meine Paul")
        // counts. A full sentence needs `correctsPrevious` to repeat the sentence before.
        #"^(?:(?:aber|sorry|entschuldigung|pardon)\s*,?\s+)?ich meine\s*,?\s*(?:(?:an|am|um|in|im|zu|zum|zur|bei|mit|nach|für|bis|ab|\d)\b|"# + germanBareFragment + #")"#,
        #"^(?:sorry|entschuldigung|pardon)\s*,\s*(?:an|am|um|in|im|zu|zum|zur|bei|mit|nach|für|bis|ab|\d)(?![\p{L}])"#,
        #"^(?:warte|moment)(?!\s+mal)\s*,\s*(?:um|am|an|im|in|zum|zur|bis|ab|nach|bei|mit|für|eher|lieber|besser|doch|nein|nee|\d)(?![\p{L}])"#,
        #"^(?:warte|moment)(?!\s+mal)\s*,\s*(?:ich|es|wir)\b(?=[^.!?]*\b(?:lieber|doch|eher|stattdessen|besser)\b)"#,
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
        if startsWithCorrection(sentence, previous: previous, language: language) { return true }
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

    /// With `previous`, "Nein, in Berlin regnet es." only counts when the fragment picks up the sentence
    /// before it (same preposition, or a number or time in it); a bare answer stays as spoken.
    public static func startsWithCorrection(_ sentence: String, previous: String? = nil, language: DictationLanguage = .german) -> Bool {
        guard language != .other else { return false }
        let lower = sentence.lowercased()
        let leading = language == .english ? englishLeadingPatterns : leadingPatterns
        if leading.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) { return true }
        let bare = language == .english ? englishBareNo : bareNein
        guard let match = lower.range(of: bare, options: .regularExpression), wordCount(sentence) <= 6 else { return false }
        guard let previous, let lead = lower[match].split(whereSeparator: { !$0.isLetter }).last.map(String.init),
              prepositions.contains(lead) else { return true }
        let before = LLMOutputGuard.words(previous)
        return before.contains(lead) || before.contains { $0.contains(where: \.isNumber) || timeWords.contains($0) }
    }

    static let prepositions: Set<String> = [
        "um", "am", "an", "im", "in", "zum", "zur", "bis", "ab", "nach", "bei", "mit", "für",
        "at", "on", "to", "for", "by", "from",
    ]
    static let timeWords: Set<String> = [
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag", "morgen", "heute", "abend",
        "uhr", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "tomorrow", "today",
        "tonight", "o'clock",
    ]

    // MARK: English

    /// Phrases after "actually," / "sorry," that are normal speech, not a correction.
    static let englishIdioms = #"(?!(?:at the moment|at least|at all|at first|in fact|in general|in my|in the end|in case|for now|for example|for sure|for real|to be honest|by the way|on the other hand)\b)"#

    static let englishNotACorrection = #"(?!(?:i|it|that|this|thanks|thank|problem|way|worries|not|no|and|but|you|we|they|he|she|really|please|maybe|the|a|an|my|our|your|their|there|what|why|how|where|who|now|so|just|is|was|are|did|do|does|everything|nothing|someone)\b)"#
    /// Without the clause openers: after "no wait," a pronoun or "the" starts the corrected text.
    static let englishNotAnAnswer = #"(?!(?:thanks|thank|problem|way|worries|not|no|and|but|really|please|maybe)\b)"#
    static let englishAfterOpener = #"(?<!\b(?:yes|yeah|oh|hi|hey|hello|okay|ok|well|so|um|uh|ah|hmm|sure))"#
    static let englishQuoteVerbs = #"(?:said|says|say|replied|answered|asked|thought|wrote|told|shouted)"#

    static let englishCorrectionPatterns: [String] = [
        #"(?:[\p{L}\p{N}€$£%]|\d\.)"# + englishAfterOpener + #",\s*(?:(?:oh|or)\s+)?(?:no\s*,\s*"# + englishNotACorrection
            + #"|no\s+wait\s*,\s*"# + englishNotAnAnswer + #")\S"#,
        // "The deadline is Friday, no, it's Thursday": a pronoun after the marker starts the new clause,
        // unless the clause before is a quotation ("He said, no, I won't").
        #"(?:^|[.!?]\s+)(?![^.!?]*\b"# + englishQuoteVerbs + #"\b)[^.!?]*[\p{L}\p{N}]"# + englishAfterOpener
            + #",\s*(?:(?:oh|or)\s+)?no\s*,\s*(?=(?:i|it|that|this|you|we|they|he|she)\b)\S"#,
        #",\s*i mean\b(?!\s*,?\s*(?:it|that|this|we|i|you|they|he|she|seriously|honestly|really|come on)\b)"#,
        #"[\p{L}\p{N}]\s+i mean\s*,\s*(?!(?:it|that|this|seriously|honestly|really|come on)\b)\S"#,
        #",\s*or rather\b"#,
        #",\s*(?:rather|actually)\s*,?\s*"# + englishIdioms + #"(?:at|on|in|to|for|by|from|\d)(?![\p{L}])"#,
        // "Let's meet Monday, make that Tuesday": any word, but not "make it work" / "make it clear".
        #",\s*make (?:that|it)\s+(?!(?:work|clear|happen|right|better|easy|easier|possible|so|up|a|an|the|simple|quick|quicker|fast|faster|short|shorter|good|nice|sure|count|real|official|known|obvious|perfect|look|sound|feel|more|less|my|our|your|their|his|her|its|this|that|it|there|to|out|through|clearer|worse|safe|happen)\b)\S"#,
        // "I want the red one, no, the blue one": the determiner comes back, so "no," repeats the phrase.
        #"\b(a|an|the|my|our|your|their)\s+[^.!?,]{1,40}?,\s*(?:or\s+)?no\s*,\s*\1\s+\S"#,
        englishAfterOpener + #",\s*wait\s*,\s*(?!(?:i|you|we|it|that|this|he|she|they|what|let|please|just|hold|okay|ok|maybe|so|now)\b)\S"#,
        #",\s*(?:sorry|pardon)\s*,\s*(?:at|on|in|to|for|by|from|\d)(?![\p{L}])"#,
        #"\b(?:at|on|in|by|from)\s+\S+(?:\s+\S+)?\s+no\s+(?:at|on|in|by|from)\b"#,
        #"\d[^.!?]*,\s*no\s+\d"#,
        #"\bscratch that\b"#,
        #"\bnever mind\s*[,.!]"#,
        #"(?<!n't )(?<!n’t )(?<!\bnot )(?<!\bnever )\bforget (?:that|it)\s*[,.!]"#,
        #"\bcorrection\s*:"#,
    ]

    static let englishLeadingPatterns: [String] = [
        #"^(?:or|actually)\s*,?\s+no\b\s*,\s*\S"#,
        // "Oh no, the backup is gone too" is an exclamation.
        #"^oh\s*,?\s+no\b\s*,\s*"# + englishNotACorrection + #"\S"#,
        #"^(?:(?:actually|sorry)\s*,?\s+)?(?:scratch that|never mind|forget (?:that|it))\s*[,.!]"#,
        #"^(?:(?:sorry)\s*,?\s+)?or rather\b(?!\s*,?\s*(?:that|it|this|i|we|you)\b)\s*,?\s*[\p{L}\p{N}]"#,
        // "I mean, she had a train to catch" is filler, not a correction. Only a preposition or number
        // ("I mean at nine"), a bare fragment ("I mean Tuesday") or "Sorry, I mean …" counts; a full
        // sentence needs `correctsPrevious` to repeat the sentence before.
        #"^(?:sorry\s*,?\s+)?i mean\s*,?\s*"# + englishIdioms + #"(?:(?:at|on|in|to|for|by|from)\b|\d|"# + englishBareFragment + #")"#,
        #"^sorry\s*,?\s+i mean\b(?!\s*,?\s*(?:that|it|this|i|we|you)\b)\s*,?\s*[\p{L}\p{N}]"#,
        #"^(?:sorry|actually)\s*,\s*"# + englishIdioms + #"(?:at|on|in|to|for|by|from|\d)(?![\p{L}])"#,
        #"^wait\s*,\s*(?:at|on|in|to|for|by|from|no|\d)(?![\p{L}])"#,
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
        return correctionWords(String(tail))
    }

    /// Words of three letters or more, no filler, no bare numbers (those are checked as numbers).
    static func correctionWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 && !fillerWords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// The corrected words that are new against the version before the marker ("fünf … bauen ich meine,
    /// ich will sechs … bauen" -> ["will", "sechs"]): what tells the new version from the old one.
    public static func changedWords(in text: String, language: DictationLanguage) -> [String] {
        guard let tail = correctedTail(in: text, language: language) else { return [] }
        // Compared word for word with the same filter, so "ich" on both sides is no change.
        let head = correctionWords(String(text.lowercased().dropLast(tail.count)))
        return correctedWords(in: text, language: language).filter { word in
            !head.contains { $0 == word || LLMOutputGuard.sharesStem($0, word) }
        }
    }

    /// The last word of the version before the marker that the corrected version does not repeat
    /// ("morgen" in "Morgen früh, nein, übermorgen früh"): the old value. An answer that still has it
    /// but not the new version's first word kept the old value. Only the last such word counts: earlier
    /// ones may be reworded by a good answer ("möchte" -> "will").
    public static func replacedWord(in text: String, language: DictationLanguage) -> String? {
        guard let tail = correctedTail(in: text, language: language) else { return nil }
        let tailWords = correctionWords(String(tail))
        return correctionWords(String(text.lowercased().dropLast(tail.count))).last { word in
            !tailWords.contains { $0 == word || LLMOutputGuard.sharesStem($0, word) }
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
        guard let match = text.range(of: namePattern, options: .regularExpression) else { return false }
        // "Ich sagte, nein, Danke": a refusal, not a correction. The quotation verb in the same
        // sentence and the polite words after "nein" rule it out, as for the other patterns.
        let sentence = text[..<match.lowerBound].split(omittingEmptySubsequences: false, whereSeparator: { ".!?".contains($0) }).last ?? ""
        let verbs = language == .english ? englishQuoteVerbs : quoteVerbs
        if sentence.lowercased().range(of: #"\b"# + verbs + #"\b"#, options: .regularExpression) != nil { return false }
        let name = String(text[match].lowercased().split(whereSeparator: { !$0.isLetter }).last ?? "")
        let polite: Set<String> = ["danke", "bitte", "thanks", "thank", "please"]
        return !polite.contains(name)
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
