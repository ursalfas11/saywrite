import Foundation

/// Deterministic, instant cleanup that runs on every dictation, with or without the LLM.
///
/// `clean` works on a single segment (fillers, stutter, spoken commands).
/// `finalize` works on the joined text (capitalization, terminal punctuation, whitespace).
public enum RuleCleaner {

    static let germanFillers = ["ähm", "äähm", "ähmm", "äh", "ääh", "öhm", "öh", "ehm", "hm", "hmm", "mhm", "hmhm"]
    static let englishFillers = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hm", "mhm"]
    /// All filler words, used by the change summary.
    static let fillerWords = germanFillers + englishFillers

    static func fillers(_ language: DictationLanguage) -> [String] {
        language == .english ? englishFillers : germanFillers
    }

    static let englishEmphasis: Set<String> = [
        "very", "really", "so", "no", "yes", "yeah", "bye", "thanks", "ha", "haha", "ok", "okay", "go", "well", "please",
        "much", "many", "blah", "bla", "far", "hey", "knock", "chop", "more", "again", "over", "round", "on",
    ]
    static let englishDoubles: Set<String> = ["that", "had", "is"]
    /// Words before "period" that make it the noun ("the grace period", "a waiting period").
    static let englishPeriodModifiers: Set<String> = [
        "grace", "waiting", "time", "trial", "probation", "notice", "cooling", "billing", "warranty", "return",
        "reporting", "test", "long", "short", "whole", "entire", "brief", "certain", "given", "same", "this", "that",
    ]
    /// Words before a command phrase that make it content ("the comma", "our new line of shoes").
    static let englishDeterminers: Set<String> = [
        "the", "a", "an", "this", "that", "my", "your", "his", "her", "our", "their", "its", "no", "one", "any", "each",
        "big", "huge", "small", "another", "every", "some", "same", "first", "last", "quote",
    ]

    /// Words that people legitimately repeat for emphasis; never collapsed.
    static let emphasisWords: Set<String> = [
        "sehr", "ganz", "so", "nein", "ja", "na", "ha", "haha", "bye", "tschüss", "danke", "hallo", "gut", "okay", "ok",
    ]

    /// Words that are correct German when doubled ("dass das das Beste ist", "die Frau, die die Blumen").
    static let grammaticalDoubles: Set<String> = ["der", "die", "das", "den", "dem", "des", "was", "wer", "sie"]

    /// Words before a command word that show it is content, not a command ("das Komma fehlt",
    /// "eine neue Zeile", "die Klammer").
    static let determiners: Set<String> = [
        "das", "der", "die", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "kein", "keine",
        "keinen", "keiner", "dieses", "diesen", "diese", "dieser", "jedes", "jeden", "jede", "am", "im", "vom", "zum",
        "zur", "beim", "welches", "welche", "ne", "nen", "mit", "ohne", "als",
    ]

    /// Spoken punctuation. "Punkt" is deliberately missing: the recognizer sets periods itself, and
    /// "der wichtigste Punkt" or "um Punkt acht" must stay as spoken.
    static let punctuationCommands: [String: String] = [
        "ausrufezeichen": "!", "fragezeichen": "?", "doppelpunkt": ":", "semikolon": ";", "komma": ",",
    ]

    /// Abbreviations that end with a period but do not end a sentence.
    public static let abbreviations: Set<String> = [
        "z.", "b.", "z.b.", "d.", "h.", "d.h.", "u.", "a.", "u.a.", "usw.", "etc.", "ca.", "bzw.", "vgl.", "nr.", "dr.",
        "prof.", "evtl.", "ggf.", "inkl.", "zzgl.", "bspw.", "mio.", "mrd.", "std.", "min.", "max.", "str.", "tel.",
        "abs.", "art.", "bd.", "jh.", "o.", "ä.", "o.ä.", "s.", "sog.", "u.u.", "v.a.", "z.t.", "e.v.", "gmbh.", "hr.", "fr.",
        "e.g.", "i.e.", "vs.", "mr.", "mrs.", "ms.", "no.", "approx.", "a.m.", "p.m.", "st.", "jr.", "sr.", "inc.", "ltd.",
    ]

