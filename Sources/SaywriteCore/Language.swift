import Foundation

/// Dictation languages with their own cleanup rules and prompts. Other languages the recognizer
/// understands are passed through with language-neutral rules only.
public enum DictationLanguage: String, CaseIterable, Sendable {
    case german = "de"
    case english = "en"
    /// Any other language the recognizer understands: language-neutral rules only, no AI cleanup.
    case other = "other"

    /// Resolves a setting ("de", "en" or "auto") for a concrete text.
    public static func resolve(setting: String, text: String) -> DictationLanguage {
        switch setting {
        case "de": return .german
        case "en": return .english
        case "auto", "":
            // Short texts without telling words keep the language of the previous dictation,
            // since people rarely switch language between two dictations.
            if let detected = detect(text) {
                lastDetected = detected
                return detected
            }
            return lastDetected ?? (UILanguage.isGerman ? .german : .english)
        default:
            return .other
        }
    }

    /// Written by the session's segment tasks, read on the main thread when priming the model.
    public static var lastDetected: DictationLanguage? {
        get {
            lastDetectedLock.lock()
            defer { lastDetectedLock.unlock() }
            return lastDetectedValue
        }
        set {
            lastDetectedLock.lock()
            lastDetectedValue = newValue
            lastDetectedLock.unlock()
        }
    }

    private static let lastDetectedLock = NSLock()
    nonisolated(unsafe) private static var lastDetectedValue: DictationLanguage?

    static let germanMarkers: Set<String> = [
        "und", "der", "die", "das", "ich", "nicht", "ist", "ein", "eine", "zu", "mit", "wir", "du", "sie", "es",
        "auf", "für", "dass", "den", "dem", "von", "bitte", "danke", "auch", "noch", "mal", "hab", "habe", "bin",
        "sind", "morgen", "heute", "kannst", "wie", "wo", "aber", "oder", "schon", "jetzt", "hier", "nein", "ja",
        "um", "er", "uhr", "bei", "nach", "im", "vom", "zum", "zur", "sehr", "gut", "wenn", "weil", "sich", "mir", "mich", "dir", "uns", "hallo", "gerne", "vielleicht", "doch",
    ]

    static let englishMarkers: Set<String> = [
        // Only words that are not also common German words ("an", "was", "will", "so", "in" are both).
        "the", "and", "i", "is", "to", "you", "not", "of", "it", "that", "for", "on", "with", "we", "are",
        "this", "be", "have", "can", "please", "thanks", "what", "how", "but", "or", "just", "at", "my",
        "your", "me", "tomorrow", "today", "do", "don't", "i'm", "it's", "there", "they", "would", "could",
        "yeah", "yes", "hey", "hello", "really", "very", "some", "about", "from", "if", "when", "then", "here",
        "thank", "sorry", "no", "should", "need", "want", "part", "let's", "i'll", "we're", "you're", "ok",
        "uh", "good", "great", "sounds", "got", "cheers", "sure", "see", "okay", "hi", "dear", "thanks",
    ]

    /// Stop-word vote; nil when the text is too short or ambiguous.
    public static func detect(_ text: String) -> DictationLanguage? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        var german = 0
        var english = 0
        for word in words {
            if germanMarkers.contains(word) { german += 1 }
            if englishMarkers.contains(word) { english += 1 }
        }
        // Umlauts in lowercase words (not in German names like "Müller" inside English text).
        if text.range(of: #"(?<![\p{L}])\p{Ll}*[äöüß]\p{Ll}*"#, options: .regularExpression) != nil { german += 1 }
        guard german != english else { return nil }
        return german > english ? .german : .english
    }
}

/// Language of the app's own interface (not the dictation): German on German systems, otherwise English.
public enum UILanguage {
    /// Fixed interface language, for tests and screenshots; nil follows the system.
    nonisolated(unsafe) public static var override: Bool?

    public static var isGerman: Bool {
        override ?? (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
    }

    /// Picks the English or German variant of an interface string.
    public static func text(_ english: String, de german: String) -> String {
        isGerman ? german : english
    }
}
