import Foundation
import SaywriteCore

/// The actions a key can be bound to.
enum HotkeySlot: CaseIterable, Identifiable {
    case dictate, rewrite, pasteLast
    var id: Self { self }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// What starts a dictation: a modifier on its own, a key combination or a mouse button.
    @Published var dictateKey: Hotkey { didSet { storeHotkey(dictateKey, forKey: "dictateHotkey", legacyKey: "dictateKey") } }
    /// What starts a rewrite of the selection. nil: rewriting by voice is off.
    @Published var rewriteKey: Hotkey? { didSet { storeHotkey(rewriteKey, forKey: "rewriteHotkey", legacyKey: "rewriteKey") } }
    /// Pastes the last dictation again. nil: only through the menu.
    @Published var pasteLastKey: Hotkey? { didSet { storeHotkey(pasteLastKey, forKey: "pasteLastHotkey", legacyKey: nil) } }
    /// Tap or hold, push to talk, or on/off; the same for both trigger keys.
    @Published var triggerMode: TriggerMode { didSet { defaults.set(triggerMode.rawValue, forKey: "triggerMode") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var aiEnabled: Bool { didSet { defaults.set(aiEnabled, forKey: "aiEnabled") } }
    /// Which engine does the AI cleanup: the built-in model (default) or an Ollama server.
    @Published var llmBackend: LLMBackend { didSet { defaults.set(llmBackend.rawValue, forKey: "llmBackend") } }
    @Published var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    /// Empty means: same model as for cleanup.
    @Published var rewriteModel: String { didSet { defaults.set(rewriteModel, forKey: "rewriteModel") } }
    @Published var llmTimeout: Double { didSet { defaults.set(llmTimeout, forKey: "llmTimeout") } }
    /// UID of the microphone, empty for the system default.
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    /// Name of that microphone, to show it in the settings while it is not connected.
    @Published var inputDeviceName: String { didSet { defaults.set(inputDeviceName, forKey: "inputDeviceName") } }
    /// Keep recent dictations in a file on this Mac (for "Paste last" and the History tab).
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Ask GitHub once a day whether a newer release exists. Off: no network request for it at all.
    @Published var checkForUpdates: Bool { didSet { defaults.set(checkForUpdates, forKey: "checkForUpdates") } }
    @Published var replacements: [Replacement] {
        didSet { defaults.set(try? JSONEncoder().encode(replacements), forKey: "replacements") }
    }
    @Published var styleMap: StyleMap {
        didSet { defaults.set(try? JSONEncoder().encode(styleMap), forKey: "styleMap") }
    }

    init() {
        let store0 = UserDefaults.standard
        // Earlier versions stored one of four modifier names under "dictateKey" / "rewriteKey".
        dictateKey = Self.loadHotkey(store0, key: "dictateHotkey")
            ?? Hotkey(legacy: store0.string(forKey: "dictateKey") ?? "") ?? .defaultDictate
        if store0.object(forKey: "rewriteHotkey") != nil {
            rewriteKey = Self.loadHotkey(store0, key: "rewriteHotkey")
        } else {
            rewriteKey = Hotkey(legacy: store0.string(forKey: "rewriteKey") ?? "") ?? .defaultRewrite
        }
        pasteLastKey = Self.loadHotkey(store0, key: "pasteLastHotkey")
        triggerMode = TriggerMode(rawValue: store0.string(forKey: "triggerMode") ?? "") ?? .tapOrHold
        language = defaults.string(forKey: "language") ?? "auto"
        aiEnabled = defaults.object(forKey: "aiEnabled") as? Bool ?? true
        let storedBackend = defaults.string(forKey: "llmBackend")
        let earlierKeys = ["dictateKey", "rewriteKey", "language", "aiEnabled", "ollamaURL", "ollamaModel", "rewriteModel",
                           "llmTimeout", "inputDeviceUID", "playSounds", "replacements", "styleMap"]
        let store = defaults
        let usedEarlierVersion = earlierKeys.contains { store.object(forKey: $0) != nil }
            || FileManager.default.fileExists(atPath: HistoryStore.defaultFileURL().path)
        let backend = LLMBackend.resolveAtLaunch(
            stored: storedBackend, modelInstalled: ModelStore().isInstalled(.qwen25_3b), usedEarlierVersion: usedEarlierVersion)
        // Remember the decision, so downloading the model later does not switch the engine behind the user's back.
        if LLMBackend(rawValue: storedBackend ?? "") == nil { store.set(backend.rawValue, forKey: "llmBackend") }
        llmBackend = backend
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen2.5:3b"
        rewriteModel = defaults.string(forKey: "rewriteModel") ?? ""
        let timeout = defaults.double(forKey: "llmTimeout")
        llmTimeout = timeout > 0 ? timeout : 4
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        inputDeviceName = defaults.string(forKey: "inputDeviceName") ?? ""
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        checkForUpdates = defaults.object(forKey: "checkForUpdates") as? Bool ?? true
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

    /// Stored as JSON; "off" is stored as JSON null, so it is not mistaken for "never set".
    private func storeHotkey(_ hotkey: Hotkey?, forKey key: String, legacyKey: String?) {
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: key)
        // An earlier version, if the user goes back to it, keeps the key when it knows it.
        if let legacyKey, let name = hotkey?.legacyName { defaults.set(name, forKey: legacyKey) }
    }

    private static func loadHotkey(_ store: UserDefaults, key: String) -> Hotkey? {
        guard let data = store.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode(Hotkey?.self, from: data)) ?? nil
    }

    /// The bindings of the other actions, to refuse a key that is already taken.
    func hotkeysOtherThan(_ slot: HotkeySlot) -> [Hotkey?] {
        HotkeySlot.allCases.filter { $0 != slot }.map { hotkey(for: $0) }
    }

    func hotkey(for slot: HotkeySlot) -> Hotkey? {
        switch slot {
        case .dictate: return dictateKey
        case .rewrite: return rewriteKey
        case .pasteLast: return pasteLastKey
        }
    }

    func setHotkey(_ hotkey: Hotkey?, for slot: HotkeySlot) {
        switch slot {
        case .dictate: if let hotkey { dictateKey = hotkey }
        case .rewrite: rewriteKey = hotkey
        case .pasteLast: pasteLastKey = hotkey
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
