import AppKit
import ServiceManagement
import SwiftUI
import SaywriteCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController
    let updates: UpdateNotifier

    var body: some View {
        TabView {
            SetupTab(settings: settings, state: state, controller: controller)
                .tabItem { Label(L("Setup", "Einrichtung"), systemImage: "checklist") }
            GeneralTab(settings: settings, state: state, controller: controller, updates: updates)
                .tabItem { Label(L("General", "Allgemein"), systemImage: "gearshape") }
            StylesTab(settings: settings)
                .tabItem { Label(L("Styles", "Stile"), systemImage: "textformat") }
            DictionaryTab(settings: settings)
                .tabItem { Label(L("Dictionary", "Wörterbuch"), systemImage: "character.book.closed") }
            HistoryTab(settings: settings, state: state, controller: controller)
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
                if settings.llmBackend == .builtin {
                    BuiltinModelRow(state: state, controller: controller)
                } else {
                    StatusRow(ok: state.ollamaState == .ready, title: L("AI (Ollama)", "KI (Ollama)"), detail: ollamaDetail,
                              actionTitle: L("Check", "Prüfen"), alwaysShowAction: true) {
                        Task { await controller.refreshOllamaStatus() }
                    }
                }
            } header: {
                Text("Status")
            } footer: {
                if settings.llmBackend == .builtin {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.builtinState != .ready {
                            Text(L("Saywrite works without the AI model too – just without AI cleanup.", "Ohne das KI-Modell funktioniert Saywrite trotzdem – nur ohne KI-Aufräumen."))
                        }
                        Text(L("Model: \(ModelSpec.qwen25_3b.displayName), \(ByteSize.text(ModelSpec.qwen25_3b.size)), runs on this Mac. Licence: non-commercial use only.",
                               "Modell: \(ModelSpec.qwen25_3b.displayName), \(ByteSize.text(ModelSpec.qwen25_3b.size)), läuft auf diesem Mac. Lizenz: nur nicht-kommerzielle Nutzung."))
                        Link(ModelSpec.qwen25_3b.licenseName, destination: ModelSpec.qwen25_3b.licenseURL)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if state.ollamaState == .unreachable || state.ollamaState == .modelMissing {
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
            Section {
                LaunchAtLoginRow()
            } footer: {
                Text(L("So dictation is ready right after you log in.", "Damit Diktieren gleich nach dem Anmelden bereit ist."))
                    .font(.caption).foregroundStyle(.secondary)
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
        case .loading(let p): return p > 0 && p < 1 ? L("Downloading… \(Int(p * 100))%", "Wird heruntergeladen … \(Int(p * 100)) %") : L("Loading…", "Wird geladen …")
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

/// The row for the built-in model: size and licence are shown (in the footer) before the first
/// download, which only starts with a click, and the progress is shown like the speech model's.
private struct BuiltinModelRow: View {
    @ObservedObject var state: AppState
    let controller: DictationController

    private var sizeText: String { ByteSize.text(ModelSpec.qwen25_3b.size) }

    var body: some View {
        HStack {
            Image(systemName: state.builtinState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(state.builtinState == .ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("AI (built-in)", "KI (eingebaut)"))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if case .downloading(let fraction) = state.builtinState {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                }
            }
            Spacer()
            switch state.builtinState {
            case .notDownloaded:
                Button(L("Download (\(sizeText))", "Herunterladen (\(sizeText))")) { controller.downloadBuiltinModel() }
            case .partial:
                Button(L("Resume", "Fortsetzen")) { controller.downloadBuiltinModel() }
                Button(L("Delete", "Löschen")) { controller.deleteBuiltinModel() }
            case .downloading:
                Button(L("Pause", "Pause")) { controller.pauseBuiltinDownload() }
            case .verifying, .optimizing:
                ProgressView().controlSize(.small)
            case .ready:
                Button(L("Delete model", "Modell löschen")) { controller.deleteBuiltinModel() }
            case .failed:
                // An interrupted download keeps its partial file: continue it rather than "try again".
                Button(controller.hasPartialDownload ? L("Resume", "Fortsetzen") : L("Try again", "Erneut versuchen")) {
                    controller.downloadBuiltinModel()
                }
                Button(L("Delete", "Löschen")) { controller.deleteBuiltinModel() }
            }
        }
    }

    private var detail: String {
        switch state.builtinState {
        case .notDownloaded: return L("Not downloaded yet", "Noch nicht heruntergeladen")
        case .partial(let bytes):
            let percent = Int(Double(bytes) / Double(ModelSpec.qwen25_3b.size) * 100)
            return L("Download paused at \(percent)%", "Download pausiert bei \(percent) %")
        case .downloading(let fraction): return L("Downloading… \(Int(fraction * 100))%", "Wird heruntergeladen … \(Int(fraction * 100)) %")
        case .verifying: return L("Verifying…", "Wird geprüft …")
        case .optimizing: return L("Optimizing for your Mac…", "Wird an deinen Mac angepasst …")
        case .ready: return L("Ready (\(ModelSpec.qwen25_3b.displayName))", "Bereit (\(ModelSpec.qwen25_3b.displayName))")
        case .failed(let message): return L("Error: \(message)", "Fehler: \(message)")
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

/// "Launch at login" with what macOS answered: a refusal or a pending approval is shown, with a way
/// to System Settings, instead of the switch silently flipping back.
private struct LaunchAtLoginRow: View {
    @State private var enabled = LaunchAtLoginRow.isOn
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var failure: String?

    /// Registered, also while macOS still waits for the user's approval.
    private static var isOn: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("Launch at login", "Beim Anmelden starten"), isOn: $enabled)
                .onChange(of: enabled) { _, wanted in
                    // Also fires when refresh() syncs the toggle; nothing to do then.
                    guard Self.isOn != wanted else { return }
                    do {
                        if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        failure = nil
                    } catch {
                        Debug.log("login item: \(error)")
                        failure = error.localizedDescription
                    }
                    refresh()
                }
            if needsApproval || failure != nil {
                HStack(alignment: .firstTextBaseline) {
                    Text(needsApproval
                         ? L("macOS waits for your approval under Login Items.", "macOS wartet unter Anmeldeobjekte auf deine Freigabe.")
                         : L("macOS refused: \(failure ?? "")", "macOS hat abgelehnt: \(failure ?? "")"))
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L("Open Login Items", "Anmeldeobjekte öffnen")) { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
        }
        .onAppear(perform: refresh)
        // Approved in System Settings meanwhile: pick it up when the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        enabled = Self.isOn
        needsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController
    let updates: UpdateNotifier
    @State private var microphones = AudioDevices.inputs()
    @State private var urlRefresh: Task<Void, Never>?

    private let languages: [(String, String)] = [
        ("auto", L("Automatic (German / English)", "Automatisch (Deutsch / Englisch)")),
        ("en", L("English", "Englisch")), ("de", L("German", "Deutsch")), ("fr", L("French", "Französisch")),
        ("es", L("Spanish", "Spanisch")), ("it", L("Italian", "Italienisch")), ("nl", L("Dutch", "Niederländisch")),
        ("pl", L("Polish", "Polnisch")), ("pt", L("Portuguese", "Portugiesisch")),
    ]

    /// Shown when the Ollama address points away from this Mac, where dictations would go.
    private var remoteOllamaWarning: String? {
        guard settings.ollamaURLValid else {
            return L("This address is not valid (use http://host:port): the local Ollama is used instead.",
                     "Diese Adresse ist ungültig (http://Host:Port verwenden): es wird das lokale Ollama benutzt.")
        }
        guard !settings.ollamaConfiguration.isLocal else { return nil }
        if settings.ollamaURL.lowercased().hasPrefix("https://") {
            return L("This address is not on this Mac: every dictation and selected text for rewriting is sent there.",
                     "Diese Adresse liegt nicht auf diesem Mac: jedes Diktat und markierter Text zum Umformulieren gehen dorthin.")
        }
        return L("This address is not on this Mac: every dictation and selected text for rewriting is sent there unencrypted.",
                 "Diese Adresse liegt nicht auf diesem Mac: jedes Diktat und markierter Text zum Umformulieren gehen unverschlüsselt dorthin.")
    }

    private func refreshSystemState() {
        microphones = AudioDevices.inputs()
        // Settings from before the name was stored learn it while the microphone is connected.
        if let device = microphones.first(where: { $0.id == settings.inputDeviceUID }), settings.inputDeviceName != device.name {
            settings.inputDeviceName = device.name
        }
    }

    /// The chosen microphone is not connected: recordings use the system default until it is back.
    private var chosenMicrophoneMissing: Bool {
        !settings.inputDeviceUID.isEmpty && !microphones.contains { $0.id == settings.inputDeviceUID }
    }

    private var fnKeyChosen: Bool { settings.dictateKey == .fn || settings.rewriteKey == .fn }

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
                if fnKeyChosen {
                    // Otherwise macOS also reacts to the key (emoji picker, its own dictation).
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("For fn / 🌐, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.",
                               "Für fn / 🌐 in Systemeinstellungen › Tastatur „🌐-Taste drücken“ auf „Nichts tun“ stellen."))
                            .font(.caption).foregroundStyle(.orange)
                        Link(L("Open Keyboard settings", "Tastatur-Einstellungen öffnen"),
                             destination: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                            .font(.caption)
                    }
                }
            }
            Section(L("Recording", "Aufnahme")) {
                Picker(L("Microphone", "Mikrofon"), selection: $settings.inputDeviceUID) {
                    Text(L("System default", "Systemstandard")).tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if chosenMicrophoneMissing {
                        let name = settings.inputDeviceName.isEmpty ? L("Chosen microphone", "Gewähltes Mikrofon") : settings.inputDeviceName
                        Text(L("\(name) (not connected)", "\(name) (nicht verbunden)")).tag(settings.inputDeviceUID)
                    }
                }
                .onChange(of: settings.inputDeviceUID) { _, uid in
                    if let device = microphones.first(where: { $0.id == uid }) { settings.inputDeviceName = device.name }
                }
                if chosenMicrophoneMissing {
                    Text(L("Not connected – the system default is used until it is back.",
                           "Nicht verbunden – bis es wieder da ist, wird der Systemstandard benutzt."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(L("Short sound on start and stop", "Kurzer Ton bei Start und Stopp"), isOn: $settings.playSounds)
            }
            Section(L("Language & AI", "Sprache & KI")) {
                Picker(L("Language", "Sprache"), selection: $settings.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(L("AI cleanup (only when needed)", "KI-Aufräumen (nur wenn nötig)"), isOn: $settings.aiEnabled)
                Picker(L("AI engine", "KI-Engine"), selection: $settings.llmBackend) {
                    Text(L("Built-in model", "Eingebautes Modell")).tag(LLMBackend.builtin)
                    Text("Ollama").tag(LLMBackend.ollama)
                }
                if settings.llmBackend == .ollama {
                    ModelField(title: L("Model (cleanup)", "Modell (Aufräumen)"), value: $settings.ollamaModel, models: state.installedModels)
                    ModelField(title: L("Model (rewrite)", "Modell (Umformulieren)"), value: $settings.rewriteModel, models: state.installedModels, allowSame: true)
                    TextField(L("Ollama address", "Ollama-Adresse"), text: $settings.ollamaURL)
                    if let warning = remoteOllamaWarning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
                Stepper(L("AI time limit: \(Int(settings.llmTimeout)) s", "KI-Zeitlimit: \(Int(settings.llmTimeout)) s"), value: $settings.llmTimeout, in: 3...30)
            }
            Section {
                LaunchAtLoginRow()
                UpdateCheckRow(settings: settings, updates: updates)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.dictateKey) { _, key in
            if settings.rewriteKey == key {
                settings.rewriteKey = TriggerKey.allCases.first { $0 != key } ?? .rightCommand
            }
            controller.applySettings()
        }
        .onChange(of: settings.ollamaURL) { _, _ in
            // Wait until typing pauses: no request per keystroke to half-typed addresses.
            urlRefresh?.cancel()
            urlRefresh = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await controller.refreshOllamaStatus()
            }
        }
        // The window is kept between openings: pick up new microphones and a changed login item.
        .onAppear(perform: refreshSystemState)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshSystemState() }
        .onChange(of: settings.rewriteKey) { _, _ in controller.applySettings() }
        .onChange(of: settings.language) { _, _ in controller.applySettings() }
        .onChange(of: settings.ollamaModel) { _, _ in Task { await controller.refreshOllamaStatus() } }
        .onChange(of: settings.llmBackend) { _, _ in controller.backendChanged() }
        .onChange(of: settings.checkForUpdates) { _, _ in updates.enabledChanged() }
    }
}

/// "Check for updates": one request to GitHub per day at most, and a button for checking right away.
private struct UpdateCheckRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateNotifier

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(L("Check for updates", "Nach Updates suchen"), isOn: $settings.checkForUpdates)
                Spacer()
                Button(L("Check now", "Jetzt prüfen")) { updates.checkNow() }
                    .controlSize(.small)
                    .disabled(!settings.checkForUpdates || updates.manualResult == .checking)
            }
            if let result = updates.manualResult {
                switch result {
                case .checking:
                    Text(L("Checking…", "Wird geprüft …")).font(.caption).foregroundStyle(.secondary)
                case .upToDate(let version):
                    Text(L("Saywrite \(version) is up to date.", "Saywrite \(version) ist aktuell.")).font(.caption).foregroundStyle(.secondary)
                case .available(let release):
                    Button(UpdateNotifier.availableText(release)) { updates.openReleasePage() }
                        .buttonStyle(.link).font(.caption)
                case .failed(let error):
                    Text(UpdateNotifier.errorText(error)).font(.caption).foregroundStyle(.orange)
                }
            } else if let release = updates.available {
                Button(UpdateNotifier.availableText(release)) { updates.openReleasePage() }
                    .buttonStyle(.link).font(.caption)
            } else {
                Text(L("Once a day, asks GitHub for the newest version. Sends nothing about you or your dictations; never downloads anything.",
                       "Fragt einmal täglich bei GitHub die neueste Version ab. Sendet nichts über dich oder deine Diktate; lädt nie etwas herunter."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    let controller: DictationController
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(L("Keep recent dictations on this Mac", "Letzte Diktate auf diesem Mac behalten"), isOn: $settings.keepHistory)
                .onChange(of: settings.keepHistory) { _, keep in if !keep { controller.clearHistory() } }
            Text(L("Stored unencrypted for 30 days at most, readable by your user only. Rewrites are not stored.",
                   "Unverschlüsselt gespeichert, höchstens 30 Tage, nur für deinen Benutzer lesbar. Umformulierungen werden nicht gespeichert."))
                .font(.caption).foregroundStyle(.secondary)
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
                    .contextMenu {
                        Button(L("Copy", "Kopieren")) { TextInserter.copy(item.final) }
                        Button(L("Delete", "Löschen"), role: .destructive) { controller.removeHistory(id: item.id) }
                    }
                }
            }
            HStack {
                Text(L("Right-click an entry to copy or delete it.", "Rechtsklick auf einen Eintrag: kopieren oder löschen."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Clear history…", "Verlauf löschen …")) { confirmClear = true }.disabled(state.history.isEmpty)
            }
            .confirmationDialog(L("Delete all \(state.history.count) dictations?", "Alle \(state.history.count) Diktate löschen?"),
                                isPresented: $confirmClear) {
                Button(L("Delete all", "Alle löschen"), role: .destructive) { controller.clearHistory() }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(L("This cannot be undone.", "Das lässt sich nicht rückgängig machen."))
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
