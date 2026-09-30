import AppKit
import ServiceManagement
import SwiftUI
import SaywriteCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController

    var body: some View {
        TabView {
            SetupTab(settings: settings, state: state, controller: controller)
                .tabItem { Label(L("Setup", "Einrichtung"), systemImage: "checklist") }
            GeneralTab(settings: settings, state: state, controller: controller)
                .tabItem { Label(L("General", "Allgemein"), systemImage: "gearshape") }
            StylesTab(settings: settings)
                .tabItem { Label(L("Styles", "Stile"), systemImage: "textformat") }
            DictionaryTab(settings: settings)
                .tabItem { Label(L("Dictionary", "Wörterbuch"), systemImage: "character.book.closed") }
            HistoryTab(state: state, controller: controller)
                .tabItem { Label(L("History", "Verlauf"), systemImage: "clock") }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}

// MARK: - Setup

private struct SetupTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController

    var body: some View {
        Form {
            Section {
                StatusRow(
                    ok: state.microphoneGranted, title: L("Microphone", "Mikrofon"),
                    detail: state.microphoneGranted ? L("Allowed", "Erlaubt") : L("Needed to record", "Wird zum Aufnehmen gebraucht"),
                    actionTitle: L("Allow", "Erlauben")
                ) {
                    Task {
                        if Permissions.microphoneStatus == .undetermined {
                            state.microphoneGranted = await Permissions.requestMicrophone()
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                }
                StatusRow(
                    ok: state.accessibilityGranted, title: L("Accessibility", "Bedienungshilfen"),
                    detail: state.accessibilityGranted ? L("Allowed", "Erlaubt") : L("Needed for the hotkey and pasting", "Für Tastenkürzel und Einfügen"),
                    actionTitle: L("Allow", "Erlauben")
                ) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                StatusRow(ok: state.modelState == .ready, title: L("Speech recognition (Parakeet)", "Spracherkennung (Parakeet)"), detail: modelDetail,
                          actionTitle: modelFailed ? L("Try again", "Erneut versuchen") : nil) {
                    controller.retryModelLoad()
                }
                StatusRow(ok: state.ollamaState == .ready, title: L("AI (Ollama)", "KI (Ollama)"), detail: ollamaDetail,
                          actionTitle: L("Check", "Prüfen"), alwaysShowAction: true) {
                    Task { await controller.refreshOllamaStatus() }
                }
            } header: {
                Text("Status")
            } footer: {
                if state.ollamaState == .unreachable || state.ollamaState == .modelMissing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Saywrite works without Ollama too – just without AI cleanup.", "Ohne Ollama funktioniert Saywrite trotzdem – nur ohne KI-Aufräumen."))
                        Text("brew install ollama && brew services start ollama\nollama pull \(settings.ollamaModel)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Section(L("How it works", "So geht's")) {
                Text(LM("Tap **\(settings.dictateKey.displayName)**, speak, tap again – the text is inserted.",
                        "**\(settings.dictateKey.displayName)** einmal tippen, sprechen, nochmal tippen = Text wird eingefügt."))
                Text(LM("Or hold it and release when you are done. **Esc** cancels.",
                        "Oder gedrückt halten und loslassen, wenn du fertig bist. **Esc** bricht ab."))
                Text(LM("Select text, tap **\(settings.rewriteKey.displayName)**, say what should change, tap again.",
                        "Text markieren, **\(settings.rewriteKey.displayName)** tippen, sagen, was sich ändern soll, nochmal tippen."))
            }
        }
        .formStyle(.grouped)
    }

    private var modelFailed: Bool {
        if case .failed = state.modelState { return true }
        return false
    }

    private var modelDetail: String {
        switch state.modelState {
        case .loading(let p): return p > 0 && p < 1 ? L("Downloading… \(Int(p * 100))%", "Wird geladen … \(Int(p * 100)) %") : L("Loading…", "Wird geladen …")
        case .ready: return L("Ready", "Bereit")
        case .failed(let message): return L("Error: \(message)", "Fehler: \(message)")
        }
    }

    private var ollamaDetail: String {
        switch state.ollamaState {
        case .unknown: return L("Checking…", "Wird geprüft …")
        case .unreachable: return L("Not reachable", "Nicht erreichbar")
        case .modelMissing: return L("Model \(settings.ollamaModel) is missing", "Modell \(settings.ollamaModel) fehlt")
        case .ready: return L("Ready (\(settings.ollamaModel))", "Bereit (\(settings.ollamaModel))")
        }
    }
}

private struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var actionTitle: String?
    var alwaysShowAction = false
    var action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, !ok || alwaysShowAction {
                Button(actionTitle, action: action)
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var microphones = AudioDevices.inputs()

    private let languages: [(String, String)] = [
        ("auto", L("Automatic (German / English)", "Automatisch (Deutsch / Englisch)")),
        ("en", L("English", "Englisch")), ("de", L("German", "Deutsch")), ("fr", L("French", "Französisch")),
        ("es", L("Spanish", "Spanisch")), ("it", L("Italian", "Italienisch")), ("nl", L("Dutch", "Niederländisch")),
        ("pl", L("Polish", "Polnisch")), ("pt", L("Portuguese", "Portugiesisch")),
    ]

    var body: some View {
        Form {
            Section(L("Keys", "Tasten")) {
                Picker(L("Dictate", "Diktieren"), selection: $settings.dictateKey) {
                    ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(L("Rewrite selection", "Umformulieren"), selection: $settings.rewriteKey) {
                    ForEach(TriggerKey.allCases.filter { $0 != settings.dictateKey }) { Text($0.displayName).tag($0) }
                }
                Text(L("Tap to start, tap again to finish. Holding and releasing works too.", "Einmal tippen startet, nochmal tippen beendet. Halten und Loslassen geht auch."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Recording", "Aufnahme")) {
                Picker(L("Microphone", "Mikrofon"), selection: $settings.inputDeviceUID) {
                    Text(L("System default", "Systemstandard")).tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                }
                Toggle(L("Short sound on start and stop", "Kurzer Ton bei Start und Stopp"), isOn: $settings.playSounds)
            }
            Section(L("Language & AI", "Sprache & KI")) {
                Picker(L("Language", "Sprache"), selection: $settings.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L("AI cleanup (only when needed)", "KI-Aufräumen (nur wenn nötig)"), isOn: $settings.aiEnabled)
                ModelField(title: L("Model (cleanup)", "Modell (Aufräumen)"), value: $settings.ollamaModel, models: state.installedModels)
                ModelField(title: L("Model (rewrite)", "Modell (Umformulieren)"), value: $settings.rewriteModel, models: state.installedModels, allowSame: true)
                TextField(L("Ollama address", "Ollama-Adresse"), text: $settings.ollamaURL)
                Stepper(L("AI time limit: \(Int(settings.llmTimeout)) s", "KI-Zeitlimit: \(Int(settings.llmTimeout)) s"), value: $settings.llmTimeout, in: 3...30)
            }
            Section {
                Toggle(L("Launch at login", "Beim Anmelden starten"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.dictateKey) { _, key in
            if settings.rewriteKey == key {
                settings.rewriteKey = TriggerKey.allCases.first { $0 != key } ?? .rightCommand
            }
            controller.applySettings()
        }
        .onChange(of: settings.ollamaURL) { _, _ in Task { await controller.refreshOllamaStatus() } }
        .onChange(of: settings.rewriteKey) { _, _ in controller.applySettings() }
        .onChange(of: settings.language) { _, _ in controller.applySettings() }
        .onChange(of: settings.ollamaModel) { _, _ in Task { await controller.refreshOllamaStatus() } }
    }
}

// MARK: - Styles

private struct StylesTab: View {
    @ObservedObject var settings: AppSettings

    private var rows: [(bundleID: String, name: String, style: Style)] {
        settings.styleMap.effectiveMappings
            .map { (bundleID: $0.key, name: Self.appName($0.key), style: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Casual: no period after a single sentence, AI only for self-corrections. Neutral: AI for self-corrections or long passages without punctuation. Formal: like neutral, plus short forms written out (gonna → going to). Apps not listed are neutral.", "Locker: kein Punkt nach einzelnen Sätzen, KI nur bei Selbstkorrekturen. Neutral: KI bei Selbstkorrekturen oder langen Passagen ohne Satzzeichen. Förmlich: wie neutral, dazu Kurzformen ausgeschrieben (hab → habe). Nicht aufgeführte Apps sind neutral."))
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(rows, id: \.bundleID) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Picker("", selection: binding(for: row.bundleID)) {
                            ForEach(Style.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            }
            HStack {
                Menu(L("Add app", "App hinzufügen")) {
                    ForEach(runningApps, id: \.0) { app in
                        Button(app.1) { settings.styleMap.overrides[app.0] = .neutral }
                    }
                }
                .fixedSize()
                Spacer()
                Button(L("Reset", "Zurücksetzen")) { settings.styleMap = StyleMap() }
            }
        }
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { settings.styleMap.effectiveMappings[$0.0] == nil }
            .sorted { $0.1 < $1.1 }
    }

    private func binding(for bundleID: String) -> Binding<Style> {
        Binding(
            get: { settings.styleMap.style(for: bundleID) },
            set: { settings.styleMap.overrides[bundleID] = $0 })
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var state: AppState
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading) {
            if state.history.isEmpty {
                Spacer()
                Text(L("No dictations yet.", "Noch keine Diktate.")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(state.history) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.final).textSelection(.enabled)
                        if item.raw != item.final {
                            Text(L("Raw: \(item.raw)", "Roh: \(item.raw)")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("\(item.date.formatted(date: .omitted, time: .shortened)) · \(item.style.displayName) · \(item.summary.text)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Spacer()
                Button(L("Clear history", "Verlauf löschen")) { controller.clearHistory() }.disabled(state.history.isEmpty)
            }
        }
    }
}

// MARK: - Model picker

private struct ModelField: View {
    let title: String
    @Binding var value: String
    let models: [String]
    var allowSame = false

    var body: some View {
        if models.isEmpty {
            TextField(title, text: $value, prompt: Text(allowSame ? L("same as above", "wie oben") : "qwen2.5:3b"))
        } else {
            Picker(title, selection: $value) {
                if allowSame { Text(L("same as above", "wie oben")).tag("") }
                ForEach(models, id: \.self) { Text($0).tag($0) }
                if !value.isEmpty, !models.contains(value) { Text(L("\(value) (not installed)", "\(value) (nicht installiert)")).tag(value) }
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject var settings: AppSettings
    @State private var heard = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Words that should always be written the same way: names, technical terms, abbreviations. Applied instantly, without AI.", "Wörter, die immer gleich geschrieben werden sollen: Namen, Fachbegriffe, Abkürzungen. Gilt ohne KI, sofort."))
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(settings.replacements) { entry in
                    HStack {
                        Text(entry.heard).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(entry.written)
                        Spacer()
                        Button {
                            settings.replacements.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField(L("Heard as, e.g. git hub", "Erkannt als, z. B. gitt hab"), text: $heard)
                TextField(L("Write as, e.g. GitHub", "Schreiben als, z. B. GitHub"), text: $written)
                Button(L("Add", "Hinzufügen")) {
                    let entry = Replacement(heard: heard.trimmingCharacters(in: .whitespaces), written: written.trimmingCharacters(in: .whitespaces))
                    guard !entry.heard.isEmpty, !entry.written.isEmpty else { return }
                    settings.replacements.append(entry)
                    heard = ""
                    written = ""
                }
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
