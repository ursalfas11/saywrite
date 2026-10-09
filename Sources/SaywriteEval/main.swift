// Quality evaluation of the text pipeline with the real local LLM.
// Usage: swift run -c release SaywriteEval [Tests/Eval/cases.json] [--no-ai] [--verbose]
//        [--backend llama|ollama] [--model qwen2.5:3b] [--model-path file.gguf] [--report Tests/Eval/results.jsonl]
// --backend defaults to llama (the built-in model) when its file is in ~/Library/Application Support/Saywrite/Models,
// otherwise ollama. --model names the Ollama model, --model-path the GGUF file of the built-in one.
// --report appends one JSON line per run (date, set, model, result), so the quality claims in the
// README have a history instead of a single number.
// Each case is one dictation (one or more recognizer segments; a leading "+" marks a segment that
// continues the previous one without a pause) and the expected final text ("||" separates variants).
import Foundation
import SaywriteCore
import SaywriteLlama

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
    let inner: LLMClient
    init(inner: LLMClient) { self.inner = inner }
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
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), args.index(after: index) < args.endIndex else { return nil }
    return args[args.index(after: index)]
}
let reportPath = option("--report")
let modelStore = ModelStore()
let modelPath = option("--model-path") ?? modelStore.fileURL(.qwen25_3b).path
let backend: LLMBackend
switch option("--backend") {
case "llama", "builtin": backend = .builtin
case "ollama": backend = .ollama
case nil: backend = LLMBackend.evalDefault(modelInstalled: FileManager.default.fileExists(atPath: modelPath))
case let other?:
    print("unknown --backend \(other) (llama or ollama)")
    exit(2)
}
let ollamaModel = option("--model") ?? OllamaClient.Configuration().model
let model = backend == .builtin ? (modelPath as NSString).lastPathComponent : ollamaModel
let optionValues = Set([option("--model"), option("--model-path"), option("--backend"), reportPath].compactMap { $0 })
let path = args.first { !$0.hasPrefix("--") && !optionValues.contains($0) } ?? "Tests/Eval/cases.json"
let useAI = !args.contains("--no-ai")
let verbose = args.contains("--verbose")
let cases = try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let llm = TimedLLM(inner: backend == .builtin
    ? LlamaClient(modelURL: URL(fileURLWithPath: modelPath))
    : OllamaClient(configuration: .init(model: ollamaModel)))
if useAI { print("backend: \(backend.rawValue) (\(model))") }
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

LlamaEngine.shared.shutdown()

if let reportPath {
    let entry: [String: Any] = [
        "date": ISO8601DateFormatter().string(from: Date()),
        "set": (path as NSString).lastPathComponent,
        "model": useAI ? model : "none",
        "backend": useAI ? backend.rawValue : "none",
        "passed": passed,
        "total": cases.count,
        "llmCalls": sorted.count,
    ]
    var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    line.append(0x0A)
    let url = URL(fileURLWithPath: reportPath)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line)
        try handle.close()
    } else {
        try line.write(to: url)
    }
    print("Report appended to \(reportPath)")
}
