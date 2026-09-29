import AppKit
import SaywriteCore

enum HotkeyAction {
    case dictate
    case rewrite
}

enum HotkeyEvent {
    /// Key went down: start recording right away (latency matters).
    case begin(HotkeyAction)
    /// Key held long enough to be push-to-talk, not a shortcut: good time to prewarm.
    case confirmed(HotkeyAction)
    /// Key released after a hold, or tapped again in hands-free mode: finish and insert.
    case end(HotkeyAction)
    /// Shortcut (another key pressed while holding) or Escape: throw the recording away.
    case cancel(HotkeyAction)
    /// Short tap: keep recording hands-free until the key is tapped again.
    case handsFree(HotkeyAction)
}

/// Watches a modifier key that is held on its own, system-wide, via a listen-only CGEventTap
/// (needs the Accessibility permission).
@MainActor
final class HotkeyMonitor {
    var dictateKey: TriggerKey
    var rewriteKey: TriggerKey
    var onEvent: ((HotkeyEvent) -> Void)?

    private let minimumHold: TimeInterval = 0.3

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var active: HotkeyAction?
    private var pressTime: Date?
    private var interrupted = false
    private var confirmTimer: Timer?
    private(set) var handsFree = false

    init(dictateKey: TriggerKey, rewriteKey: TriggerKey) {
        self.dictateKey = dictateKey
        self.rewriteKey = rewriteKey
    }

    /// Starts listening. Returns false when macOS refused the event tap (Accessibility missing).
    @discardableResult
    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { monitor.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            // Our own simulated ⌘C/⌘V/⌘Z must not count as "user pressed another key".
            if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag {
                return Unmanaged.passUnretained(event)
            }
            if let nsEvent = NSEvent(cgEvent: event) {
                MainActor.assumeIsolated { monitor.handle(nsEvent) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Debug.log("event tap refused")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTap = nil
        runLoopSource = nil
    }

    var isRunning: Bool { eventTap != nil }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        // Events that arrived while the tap was disabled are lost. If the trigger key was released
        // in that window, deliver the release now so a hold does not record forever.
        guard let active, pressTime != nil else { return }
        let key = active == .dictate ? dictateKey : rewriteKey
        let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        let stillDown: Bool
        switch key {
        case .rightOption: stillDown = flags.rawValue & 0x40 != 0
        case .rightCommand: stillDown = flags.rawValue & 0x10 != 0
        case .rightControl: stillDown = flags.rawValue & 0x2000 != 0
        case .fn: stillDown = flags.contains(.function)
        }
        if !stillDown { keyUp(active) }
    }

    /// Called by the controller when a session ended by other means (error, cancel via menu).
    func reset() {
        active = nil
        pressTime = nil
        handsFree = false
        interrupted = false
        confirmTimer?.invalidate()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .flagsChanged:
            handleFlags(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 /* Escape */ {
            if let active {
                handsFree = false
                interrupted = true
                self.active = nil
                pressTime = nil
                confirmTimer?.invalidate()
                onEvent?(.cancel(active))
                return
            }
        }
        // Another key while holding the trigger means the user typed a shortcut (e.g. ⌥L for @).
        if let active, pressTime != nil, !interrupted {
            Debug.log("cancel: key \(event.keyCode) pressed while holding")
            interrupted = true
            confirmTimer?.invalidate()
            onEvent?(.cancel(active))
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let action: HotkeyAction
        if event.keyCode == dictateKey.keyCode {
            action = .dictate
        } else if event.keyCode == rewriteKey.keyCode {
            action = .rewrite
        } else {
            // A different modifier pressed while holding: treat as shortcut.
            if let active, pressTime != nil, !interrupted, !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                Debug.log("cancel: modifier \(event.keyCode) flags \(event.modifierFlags.rawValue) while holding")
                interrupted = true
                confirmTimer?.invalidate()
                onEvent?(.cancel(active))
            }
            return
        }
        let key = action == .dictate ? dictateKey : rewriteKey
        if isDown(key, event) {
            keyDown(action)
        } else {
            keyUp(action)
        }
    }

    private func isDown(_ key: TriggerKey, _ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch key {
        case .rightOption: return flags.contains(.option) && flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand: return flags.contains(.command) && flags.rawValue & 0x10 != 0 // NX_DEVICERCMDKEYMASK
        case .rightControl: return flags.contains(.control) && flags.rawValue & 0x2000 != 0 // NX_DEVICERCTLKEYMASK
        case .fn: return flags.contains(.function)
        }
    }

    private func keyDown(_ action: HotkeyAction) {
        guard pressTime == nil else { return }
        if handsFree {
            // Only the key that started hands-free mode ends it; handled on release.
            guard action == active else { return }
            pressTime = Date()
            interrupted = false
            return
        }
        guard active == nil else { return }
        active = action
        pressTime = Date()
        interrupted = false
        onEvent?(.begin(action))
        confirmTimer?.invalidate()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: minimumHold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let active = self.active, self.pressTime != nil, !self.interrupted else { return }
                self.onEvent?(.confirmed(active))
            }
        }
    }

    private func keyUp(_ action: HotkeyAction) {
        guard let pressTime, active == action else { return }
        let held = Date().timeIntervalSince(pressTime)
        self.pressTime = nil
        confirmTimer?.invalidate()

        if handsFree {
            handsFree = false
            active = nil
            onEvent?(.end(action))
            return
        }
        if interrupted {
            active = nil
            return
        }
        if held >= minimumHold {
            active = nil
            onEvent?(.end(action))
            return
        }
        // Short tap: the recording that started on key down simply continues hands-free.
        handsFree = true
        onEvent?(.handsFree(action))
    }
}