    /// Capitalized words that start a new sentence or a correction after a number ("um 5. Nein, um 6.",
    /// "Hauptstraße 12. Ach nein"). After any other capitalized word a number plus period stays an
    /// ordinal, because German nouns are capitalized ("die 3. Etage", "am 5. Oktober").
    static let sentenceStartsAfterNumber: Set<String> = [
        "nein", "nee", "ach", "oder", "moment", "warte", "quatsch", "ich", "aber", "also", "vergiss", "sorry", "dann",
        "no", "wait", "actually", "oops", "never", "scratch", "i", "we", "but", "so", "then",
    ]

    /// The first word of `text` (leading whitespace skipped).
    static func firstWord(of text: Substring) -> Substring {
        text.drop(while: { $0.isWhitespace }).prefix(while: { !$0.isWhitespace })
    }

    /// True when the period at the end of `token` does not end a sentence (abbreviation, ordinal).
    /// `following` is the text after the period; a number followed by a capitalized sentence starter
    /// ends the sentence instead of being an ordinal.
    static func isNonTerminalPeriod(_ token: Substring, following: Substring = "") -> Bool {
        let lower = token.lowercased()
        if abbreviations.contains(lower) { return true }
        // Letter-dot abbreviations: u.s., u.k., e.u., i.e.
        if lower.range(of: #"^(?:\p{L}\.){2,}$"#, options: .regularExpression) != nil { return true }
        let body = lower.dropLast()
        // A number ("5.") or a short German date ("3.10.", "15.03.", "1.1.2025.").
        let isShortDate = body.range(of: #"^\d{1,2}\.\d{1,2}(?:\.\d{2,4})?$"#, options: .regularExpression) != nil
        guard !body.isEmpty, body.allSatisfy(\.isNumber) || isShortDate else { return false }
        let next = firstWord(of: following)
        if next.first?.isUppercase == true, sentenceStartsAfterNumber.contains(normalizeToken(String(next))) { return false }
        return true
    }

    static let numberWords: Set<String> = [
        "null", "eins", "ein", "eine", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "zwanzig", "dreißig", "hundert", "tausend",
    ]

    // MARK: - Segment cleanup

    public static func clean(_ text: String, language: DictationLanguage = .german) -> String {
        var result = text
        guard language != .other else { return normalizeWhitespace(result) }
        result = removeFillers(result, language: language)
        result = collapseStutter(result, language: language)
        if language == .english {
            result = applyEnglishCommands(result)
        } else {
            result = applySymbolCommands(result)
            result = applyLayoutCommands(result)
        }
        result = normalizeWhitespace(result)
        return result
    }

    static func removeFillers(_ text: String, language: DictationLanguage = .german) -> String {
        let alternation = fillers(language).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let clauseStarts = language == .english
            ? "that|which|who|because|if|when|but|no|sorry|i mean|or|i|we|he|she|they|maybe|perhaps|then|actually"
            : "ob|dass|weil|wenn|als|obwohl|damit|sodass|wie|was|wo|warum|welche[rsn]?|der|die|das|den|dem|aber|sondern|denn|nein|nee|ne|also|sorry|oder|ich meine|besser|ich|wir|er|man|vielleicht|dann"
        // ", äh," between two parts of a sentence: the commas only mark the hesitation, unless a
        // subordinate clause follows, which needs its comma ("fragen, ob").
        var result = text.replacingOccurrences(
            of: #",\s*(?i:"# + alternation + #")(?![\p{L}\p{N}-])\s*,\s*(?=(?i:"# + clauseStarts + #")\b)"#,
            with: ", ", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #",\s*(?i:"# + alternation + #")(?![\p{L}\p{N}-])\s*,\s*"#,
            with: " ", options: .regularExpression)
        // Filler as a standalone word, together with the comma/dot the recognizer attached to it.
        // Only lower case or a capital first letter: "ER" (emergency room) and "UM" stay.
        let casedAlternation = fillers(language).map { word in
            "(?:" + NSRegularExpression.escapedPattern(for: word) + "|" + NSRegularExpression.escapedPattern(for: word.prefix(1).uppercased() + word.dropFirst()) + ")"
        }.joined(separator: "|")
        // A filler at the start of a sentence takes its period with it ("Ähm. Also ..."); anywhere else
        // the period or question mark stays as the sentence end ("morgen äh. Dann").
        result = result.replacingOccurrences(
            of: #"(?:^|(?<=[.?!] ))(?:"# + casedAlternation + #")(?![\p{L}\p{N}-])[,.…]*\s*"#,
            with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}-])(?:"# + casedAlternation + #")(?![\p{L}\p{N}-])[,…]*"#,
            with: "", options: .regularExpression)
        // "Em," / "Äm," at the very start of a dictation.
        result = result.replacingOccurrences(
            of: #"^(?i:em|emm|äm|ämm|öm|um|uh|uhm)[,.…]\s*"#, with: "", options: .regularExpression)
        if language == .german {
            // Lowercase-only spellings of "ähm" the recognizer produces ("EM" stays: Europameisterschaft).
            result = result.replacingOccurrences(
                of: #"(?<![\p{L}\p{N}-])(?:em|emm|äm|ämm|öm|ähem)(?![\p{L}\p{N}-])[,.…]*"#,
                with: "", options: .regularExpression)
            // Parakeet sometimes renders "ähm" as a lone capital M inside a sentence. Keep real letters:
            // "Größe M oder L", "M wie Martha", "Variante M ist günstiger". Only after a lowercase word
            // (verb, adverb) or a comma; a capitalized word before it is almost always a noun it labels.
            result = result.replacingOccurrences(
                of: #"((?<![\p{L}\p{N}-])\p{Ll}[\p{L}]*|,) (?<!(?i:größe|typ|klasse|buchstabe|gruppe|variante|modell|paket|stufe|format|version|kategorie|plan|set) )Mm?(?= \p{Ll})(?! (?:wie|oder|und)\b)"#,
                with: "$1", options: .regularExpression)
        }
        result = tidyAfterRemoval(result)
        return result
    }

