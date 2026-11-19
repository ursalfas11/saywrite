import AppKit
import Combine
import SwiftUI
import SaywriteCore
import SaywriteLlama

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let state = AppState()
    private var overlay: OverlayController!
    private var controller: DictationController!
    private var updates: UpdateNotifier!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var systemObservers: [NSObjectProtocol] = []
    /// Another app has secure input on (password field, some terminals): the event tap may get no keys.
    private var secureInputActive = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.log("launched, accessibility=\(Permissions.accessibilityGranted) mic=\(Permissions.microphoneStatus)")
        overlay = OverlayController()
        controller = DictationController(
            settings: settings, state: state, overlay: overlay,
            history: HistoryStore(fileURL: HistoryStore.defaultFileURL()))
        controller.openSettings = { [weak self] in self?.openSettings() }
        // Before anything can open the settings, which show its switch.
        updates = UpdateNotifier(settings: settings)
        // An accessory app has no menu bar, but its key equivalents (⌘V, ⌘C, ⌘A, ⌘Z, ⌘W) still come
        // from the main menu: without one, text fields in the settings window cannot paste.
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Saywrite")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.start()
        updates.start()
        watchPermissions()
        watchSystemEvents()

        if !state.accessibilityGranted || Permissions.microphoneStatus != .granted {
            openSettings()
        }
        if Permissions.microphoneStatus == .undetermined {
            Task { state.microphoneGranted = await Permissions.requestMicrophone() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A paste may still be waiting to give the user's clipboard back.
        TextInserter.restorePendingClipboard()
        // ggml asserts at exit when the Metal model is still loaded.
        LlamaEngine.shared.shutdown()
    }

    /// Accessibility can be granted at any time in System Settings; pick it up without a restart.
    private func watchPermissions() {
        schedulePermissionTimer(every: 2)
    }

    private func schedulePermissionTimer(every interval: TimeInterval) {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }
        // Nothing here is urgent: the tolerance lets macOS bundle the wake-up with others.
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func checkPermissions() {
        let granted = Permissions.accessibilityGranted
        // A tap created before access was granted exists but receives nothing, so it is
        // re-created the moment access is granted (or if creating it failed earlier).
        let justGranted = granted && !state.accessibilityGranted
        if granted && (justGranted || !controller.hotkeysActive) {
            Debug.log("accessibility granted, restarting hotkeys")
            controller.restartHotkeys()
        }
        state.accessibilityGranted = granted
        state.microphoneGranted = Permissions.microphoneStatus == .granted
        let secure = TextInserter.secureInputActive
        if secure != secureInputActive {
            Debug.log("secure input \(secure ? "on: the trigger key may be blocked" : "off")")
            secureInputActive = secure
        }
        // Every 2 s while something is missing, so granting takes effect at once; then every 10 s,
        // which still notices a revoked permission or secure input soon enough.
        let complete = granted && state.microphoneGranted && controller.hotkeysActive
        let interval: TimeInterval = complete ? 10 : 2
        if permissionTimer?.timeInterval != interval { schedulePermissionTimer(every: interval) }
    }

    /// A recording, or a dictation still being processed, must not run on through sleep, a locked
    /// screen or a switch to another user: it would be inserted afterwards into whatever is in front then.
    private func watchSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification]
        for name in names {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.controller.cancelRecording(because: note.name.rawValue) }
            })
        }
        let locked = Notification.Name("com.apple.screenIsLocked")
        systemObservers.append(DistributedNotificationCenter.default().addObserver(forName: locked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.cancelRecording(because: locked.rawValue) }
        })
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The status lines open the settings, where each problem has its button.
        for (line, problem) in statusLines {
            let item = NSMenuItem(title: line, action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            if problem { item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) }
            menu.addItem(item)
        }
        // Not a setting of Saywrite (another app holds it), so a plain line without an action.
        secureInputActive = TextInserter.secureInputActive
        if secureInputActive {
            let secure = NSMenuItem(title: L("Secure input active – shortcut may be blocked", "Gesicherte Eingabe aktiv – Tastenkürzel evtl. blockiert"), action: nil, keyEquivalent: "")
            secure.isEnabled = false
            secure.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            menu.addItem(secure)
        }
        // Only a hint: opens the release page in the browser, nothing is downloaded.
        if let release = updates.available {
            let update = NSMenuItem(title: UpdateNotifier.availableText(release), action: #selector(openReleasePage), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(update)
        }
        if case .failed = state.modelState {
            let retry = NSMenuItem(title: L("Load speech model again", "Sprachmodell erneut laden"), action: #selector(retryModelLoad), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())

        let recent = NSMenuItem(title: L("Recent dictations", "Letzte Diktate"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if state.history.isEmpty {
            let empty = NSMenuItem(title: L("None yet", "Noch keine"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for item in state.history {
            let title = item.final.count > 60 ? String(item.final.prefix(60)) + "…" : item.final
            let entry = NSMenuItem(title: title.replacingOccurrences(of: "\n", with: " "), action: #selector(copyHistory(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.final
            entry.toolTip = L("Click to copy", "Klicken zum Kopieren")
            submenu.addItem(entry)
        }
        recent.submenu = submenu
        menu.addItem(recent)

        let pasteItem = NSMenuItem(title: L("Paste last dictation", "Letztes Diktat einfügen"), action: #selector(pasteLast), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = !state.history.isEmpty
        menu.addItem(pasteItem)

        // Switched on but not usable (model missing, Ollama down) is not a plain check mark.
        let aiTitle = settings.aiEnabled && aiProblem != nil
            ? L("AI cleanup (not available)", "KI-Aufräumen (nicht verfügbar)") : L("AI cleanup", "KI-Aufräumen")
        let aiItem = NSMenuItem(title: aiTitle, action: #selector(toggleAI), keyEquivalent: "")
        aiItem.target = self
        aiItem.state = settings.aiEnabled ? (aiProblem == nil ? .on : .mixed) : .off
        menu.addItem(aiItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings…", "Einstellungen …"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: L("Quit Saywrite", "Saywrite beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Each line with whether it is a problem. "Ready" only when nothing blocks a dictation.
    private var statusLines: [(String, Bool)] {
        var lines: [(String, Bool)] = []
        if !state.accessibilityGranted { lines.append((L("Accessibility access missing", "Bedienungshilfen fehlen"), true)) }
        if Permissions.microphoneStatus != .granted { lines.append((L("Microphone access missing", "Mikrofon-Zugriff fehlt"), true)) }
        switch state.modelState {
        case .loading(let p): lines.append((L("Speech model loading… \(Int(p * 100))%", "Sprachmodell lädt … \(Int(p * 100)) %"), false))
        case .failed: lines.append((L("Speech model error", "Sprachmodell-Fehler"), true))
        case .ready:
            if lines.isEmpty {
                lines.append((L("Ready – tap \(settings.dictateKey.displayName)", "Bereit – \(settings.dictateKey.displayName) tippen"), false))
            }
        }
        if settings.aiEnabled, let aiProblem { lines.append((aiProblem, true)) }
        return lines
    }

    /// Why the switched-on AI cannot clean up right now, or nil.
    private var aiProblem: String? {
        switch settings.llmBackend {
        case .builtin:
            switch state.builtinState {
            case .ready: return nil
            case .downloading(let fraction):
                return L("AI model downloading… \(Int(fraction * 100))%", "KI-Modell wird heruntergeladen … \(Int(fraction * 100)) %")
            case .verifying, .optimizing: return L("AI model being prepared…", "KI-Modell wird vorbereitet …")
            case .notDownloaded, .partial: return L("AI model not downloaded – rules only", "KI-Modell nicht heruntergeladen – nur Regeln")
            case .failed: return L("AI model error – rules only", "KI-Modell-Fehler – nur Regeln")
            }
        case .ollama:
            switch state.ollamaState {
            case .ready, .unknown: return nil
            case .unreachable: return L("Ollama not reachable – rules only", "Ollama nicht erreichbar – nur Regeln")
            case .modelMissing: return L("Ollama model missing – rules only", "Ollama-Modell fehlt – nur Regeln")
            }
        }
    }

    @objc private func openReleasePage() {
        updates.openReleasePage()
    }

    @objc private func retryModelLoad() {
        controller.retryModelLoad()
    }

    /// App, Edit and Window menus: never visible (accessory app), only there for the standard shortcuts.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            for entry in items { menu.addItem(entry) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Saywrite", [
            item(L("Hide Saywrite", "Saywrite ausblenden"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Quit Saywrite", "Saywrite beenden"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu(L("Edit", "Bearbeiten"), [
            item(L("Undo", "Widerrufen"), Selector(("undo:")), "z"),
            item(L("Redo", "Wiederholen"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut", "Ausschneiden"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy", "Kopieren"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste", "Einsetzen"), #selector(NSText.paste(_:)), "v"),
            item(L("Select All", "Alles auswählen"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(L("Window", "Fenster"), [
            item(L("Close", "Schließen"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copy(text)
    }

    @objc private func pasteLast() {
        controller.pasteLast()
    }

    @objc private func toggleAI() {
        settings.aiEnabled.toggle()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, state: state, controller: controller, updates: updates)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Saywrite"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        controller.refreshBuiltinState()
        if settings.llmBackend == .ollama { Task { await controller.refreshOllamaStatus() } }
    }
}
