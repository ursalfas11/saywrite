// Quality evaluation of the text pipeline with the real local LLM.
// Usage: swift run -c release SaywriteEval [Tests/Eval/cases.json] [--no-ai] [--verbose]
// Each case is one dictation (one or more recognizer segments; a leading "+" marks a segment that
// continues the previous one without a pause) and the expected final text ("||" separates variants).
import Foundation
import SaywriteCore

struct EvalCase: Codable {
    var id: String
    var style: String
    var segs: [String]
    var expected: String
}

final class ScriptedTranscriber: Transcriber, @unchecked Sendable {
    let texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func transcribe(_ samples: [Float]) async throws -> String { texts[Int(samples[0])] }
}

final class TimedLLM: LLMClient, @unchecked Sendable {
    let inner = OllamaClient(configuration: .init())
    private let lock = NSLock()
    private(set) var latencies: [Double] = []
    private(set) var calls: [String] = []

    func prewarm(forRewrite: Bool) async { await inner.prewarm(forRewrite: forRewrite) }
    func rewrite(selection: String, instruction: String) async throws -> String { selection }
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String {
        let start = Date()
        do {
            let out = try await inner.cleanup(text: text, style: style, language: language)
            record(Date().timeIntervalSince(start), "LLM \(text) -> \(out)")
            return out
        } catch {
            record(Date().timeIntervalSince(start), "LLM \(text) -> ERROR \(error)")
            throw error
        }
    }
    func reset() { lock.lock(); calls = []; lock.unlock() }
    private func record(_ latency: Double, _ line: String) {
        lock.lock(); latencies.append(latency); calls.append(line); lock.unlock()
    }
}

let args = CommandLine.arguments.dropFirst()
let path = args.first { !$0.hasPrefix("--") } ?? "Tests/Eval/cases.json"
let useAI = !args.contains("--no-ai")
let verbose = args.contains("--verbose")
let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let llm = TimedLLM()
if useAI { await llm.prewarm(forRewrite: false) }

var passed = 0
var failures: [String] = []
for c in cases {
    llm.reset()
    let texts = c.segs.map { $0.hasPrefix("+") ? String($0.dropFirst()) : $0 }
    let session = DictationSession(
        transcriber: ScriptedTranscriber(texts), llm: useAI ? llm : nil,
        style: Style(rawValue: c.style) ?? .neutral, appBundleID: nil)
    for (index, segment) in c.segs.enumerated() {
        await session.addSegment(AudioSegment(samples: [Float(index)], continuesPrevious: segment.hasPrefix("+")))
    }
    let final = await session.finish()?.final ?? "<nichts>"
    let ok = c.expected.components(separatedBy: "||").contains(final)
    if ok { passed += 1 } else {
        var report = "FAIL [\(c.id)] (\(c.style))\n  in:  \(c.segs.joined(separator: " | "))\n  got: \(final)\n  exp: \(c.expected)"
        if verbose { report += "\n    " + llm.calls.joined(separator: "\n    ") }
        failures.append(report.replacingOccurrences(of: "\n\n", with: "⏎⏎"))
    }
}
failures.forEach { print($0) }
let sorted = llm.latencies.sorted()
print("PASS \(passed)/\(cases.count) (\(Int(Double(passed) / Double(cases.count) * 100)) %)  LLM calls: \(sorted.count)")
if !sorted.isEmpty {
    print(String(format: "LLM latency median %.2fs  p90 %.2fs  max %.2fs",
                 sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last!))
}