    static func collapseStutter(_ text: String, language: DictationLanguage = .german) -> String {
        let emphasis = language == .english ? englishEmphasis : emphasisWords
        let doubles = language == .english ? englishDoubles : grammaticalDoubles
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var changed = true
        while changed {
            changed = false
            for size in [2, 1] {
                var i = 0
                while i + 2 * size <= tokens.count {
                    let first = Array(tokens[i..<i + size])
                    let second = Array(tokens[i + size..<i + 2 * size])
                    let firstNorm = first.map(normalizeToken)
                    let secondNorm = second.map(normalizeToken)
                    let endsClause = first.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") || $0.hasSuffix(",") } ?? false
                    let nextWord = i + 2 * size < tokens.count ? tokens[i + 2 * size] : ""
                    let isNumber = firstNorm.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                    // "dass das das Beste", "die die Blumen" (noun follows) are correct; "der der beste" is a stutter.
                    // English "that that" / "had had" are grammatical regardless of what follows.
                    let nounFollows = language == .english || (nextWord.first?.isUppercase ?? false)
                    let isGrammatical = doubles.contains(firstNorm[0]) && nounFollows
                    let isAllowedDouble = isNumber || (size == 1 && (emphasis.contains(firstNorm[0]) || isGrammatical))
                    let hasNewline = first.contains { $0.contains("\n") }
                    if firstNorm == secondNorm, !firstNorm.contains(""), !endsClause, !isAllowedDouble, !hasNewline {
                        tokens.removeSubrange(i..<i + size)
                        changed = true
                    } else {
                        i += 1
                    }
                }
            }
        }
        return tokens.joined(separator: " ")
    }

