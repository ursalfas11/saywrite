import Foundation

/// Speech recognition: 16 kHz mono float samples in, text out.
public protocol Transcriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

/// A piece of the recording. `continuesPrevious` is true when it was cut off mid-speech (no pause),
/// so the recognizer's sentence end at the cut is not real.
public struct AudioSegment: Sendable {
    public var samples: [Float]
    public var continuesPrevious: Bool

    public init(samples: [Float], continuesPrevious: Bool = false) {
        self.samples = samples
        self.continuesPrevious = continuesPrevious
    }
}

public struct DictationResult: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var raw: String
    public var final: String
    public var style: Style
    public var appBundleID: String?
    public var summary: ChangeSummary
    /// Seconds from `finish()` being called until the final text was ready.
    public var latency: TimeInterval
    /// The same dictation with rules only (no AI), offered as "Original" when the AI changed words.
    public var withoutAI: String?

    public init(id: UUID = UUID(), date: Date = Date(), raw: String, final: String, style: Style, appBundleID: String?, summary: ChangeSummary, latency: TimeInterval, withoutAI: String? = nil) {
        self.id = id
        self.date = date
        self.raw = raw
        self.final = final
        self.style = style
        self.appBundleID = appBundleID
        self.summary = summary
        self.latency = latency
        self.withoutAI = withoutAI
    }
}

struct SegmentResult: Sendable {
    var raw: String
    /// Cleaned sentences of this segment.
    var units: [String]
    /// The rule-cleaned text before any AI.
    var ruled: String = ""
    var continuesPrevious = false
    var language: DictationLanguage = .german
    /// Corrections whose LLM call already failed; not retried in `finish()`.
    var attemptedCorrections: Set<String> = []
    var usedLLM: Bool
    var llmFailed: Bool

    var cleaned: String { DictationSession.join(units) }
}

