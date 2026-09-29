import AppKit
import Combine
import SwiftUI
import SaywriteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let state = AppState()
    private var overlay: OverlayController!
    private var controller: DictationController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.log("launched, accessibility=\(Permissions.accessibilityGranted) mic=\(Permissions.microphoneStatus)")
        overlay = OverlayController()
        controller = DictationController(
            settings: settings, state: state, overlay: overlay,
            history: HistoryStore(fileURL: HistoryStore.defaultFileURL()))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Saywrite")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.start()
        watchPermissions()

        if !state.accessibilityGranted || Permissions.microphoneStatus != .granted {
            openSettings()
        }
        if Permissions.microphoneStatus == .undetermined {
            Task { state.microphoneGranted = await Permissions.requestMicrophone() }
        }
    }

    /// Accessibility can be granted at any time in System Settings; pick it up without a restart.
    private func watchPermissions() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let granted = Permissions.accessibilityGranted
                // A tap created before access was granted exists but receives nothing, so it is
                // re-created the moment access is granted (or if creating it failed earlier).
                let justGranted = granted && !self.state.accessibilityGranted
                if granted && (justGranted || !self.controller.hotkeysActive) {
                    Debug.log("accessibility granted, restarting hotkeys")
                    self.controller.restartHotkeys()
                }
                self.state.accessibilityGranted = granted
                self.state.microphoneGranted = Permissions.microphoneStatus == .granted
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
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

        let aiItem = NSMenuItem(title: L("AI cleanup", "KI-Aufräumen"), action: #selector(toggleAI), keyEquivalent: "")
        aiItem.target = self
        aiItem.state = settings.aiEnabled ? .on : .off
        menu.addItem(aiItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings …", "Einstellungen …"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: L("Quit Saywrite", "Saywrite beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusLine: String {
        if !state.accessibilityGranted { return L("⚠ Accessibility access missing", "⚠ Bedienungshilfen fehlen") }
        switch state.modelState {
        case .loading(let p): return L("Speech model loading … \(Int(p * 100)) %", "Sprachmodell lädt … \(Int(p * 100)) %")
        case .failed: return L("⚠ Speech model error", "⚠ Sprachmodell-Fehler")
        case .ready: return L("Ready – tap \(settings.dictateKey.displayName)", "Bereit – \(settings.dictateKey.displayName) tippen")
        }
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func pasteLast() {
        controller.pasteLast()
    }

    @objc private func toggleAI() {
        settings.aiEnabled.toggle()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, state: state, controller: controller)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Saywrite"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Task { await controller.refreshOllamaStatus() }
    }
}
