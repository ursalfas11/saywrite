import FluidAudio
import Foundation
import SaywriteCore
import SaywriteLlama
import SwiftUI
import AppKit

/// `Saywrite --selftest <audio> [style]`: runs an audio file through the real pipeline as if it
/// were dictated live (chunked, with VAD segmentation) and prints text and latency. Used by
/// `scripts/bench.sh`.
enum SelfTest {
    static func run(arguments: [String]) async -> Int32 {
        guard arguments.count >= 1 else {
            print("usage: Saywrite --selftest <audio file> [casual|neutral|formal] [--no-ai] [--backend llama|ollama]")
            return 2
        }
        let url = URL(fileURLWithPath: arguments[0])
        let style = arguments.dropFirst().compactMap { Style(rawValue: $0) }.first ?? .neutral
        let useAI = !arguments.contains("--no-ai")
        let store = ModelStore()
        let modelURL = store.fileURL(.qwen25_3b)
        let backend: LLMBackend
        if let index = arguments.firstIndex(of: "--backend"), index + 1 < arguments.count {
            backend = arguments[index + 1] == "ollama" ? .ollama : .builtin
        } else {
            backend = LLMBackend.evalDefault(modelInstalled: store.isInstalled(.qwen25_3b))
        }

        do {
            let loadStart = Date()
            let transcriber = ParakeetTranscriber()
            await transcriber.setLanguage("auto")
            try await transcriber.load { _ in }
            let vad = try? await VadManager(config: VadConfig(defaultThreshold: 0.6))
            print(String(format: "models loaded in %.2fs (vad: %@)", Date().timeIntervalSince(loadStart), vad == nil ? "off" : "on"))

            let samples = try AudioConverter().resampleAudioFile(url)
            let llm: LLMClient?
            switch (useAI, backend) {
            case (false, _): llm = nil
            case (true, .builtin): llm = LlamaClient(modelURL: modelURL)
            case (true, .ollama): llm = OllamaClient(configuration: .init())
            }
            if useAI { print("AI backend: \(backend.rawValue)") }
            if let llm { await llm.prewarm(forRewrite: false) }

            let session = DictationSession(transcriber: transcriber, llm: llm, style: style, appBundleID: nil)
            let segmenter = Segmenter(vad: vad)
            await segmenter.reset()

            // Feed audio in real time so segment processing overlaps with "speaking", like live use.
            let chunk = 2048
            var index = 0
            var segmentCount = 0
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                for segment in await segmenter.append(Array(samples[index..<end])) {
                    segmentCount += 1
                    await session.addSegment(segment)
                }
                index = end
                try await Task.sleep(nanoseconds: UInt64(Double(chunk) / 16_000 * 1_000_000_000))
            }
            let release = Date()
            if let rest = await segmenter.flush() {
                segmentCount += 1
                await session.addSegment(rest)
            }
            guard let result = await session.finish() else {
                print("no speech detected")
                return 1
            }
            let latency = Date().timeIntervalSince(release)
            print("segments: \(segmentCount)")
            print("raw:      \(result.raw)")
            print("final:    \(result.final)")
            print("summary:  \(result.summary.text)")
            print(String(format: "latency after release: %.2fs (audio %.1fs, style %@)", latency, Double(samples.count) / 16_000, style.rawValue))
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}

/// `Saywrite --render-overlay <dir>`: renders the overlay states to PNG files (for docs and review).
enum OverlaySnapshot {
    @MainActor
    static func run(directory: String) -> Int32 {
        UILanguage.override = false // screenshots are in English
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let states: [(String, OverlayState, String, String)] = [
            ("recording", .recording(handsFree: true, rewrite: false), "", ""),
            ("rewrite", .recording(handsFree: true, rewrite: true), "", ""),
            ("processing", .processing, "I'd like to buy a new bike. Ideally one with lights.", ""),
            ("done", .done(ChangeSummary(punctuationChanged: 1, wordsChanged: 5, usedLLM: true).text, undo: true), "I'd like to buy a new bike.", ""),
            ("error", .error("No microphone access"), "", ""),
        ]
        for (name, state, committed, partial) in states {
            let model = OverlayModel()
            model.state = state
            model.committedText = committed
            model.partialText = partial
            model.levels = (0..<OverlayModel.dotCount).map { i in Float(abs(sin(Double(i) * 0.7))) * 0.8 }
            // The pill is one 34 pt row; room around it for its shadow, centered like on screen.
            let view = OverlayView(model: model, onStop: {}, onErrorTap: {})
                .frame(width: 360, height: 34)
                .padding(.vertical, 18)
                .background(LinearGradient(
                    colors: [Color(red: 0.36, green: 0.22, blue: 0.55), Color(red: 0.12, green: 0.14, blue: 0.30)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("overlay-\(name).png"))
        }
        return 0
    }
}