    /// Spoken punctuation, quotes and brackets.
    static func applySymbolCommands(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var quoteOpen = false
        var i = 0

        func previousIsDeterminer(_ index: Int) -> Bool {
            guard index > 0 else { return false }
            return determiners.contains(normalizeToken(tokens[index - 1]))
        }
        func stripTrailingPunctuation(_ token: String) -> String {
            var token = token
            while let last = token.last, ",.;:!?".contains(last) { token.removeLast() }
            return token
        }
        func isNumber(_ token: String) -> Bool {
            let norm = normalizeToken(token)
            return !norm.isEmpty && norm.allSatisfy(\.isNumber)
        }

        while i < tokens.count {
            let norm = normalizeToken(tokens[i])
            let next = i + 1 < tokens.count ? normalizeToken(tokens[i + 1]) : nil

            // "Klammer auf" / "Klammer zu"
            if norm == "klammer", let next, next == "auf" || next == "zu", !previousIsDeterminer(i) {
                if next == "auf" {
                    tokens.removeSubrange(i...i + 1)
                    if i < tokens.count { tokens[i] = "(" + tokens[i] } else { tokens.append("(") }
                } else {
                    let trailing = String(tokens[i + 1].reversed().prefix { ",.;:!?".contains($0) }.reversed())
                    tokens.removeSubrange(i...i + 1)
                    if i > 0 { tokens[i - 1] = stripTrailingPunctuation(tokens[i - 1]) + ")" + trailing } else { tokens.insert(")", at: 0) }
                }
                continue
            }

            // "Anführungszeichen" toggles between opening „ and closing “.
            if norm == "anführungszeichen" || norm == "gänsefüßchen", !previousIsDeterminer(i) {
                let trailing = String(tokens[i].reversed().prefix { ",.;:!?".contains($0) }.reversed())
                tokens.remove(at: i)
                if !quoteOpen {
                    if i < tokens.count { tokens[i] = "„" + tokens[i] } else { tokens.append("„") }
                } else if i > 0 {
                    tokens[i - 1] = stripTrailingPunctuation(tokens[i - 1]) + "“" + trailing
                }
                quoteOpen.toggle()
                continue
            }

            if let symbol = punctuationCommands[norm], i > 0, !previousIsDeterminer(i) {
                // "2 Komma 5" is a decimal number, "zwei Komma fünf" stays as spoken.
                if norm == "komma", let next {
                    let prevIsNumber = isNumber(tokens[i - 1])
                    if prevIsNumber, isNumber(tokens[i + 1]) {
                        tokens[i - 1] = stripTrailingPunctuation(tokens[i - 1]) + "," + tokens[i + 1]
                        tokens.removeSubrange(i...i + 1)
                        continue
                    }
                    if numberWords.contains(normalizeToken(tokens[i - 1])) && numberWords.contains(next) {
                        i += 1
                        continue
                    }
                }
                tokens[i - 1] = stripTrailingPunctuation(tokens[i - 1]) + symbol
                tokens.remove(at: i)
                continue
            }
            i += 1
        }
        return tokens.joined(separator: " ")
    }

