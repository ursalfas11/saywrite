import Foundation
import SaywriteCore

/// Keys that can be held alone as a dictation trigger.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case rightControl
    case fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return L("Right ⌥ Option", "Rechte ⌥ Option")
        case .rightCommand: return L("Right ⌘ Command", "Rechte ⌘ Command")
        case .rightControl: return L("Right ⌃ Control", "Rechte ⌃ Control")
        case .fn: return "fn / 🌐"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var dictateKey: TriggerKey { didSet { defaults.set(dictateKey.rawValue, forKey: "dictateKey") } }
    @Published var rewriteKey: TriggerKey { didSet { defaults.set(rewriteKey.rawValue, forKey: "rewriteKey") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    /// Empty means: same model as for cleanup.
    @Published var rewriteModel: String { didSet { defaults.set(rewriteModel, forKey: "rewriteModel") } }
    @Published var llmTimeout: Double { didSet { defaults.set(llmTimeout, forKey: "llmTimeout") } }
    /// UID of the microphone, empty for the system default.
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    /// Keep recent dictations in a file on this Mac (for "Paste last" and the History tab).
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var replacements: [Replacement] {
        didSet { defaults.set(try? JSONEncoder().encode(replacements), forKey: "replacements") }
    }
    @Published var styleMap: StyleMap {
        didSet { defaults.set(try? JSONEncoder().encode(styleMap), forKey: "styleMap") }
    }

    init() {
        dictateKey = TriggerKey(rawValue: defaults.string(forKey: "dictateKey") ?? "") ?? .rightOption
        rewriteKey = TriggerKey(rawValue: defaults.string(forKey: "rewriteKey") ?? "") ?? .rightCommand
        language = defaults.string(forKey: "language") ?? "auto"
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen2.5:3b"
        rewriteModel = defaults.string(forKey: "rewriteModel") ?? ""
        let timeout = defaults.double(forKey: "llmTimeout")
        llmTimeout = timeout > 0 ? timeout : 4
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        if let data = defaults.data(forKey: "replacements"), let list = try? JSONDecoder().decode([Replacement].self, from: data) {
            replacements = list
        } else {
            replacements = []
        }
        if let data = defaults.data(forKey: "styleMap"), let map = try? JSONDecoder().decode(StyleMap.self, from: data) {
            styleMap = map
        } else {
            styleMap = StyleMap()
        }
    }

    /// False when the typed address cannot be used and requests go to the local default instead.
    var ollamaURLValid: Bool { OllamaEndpoint.parse(ollamaURL) != nil }

    var ollamaConfiguration: OllamaClient.Configuration {
        OllamaClient.Configuration(
            baseURL: OllamaEndpoint.parse(ollamaURL) ?? URL(string: "http://localhost:11434")!,
            model: ollamaModel,
            rewriteModel: rewriteModel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : rewriteModel,
            cleanupTimeout: llmTimeout
        )
    }
}