/// One dictation. Segments are processed while the user is still speaking; results are joined in
/// capture order when the dictation ends. LLM calls run strictly one after another because each
/// segment waits for its predecessor.
public actor DictationSession {
    private let transcriber: Transcriber
    private let llm: LLMClient?
    public let style: Style
    public let appBundleID: String?
    private var tasks: [Task<SegmentResult, Never>] = []
    private var completed: [Int: SegmentResult] = [:]
    /// "de", "en" or "auto" (detected per segment from the recognized words).
    private let languageSetting: String
    private let replacements: [Replacement]
    private let breaker = LLMCircuitBreaker()

    /// `llm == nil` means AI cleanup is switched off (not an error).
    public init(
        transcriber: Transcriber, llm: LLMClient?, style: Style, appBundleID: String?,
        language: String = "auto", replacements: [Replacement] = []
    ) {
        self.transcriber = transcriber
        self.llm = llm
        self.style = style
        self.appBundleID = appBundleID
        self.languageSetting = language
        self.replacements = replacements
    }

    /// Queue a finished audio segment for background processing.
    public func addSegment(_ samples: [Float]) {
        addSegment(AudioSegment(samples: samples))
    }

    public func addSegment(_ segment: AudioSegment) {
        let samples = segment.samples
        let continuesPrevious = segment.continuesPrevious
        let previous = tasks.last
        let transcriber = self.transcriber
        let llm = self.llm
        let style = self.style
        let languageSetting = self.languageSetting
        let breaker = self.breaker
        let index = tasks.count
        let task = Task<SegmentResult, Never> { [weak self] in
            let raw: String
            do {
                raw = try await transcriber.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                raw = ""
            }
            // Wait for the previous segment so LLM calls run one after another.
            _ = await previous?.value
            let language = DictationLanguage.resolve(setting: languageSetting, text: raw)
            var result = await Self.process(raw: raw, style: style, llm: llm, language: language, breaker: breaker)
            result.language = language
            result.continuesPrevious = continuesPrevious
            await self?.record(result, at: index)
            return result
        }
        tasks.append(task)
    }

    private func record(_ result: SegmentResult, at index: Int) {
        completed[index] = result
    }

    /// Text of the segments finished so far, in order, for the live preview.
    public func previewText() -> String {
        var parts: [String] = []
        for index in 0..<tasks.count {
            guard let result = completed[index] else { break }
            parts.append(result.cleaned)
        }
        return Self.join(parts)
    }

    /// Whether a queued segment is still being transcribed or cleaned.
    public var hasPendingSegments: Bool { completed.count < tasks.count }

    static func process(
        raw: String, style: Style, llm: LLMClient?, language: DictationLanguage = .german,
        breaker: LLMCircuitBreaker = LLMCircuitBreaker()
    ) async -> SegmentResult {
        guard !raw.isEmpty else { return SegmentResult(raw: "", units: [], usedLLM: false, llmFailed: false) }
        let ruled = RuleCleaner.clean(raw, language: language)
        guard !ruled.isEmpty else { return SegmentResult(raw: raw, units: [], usedLLM: false, llmFailed: false) }

        // Only the sentences that need it go to the model: short requests are fast, and clean
        // sentences stay exactly as spoken.
        let units = SentenceSplitter.split(ruled)
        var output: [String] = []
        var usedLLM = false
        var llmFailed = false
        var attemptedCorrections: Set<String> = []
        for unit in units {
            // "… Aber nee, vergiss das, ich meine …" corrects the sentence before it. That needs the
            // previous sentence as input; a correction at the very start of a segment is handled
            // in `finish()`, where the previous segment is known.
            if CleanupGate.startsWithCorrection(unit, language: language) {
                guard let llm, let previous = output.popLast() else {
                    output.append(unit)
                    continue
                }
                let combined = Self.joinForCorrection(previous, unit)
                do {
                    guard !breaker.isOpen else { throw LLMError.unreachable }
                    let improved = try await llm.cleanup(text: combined, style: style, language: language)
                    Debug.log("llm (with previous sentence): \(combined) -> \(improved)")
                    // Returning only the discarded sentence means the model misunderstood.
                    guard !LLMOutputGuard.sameWords(improved, previous),
                          !LLMOutputGuard.removedOnlyMarkers(input: combined, output: improved),
                          Self.keepsCorrectedNumbers(combined, improved, language)
                    else { throw LLMError.rejectedOutput }
                    output.append(RuleCleaner.clean(improved, language: language))
                    usedLLM = true
                } catch {
                    Debug.log("llm failed: \(error)")
                    breaker.record(error)
                    llmFailed = true
                    output.append(contentsOf: [previous, unit])
                    attemptedCorrections.insert(unit)
                }
                continue
            }
            let decision = CleanupGate.decide(raw: unit, style: style, language: language)
            guard decision.usesLLM else {
                output.append(unit)
                continue
            }
            let isCorrection = decision == .llm(reason: "Selbstkorrektur")
            guard let llm else {
                output.append(unit)
                continue
            }
            do {
                guard !breaker.isOpen else { throw LLMError.unreachable }
                let improved = try await llm.cleanup(text: unit, style: style, language: language)
                Debug.log("llm: \(unit) -> \(improved)")
                // Without a correction the model may only add punctuation; changed words fall back.
                guard isCorrection || LLMOutputGuard.sameWords(unit, improved) else { throw LLMError.rejectedOutput }
                guard !LLMOutputGuard.removedOnlyMarkers(input: unit, output: improved) else { throw LLMError.rejectedOutput }
                // The corrected numbers must be in the result, otherwise the model kept the wrong version.
                guard Self.keepsCorrectedNumbers(unit, improved, language) else { throw LLMError.rejectedOutput }
                output.append(RuleCleaner.clean(improved, language: language))
                usedLLM = true
            } catch {
                Debug.log("llm failed: \(error)")
                breaker.record(error)
                llmFailed = true
                output.append(unit)
            }
        }
        var result = SegmentResult(raw: raw, units: output, ruled: ruled, usedLLM: usedLLM, llmFailed: llmFailed)
        result.attemptedCorrections = attemptedCorrections
        return result
    }

    /// Wait for all segments and build the final text. Returns nil when nothing was said.
    public func finish() async -> DictationResult? {
        let start = Date()
        var results: [SegmentResult] = []
        for task in tasks { results.append(await task.value) }
        let spoken = results.filter { !$0.raw.isEmpty }
        guard !spoken.isEmpty else { return nil }

        var usedLLM = spoken.contains { $0.usedLLM }
        var llmFailed = spoken.contains { $0.llmFailed }
        let language = DictationLanguage.resolve(setting: languageSetting, text: spoken.map(\.raw).joined(separator: " "))
        var units: [String] = []
        for segment in spoken {
            var segmentUnits = segment.units
            if segment.continuesPrevious, !units.isEmpty, let first = segmentUnits.first, CleanupGate.startsWithCorrection(first, language: language) {
                // "am Donnerstag, | nein, am Freitag": keep apart so the correction pass below sees it.
                units[units.count - 1] = Self.dropFalsePeriod(units[units.count - 1])
            } else if segment.continuesPrevious, !units.isEmpty, !segmentUnits.isEmpty {
                // Cut mid-sentence: glue the halves back together.
                units[units.count - 1] = Self.dropFalsePeriod(units[units.count - 1])
                segmentUnits[0] = Self.lowercaseContinuation(segmentUnits[0])
                units[units.count - 1] += " " + segmentUnits.removeFirst()
            }
            units.append(contentsOf: segmentUnits)
        }

        // "Ich komme um fünf. … Nein, um sechs." – after a pause the correction lands in its own
        // sentence, so it is merged with the sentence it corrects.
        let alreadyTried = spoken.reduce(into: Set<String>()) { $0.formUnion($1.attemptedCorrections) }
        var index = 1
        while index < units.count {
            // A model that already failed (timeout) is not asked again: that would double the wait.
            guard CleanupGate.startsWithCorrection(units[index], language: language), let llm,
                  !alreadyTried.contains(units[index]) else {
                index += 1
                continue
            }
            let combined = Self.joinForCorrection(units[index - 1], units[index])
            do {
                guard !breaker.isOpen else { throw LLMError.unreachable }
                let improved = try await llm.cleanup(text: combined, style: style, language: language)
                Debug.log("llm (across pause): \(combined) -> \(improved)")
                guard !LLMOutputGuard.sameWords(improved, units[index - 1]),
                      !LLMOutputGuard.removedOnlyMarkers(input: combined, output: improved),
                      Self.keepsCorrectedNumbers(combined, improved, language)
                else { throw LLMError.rejectedOutput }
                units[index - 1] = RuleCleaner.clean(improved, language: language)
                units.remove(at: index)
                usedLLM = true
            } catch {
                Debug.log("llm failed: \(error)")
                breaker.record(error)
                llmFailed = true
                index += 1
            }
        }

        let raw = Self.join(spoken.map(\.raw))
        let plain = RuleCleaner.finalize(Self.join(units), style: style, language: language)
        guard !plain.isEmpty else { return nil }
        let (final, replacementCount) = ReplacementEngine.apply(replacements, to: plain)

        let summary = ChangeSummarizer.summarize(
            raw: raw, final: plain, usedLLM: usedLLM, llmFailed: llmFailed, replacements: replacementCount,
            language: language)
        var withoutAI: String?
        if usedLLM {
            let rulesOnly = RuleCleaner.finalize(Self.join(spoken.map(\.ruled)), style: style, language: language)
            let rulesFinal = ReplacementEngine.apply(replacements, to: rulesOnly).text
            if rulesFinal != final { withoutAI = rulesFinal }
        }
        return DictationResult(
            raw: raw, final: final, style: style, appBundleID: appBundleID,
            summary: summary, latency: Date().timeIntervalSince(start), withoutAI: withoutAI)
    }

    public func cancel() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        completed.removeAll()
    }

    static func keepsCorrectedNumbers(_ input: String, _ output: String, _ language: DictationLanguage) -> Bool {
        let outputNumbers = Set(output.split(whereSeparator: { !$0.isNumber }).map(String.init))
        return CleanupGate.correctedNumbers(in: input, language: language).allSatisfy(outputNumbers.contains)
    }

    /// "Ich komme um fünf." + "Nein, um sechs." or "am Donnerstag" + "nein, am Freitag".
    static func joinForCorrection(_ previous: String, _ correction: String) -> String {
        guard let last = previous.last else { return correction }
        return ".?!,;:".contains(last) ? previous + " " + correction : previous + ", " + correction
    }

    static func dropFalsePeriod(_ text: String) -> String {
        text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) : text
    }

    /// Words that are only capitalized because the recognizer thought a sentence started there.
    static let continuationWords: Set<String> = [
        "und", "oder", "aber", "dass", "weil", "wenn", "als", "ob", "denn", "sondern", "dann", "also", "noch", "auch",
        "nicht", "nur", "schon", "die", "der", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer",
        "ich", "du", "er", "es", "wir", "ihr", "mit", "von", "vom", "zu", "zum", "zur", "in", "im", "an", "am", "auf",
        "für", "bei", "nach", "aus", "über", "unter", "vor", "bis", "ist", "sind", "war", "hat", "habe", "haben",
        "wird", "werden", "kann", "muss", "soll", "will", "mir", "mich", "dir", "dich", "uns", "euch", "ihm", "ihn",
        "sich", "so", "wie", "was", "wo", "da", "hier", "jetzt", "heute", "morgen", "gestern", "sehr", "mal",
        // English
        "and", "or", "but", "that", "the", "a", "an", "to", "of", "on", "at", "for", "with", "is", "are", "was",
        "it", "we", "you", "they", "my", "your", "our", "this", "if", "because", "so", "then", "also", "not",
    ]

    static func lowercaseContinuation(_ text: String) -> String {
        guard let first = text.split(separator: " ").first else { return text }
        let word = first.trimmingCharacters(in: .punctuationCharacters)
        guard continuationWords.contains(word.lowercased()), word.first?.isUppercase == true else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Join segment texts with a space, but not around explicit line breaks.
    static func join(_ parts: [String]) -> String {
        var output = ""
        for part in parts where !part.isEmpty {
            if output.isEmpty || output.hasSuffix("\n") || part.hasPrefix("\n") {
                output += part
            } else {
                output += " " + part
            }
        }
        return output
    }
}