    /// English spoken commands. Multi-word commands are matched as phrases; a determiner before
    /// them ("the question mark", "a new line") means they are content.
    static func applyEnglishCommands(_ text: String) -> String {
        var result = text
        let determiner = #"(?<!\b(?i:"# + englishDeterminers.sorted().joined(separator: "|") + #") )"#
        let punctuation: [(String, String)] = [
            (#"question mark"#, "?"), (#"exclamation (?:mark|point)"#, "!"), (#"semicolon"#, ";"),
            (#"colon(?! (?:cancer|surgery|cleanse|polyps?|screening|health))"#, ":"), (#"comma"#, ","), (#"full stop"#, "."),
        ]
        for (phrase, symbol) in punctuation {
            result = result.replacingOccurrences(
                of: #"[ \t]*[,.;:!?]*[ \t]*"# + determiner + #"\b(?i:"# + phrase + #")\b[,.;:!?]*"#,
                with: symbol, options: .regularExpression)
        }
        let pairs: [(String, String)] = [
            (#"(?:open|begin) (?:quote|quotes|quotation marks?)"#, "\u{201C}"),
            (#"(?:close|end) (?:quote|quotes|quotation marks?)|(?<!quote )unquote"#, "\u{201D}"),
            (#"open (?:paren|parenthesis|parentheses|bracket)"#, "("),
            (#"close (?:paren|parenthesis|parentheses|bracket)"#, ")"),
        ]
        for (phrase, symbol) in pairs {
            let opening = symbol == "\u{201C}" || symbol == "("
            let pattern = opening
                ? determiner + #"\b(?i:"# + phrase + #")\b[,.]?\s*"#
                : #"[ \t]*[,.]?[ \t]*"# + determiner + #"\b(?i:"# + phrase + #")\b"#
            result = result.replacingOccurrences(of: pattern, with: symbol, options: .regularExpression)
        }
        // "period" only as a command at the end or right before a line break ("a period of time" stays).
        let periodNoun = #"(?<!\b(?i:"# + englishPeriodModifiers.union(englishDeterminers).sorted().joined(separator: "|") + #") )"#
        result = result.replacingOccurrences(
            of: #"[ \t]*[,.]?[ \t]*"# + periodNoun + #"\b(?i:period)\b[.]?(?=\s*$|\s+(?i:new|next) (?i:line|paragraph))"#,
            with: ".", options: .regularExpression)
        for (phrase, replacement) in [(#"new paragraph"#, "\n\n"), (#"(?:new|next) line"#, "\n")] {
            result = result.replacingOccurrences(
                of: #"[ \t]*"# + determiner + #"\b(?i:"# + phrase + #")\b[\s,.;]*"#,
                with: replacement, options: .regularExpression)
        }
        // Lowercase "i" as a word is always "I".
        result = result.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}'./@_-])i(?=(?:'(?:m|ll|d|ve|s))?(?![\p{L}\p{N}/@_-])(?!\.[\p{L}\p{N}]))"#,
            with: "I", options: .regularExpression)
        return result
    }

    static func applyLayoutCommands(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [
            (#"(?:neuer|nächster)\s+absatz"#, "\n\n"),
            (#"(?:neue|nächste)\s+zeile"#, "\n"),
        ] {
            guard let regex = try? NSRegularExpression(
                pattern: #"[ \t]*\b"# + pattern + #"\b[\s,.;]*"#, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                // "eine neue Zeile", "ein neuer Absatz" are content.
                let before = result[..<range.lowerBound]
                let previousWord = before.split(whereSeparator: { $0.isWhitespace }).last.map { normalizeToken(String($0)) }
                if let previousWord, determiners.contains(previousWord) || previousWord == "ein" { continue }
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    // MARK: - Final pass over joined text

    public static func finalize(_ text: String, style: Style, language: DictationLanguage = .german) -> String {
        var result = normalizeWhitespace(text)
        if style == .formal, language != .other {
            result = expandShortForms(result, forms: language == .english ? englishShortForms : shortForms)
        }
        // A line that ends in a word before a paragraph/line break gets a period, except greeting and
        // closing lines of letters ("Mit freundlichen Grüßen", "Hallo Anna").
        result = result.replacingOccurrences(
            of: #"(?m)^(?!.*\b(?i:grüßen|grüße|gruß|grüsse|regards|hallo|hi|hey|hello|dear|cheers|best|sincerely|thanks|liebe[rs]?|sehr geehrte[rs]?|guten (?:tag|morgen|abend))\b[^\n]*$)([^\n]*[\p{L}\p{N}])(?=\n)"#,
            with: "$1.", options: .regularExpression)
        result = capitalizeSentences(result, capitalizeAfterCommaLine: language == .english)
        if !isSignatureLine(result) {
            result = ensureTerminalPunctuation(result, style: style)
        }
        return result
    }

    /// The last line is a name under a closing ("Best regards,\nAlex"): no period after it.
    static func isSignatureLine(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2, let last = lines.last, let previous = lines.dropLast().last else { return false }
        let closing = previous.range(
            of: #"(?i)\b(?:regards|grüßen|grüße|gruß|cheers|best|thanks|sincerely|herzlich(?:st)?|viele grüße)\b[,!]?\s*$"#,
            options: .regularExpression) != nil
        return closing && last.split(separator: " ").count <= 3
    }

    /// Colloquial short forms and their written standard form, for the formal style.
    /// Only unambiguous forms: "könnt", "ne" or "grad" (3 Grad) are left alone because they can be correct.
    static let shortForms: [(String, String)] = [
        ("hab", "habe"), ("habs", "habe es"), ("hab's", "habe es"), ("is", "ist"), ("isses", "ist es"),
        ("nich", "nicht"), ("nix", "nichts"), ("gibts", "gibt es"), ("gibt's", "gibt es"),
        ("geht's", "geht es"), ("gehts", "geht es"), ("war's", "war es"), ("ham", "haben"), ("nen", "einen"),
        ("'nen", "einen"), ("kannste", "kannst du"), ("haste", "hast du"), ("biste", "bist du"),
        ("willste", "willst du"), ("würd", "würde"), ("wär", "wäre"), ("hätt", "hätte"),
    ]

    static let englishShortForms: [(String, String)] = [
        ("'ve gotta", "'ve got to"), ("gonna", "going to"), ("wanna", "want to"), ("gotta", "have to"),
        ("kinda", "kind of"), ("sorta", "sort of"), ("dunno", "don't know"), ("lemme", "let me"), ("gimme", "give me"),
        ("'cause", "because"), ("cuz", "because"), ("y'all", "you all"),
    ]

    static func expandShortForms(_ text: String, forms: [(String, String)]) -> String {
        var result = text
        for (short, long) in forms {
            // "'ve gotta" follows a letter by design ("I've gotta"); other forms must not.
            let lookbehind = short.hasPrefix("'ve") ? #"(?<![-'])"# : #"(?<![\p{L}'-])"#
            let pattern = lookbehind + NSRegularExpression.escapedPattern(for: short) + #"(?![\p{L}'-])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let original = result[range]
                // All-caps tokens are abbreviations ("IS"), not short forms.
                if original.count > 1, original == original.uppercased() { continue }
                let replacement = original.first?.isUppercase == true ? long.prefix(1).uppercased() + long.dropFirst() : long
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    /// Uppercases the first letter of each sentence. A sentence ends at `.?!` followed by whitespace
    /// (not inside URLs or e-mail addresses, not after abbreviations or ordinals) or at a line break
    /// that does not follow a comma ("Sehr geehrte Frau X,\nvielen Dank").
    static func capitalizeSentences(_ text: String, capitalizeAfterCommaLine: Bool = false) -> String {
        let chars = Array(text)
        var output = ""
        var capitalizeNext = true
        var pendingEnd = false
        var tokenStart = 0
        for (index, char) in chars.enumerated() {
            if char.isWhitespace {
                if pendingEnd { capitalizeNext = true }
                pendingEnd = false
                if char == "\n" {
                    let previous = chars[..<index].last { !$0.isNewline }
                    // German letters continue lowercase after "Sehr geehrte Frau X,"; English capitalizes.
                    capitalizeNext = capitalizeAfterCommaLine || (previous.map { $0 != "," } ?? true)
                }
                output.append(char)
                tokenStart = index + 1
                continue
            }
            if capitalizeNext, char.isLetter {
                // "iPhone", "eBay", "github.com" keep their spelling at a sentence start.
                if isBrandToken(chars[index...].prefix { !$0.isWhitespace }) {
                    output.append(char)
                    capitalizeNext = false
                    pendingEnd = false
                    continue
                }
                output.append(contentsOf: char.uppercased())
                capitalizeNext = false
                pendingEnd = false
                continue
            }
            output.append(char)
            if "?!".contains(char) {
                pendingEnd = true
            } else if char == "." {
                let following = String(chars[(index + 1)..<min(index + 25, chars.count)])
                pendingEnd = !isNonTerminalPeriod(Substring(String(chars[tokenStart...index])), following: Substring(following))
            } else if !"\"'„“»«()".contains(char) {
                pendingEnd = false
                capitalizeNext = false
            }
        }
        return output
    }

    /// A token that starts lowercase on purpose: a capital inside ("iPhone", "eBay", "iOS") or a domain
    /// ("github.com"). Abbreviations like "z.B." do not count.
    static func isBrandToken(_ token: some Sequence<Character>) -> Bool {
        let text = String(token)
        guard text.first?.isLowercase == true else { return false }
        return text.range(of: #"^\p{Ll}\p{L}*\p{Lu}"#, options: .regularExpression) != nil
            || text.range(of: #"^[\p{L}\p{N}-]+\.\p{L}{2,}"#, options: .regularExpression) != nil
    }

    static func ensureTerminalPunctuation(_ text: String, style: Style) -> String {
        var result = text
        guard let last = result.last else { return result }
        let beforeClosers = result.reversed().first { !"“”»)\"'".contains($0) }
        if last.isLetter || last.isNumber {
            result.append(".")
        } else if "“”»)".contains(last), let beforeClosers, beforeClosers.isLetter || beforeClosers.isNumber {
            result.append(".")
        }
        if style == .casual, result.hasSuffix("."), !result.hasSuffix("..") {
            let body = result.dropLast()
            let isSingleSentence = !body.contains("\n") && SentenceSplitter.split(String(body)).count == 1
            if isSingleSentence { result = String(body) }
        }
        return result
    }

    // MARK: - Helpers

    static func normalizeToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    static func tidyAfterRemoval(_ text: String) -> String {
        var result = text
        // ", ," -> ","  and  ", ." -> "."
        result = result.replacingOccurrences(of: #",(\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #",\s*([.?!])"#, with: "$1", options: .regularExpression)
        // Leading comma at the start of text or line.
        result = result.replacingOccurrences(of: #"(?m)^[ \t]*,\s*"#, with: "", options: .regularExpression)
        // Comma directly after sentence end: ". , so" -> ". so". Not after an abbreviation or an
        // ordinal ("usw., das", "am 12., 14. und 15."), where the comma is real.
        guard let regex = try? NSRegularExpression(pattern: #"([^\s,]*[.?!])\s*,"#) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result), let tokenRange = Range(match.range(at: 1), in: result) else { continue }
            let token = result[tokenRange]
            if token.hasSuffix("."), isNonTerminalPeriod(token) { continue }
            result.replaceSubrange(range, with: token)
        }
        return result
    }

    public static func normalizeWhitespace(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        result = tidyAfterRemoval(result)
        return result.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }
}
