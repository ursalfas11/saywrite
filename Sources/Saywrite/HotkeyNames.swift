import AppKit
import Carbon
import SaywriteCore
import SwiftUI

extension ModifierKey {
    var displayName: String {
        switch self {
        case .rightOption: return L("Right ⌥ Option", "Rechte ⌥ Option")
        case .rightCommand: return L("Right ⌘ Command", "Rechte ⌘ Command")
        case .rightControl: return L("Right ⌃ Control", "Rechte ⌃ Control")
        case .rightShift: return L("Right ⇧ Shift", "Rechte ⇧ Umschalt")
        case .fn: return "fn / 🌐"
        case .leftOption: return L("Left ⌥ Option", "Linke ⌥ Option")
        case .leftCommand: return L("Left ⌘ Command", "Linke ⌘ Command")
        case .leftControl: return L("Left ⌃ Control", "Linke ⌃ Control")
        case .leftShift: return L("Left ⇧ Shift", "Linke ⇧ Umschalt")
        }
    }
}

extension Hotkey {
    /// The name shown in the settings, the menu and the hints, e.g. "Right ⌥ Option", "⌃⌥D", "F5".
    @MainActor
    var displayName: String {
        switch self {
        case .modifier(let key):
            return key.displayName
        case .key(let code, let modifiers):
            return modifiers.symbols + Self.keyName(code)
        case .mouse(let button):
            if button == 2 { return L("Middle mouse button", "Mittlere Maustaste") }
            return L("Mouse button \(button + 1)", "Maustaste \(button + 1)")
        }
    }

    /// The short status line of the menu, e.g. "Ready – tap Right ⌥ Option".
    @MainActor
    func readyLine(mode: TriggerMode) -> String {
        let name = displayName
        if mode == .holdOnly { return L("Ready – hold \(name)", "Bereit – \(name) halten") }
        if case .mouse = self { return L("Ready – click \(name)", "Bereit – \(name) klicken") }
        return L("Ready – tap \(name)", "Bereit – \(name) tippen")
    }

    /// The "How it works" lines for the chosen keys and mode.
    @MainActor
    static func howItWorks(dictate: Hotkey, rewrite: Hotkey?, mode: TriggerMode) -> [LocalizedStringKey] {
        var lines: [LocalizedStringKey] = []
        let d = dictate.displayName
        let click: Bool = { if case .mouse = dictate { return true } else { return false } }()
        switch mode {
        case .holdOnly:
            lines.append(LM("Hold **\(d)** while you speak, release – the text is inserted. **Esc** cancels.",
                            "**\(d)** halten, solange du sprichst, loslassen = Text wird eingefügt. **Esc** bricht ab."))
        case .tapOnly:
            lines.append(click
                ? LM("Click **\(d)**, speak, click again – the text is inserted. **Esc** cancels.",
                     "**\(d)** klicken, sprechen, nochmal klicken = Text wird eingefügt. **Esc** bricht ab.")
                : LM("Tap **\(d)**, speak, tap again – the text is inserted. **Esc** cancels.",
                     "**\(d)** einmal tippen, sprechen, nochmal tippen = Text wird eingefügt. **Esc** bricht ab."))
        case .tapOrHold:
            lines.append(click
                ? LM("Click **\(d)**, speak, click again – the text is inserted.",
                     "**\(d)** klicken, sprechen, nochmal klicken = Text wird eingefügt.")
                : LM("Tap **\(d)**, speak, tap again – the text is inserted.",
                     "**\(d)** einmal tippen, sprechen, nochmal tippen = Text wird eingefügt."))
            lines.append(LM("Or hold it and release when you are done. **Esc** cancels.",
                            "Oder gedrückt halten und loslassen, wenn du fertig bist. **Esc** bricht ab."))
        }
        if let rewrite {
            let r = rewrite.displayName
            lines.append(mode == .holdOnly
                ? LM("Select text, hold **\(r)**, say what should change, release.",
                     "Text markieren, **\(r)** halten, sagen, was sich ändern soll, loslassen.")
                : LM("Select text, press **\(r)**, say what should change, press again.",
                     "Text markieren, **\(r)** drücken, sagen, was sich ändern soll, nochmal drücken."))
        }
        return lines
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌅", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 114: "Help",
        65: "Num .", 67: "Num *", 69: "Num +", 75: "Num /", 78: "Num -", 81: "Num =",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7",
        91: "Num 8", 92: "Num 9", 71: "Clear",
    ]

    @MainActor
    static func keyName(_ code: UInt16) -> String {
        if let index = functionKeyCodes.firstIndex(of: code) { return "F\(index + 1)" }
        if code == 49 { return L("Space", "Leertaste") }
        if let name = specialKeys[code] { return name }
        return character(for: code) ?? "#\(code)"
    }

    /// What the key prints on the current keyboard layout, so a German keyboard shows Z where Z is.
    /// The Text Input Sources API wants the main thread.
    @MainActor
    private static func character(for code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.uppercased()
    }
}

extension Hotkey.Problem {
    var message: String {
        switch self {
        case .escapeReserved:
            return L("Esc cancels a recording and cannot be a trigger.", "Esc bricht eine Aufnahme ab und kann kein Auslöser sein.")
        case .needsModifier:
            return L("A letter or Space alone would block typing. Add ⌃ or ⌥, or use F1–F20.",
                     "Eine Taste allein würde das Tippen blockieren. ⌃ oder ⌥ dazunehmen oder F1–F20 wählen.")
        case .commandOnly:
            return L("⌘ plus a key is mostly taken already (⌘C, ⌘V …). Add ⌃ or ⌥.",
                     "⌘ plus Taste ist meist schon belegt (⌘C, ⌘V …). ⌃ oder ⌥ dazunehmen.")
        case .primaryMouseButton:
            return L("The left and right mouse buttons cannot be a trigger. Use the middle or a side button.",
                     "Linke und rechte Maustaste gehen nicht. Mittlere oder eine Seitentaste nehmen.")
        case .alreadyUsed:
            return L("Already used for another action.", "Schon für eine andere Aktion belegt.")
        }
    }
}

/// Records the next key, combination, modifier or extra mouse button pressed in the settings window.
/// The global event tap is suspended meanwhile (see `DictationController.setHotkeysSuspended`), so
/// pressing the current trigger does not start a dictation.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    /// A modifier that went down with no other modifier: released on its own, it becomes the trigger.
    private var pendingModifier: ModifierKey?
    /// nil: cancelled with Esc.
    private var onResult: ((Hotkey?) -> Void)?

    func start(_ onResult: @escaping (Hotkey?) -> Void) {
        stop()
        self.onResult = onResult
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        onResult = nil
        isRecording = false
    }

    /// Returns true when the event was used for recording and must not reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            pendingModifier = nil
            let modifiers = ModifierSet(flags: event.modifierFlags.rawValue)
            if event.keyCode == Hotkey.escapeKeyCode, modifiers.isEmpty {
                finish(nil)
            } else {
                finish(.key(code: event.keyCode, modifiers: modifiers))
            }
            return true
        case .flagsChanged:
            guard let key = ModifierKey(keyCode: event.keyCode) else { return true } // Caps Lock
            let flags = event.modifierFlags.rawValue
            if key.isDown(inFlags: flags) {
                let others = ModifierSet(flags: flags).subtracting(ModifierSet(flags: key.flag))
                pendingModifier = others.isEmpty ? key : nil
            } else if pendingModifier == key {
                finish(.modifier(key))
            } else {
                pendingModifier = nil
            }
            return true
        case .otherMouseDown:
            finish(.mouse(button: event.buttonNumber))
            return true
        default:
            return false
        }
    }

    private func finish(_ hotkey: Hotkey?) {
        let callback = onResult
        stop()
        callback?(hotkey)
    }
}

/// One key binding in the settings: a menu with the usual keys, "Record…" and (where allowed) "Off".
struct HotkeyField: View {
    let slot: HotkeySlot
    @ObservedObject var settings: AppSettings
    let controller: DictationController
    @StateObject private var recorder = KeyRecorder()
    @State private var problem: String?

    private var current: Hotkey? { settings.hotkey(for: slot) }
    private var others: [Hotkey?] { settings.hotkeysOtherThan(slot) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if recorder.isRecording {
                HStack(spacing: 8) {
                    Text(L("Press a key, a combination or a mouse button …", "Taste, Kombination oder Maustaste drücken …"))
                        .foregroundStyle(.secondary)
                    Button(L("Cancel", "Abbrechen")) { stopRecording() }
                }
            } else {
                Menu(current?.displayName ?? L("Off", "Aus")) {
                    ForEach(ModifierKey.presets, id: \.self) { key in
                        let hotkey = Hotkey.modifier(key)
                        Button {
                            choose(hotkey)
                        } label: {
                            if current == hotkey { Label(key.displayName, systemImage: "checkmark") } else { Text(key.displayName) }
                        }
                        .disabled(others.contains(hotkey))
                    }
                    Divider()
                    Button(L("Other key or combination …", "Andere Taste oder Kombination …")) { startRecording() }
                    if slot != .dictate {
                        Divider()
                        Button(L("Off", "Aus")) { choose(nil) }
                    }
                }
                .fixedSize()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        problem = nil
        controller.setHotkeysSuspended(true)
        recorder.start { hotkey in
            controller.setHotkeysSuspended(false)
            if let hotkey { choose(hotkey) }
        }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop()
        controller.setHotkeysSuspended(false)
    }

    private func choose(_ hotkey: Hotkey?) {
        if let hotkey, let issue = hotkey.problem(others: others) {
            problem = issue.message
            return
        }
        problem = nil
        settings.setHotkey(hotkey, for: slot)
        controller.applySettings()
    }
}
