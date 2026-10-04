import AppKit
import SaywriteCore

/// Watches a modifier key that is held on its own, system-wide, via an active CGEventTap (needs
/// the Accessibility permission). The tap is a filter, not listen-only, because Esc that cancels a
/// recording is swallowed; every key press therefore waits for the callback, which must stay fast.
/// The tap-or-hold logic lives in `HotkeyStateMachine`.
@MainActor
final class HotkeyMonitor {
    var dictateKey: TriggerKey
    var rewriteKey: TriggerKey
    var onEvent: ((HotkeyEvent) -> Void)?

    private var machine = HotkeyStateMachine()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var confirmTimer: Timer?
    var handsFree: Bool { machine.handsFree }

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
                // Esc that cancels a recording is swallowed, so it does not also close a dialog or
                // leave full screen in the app underneath.
                let consumed = MainActor.assumeIsolated { monitor.handle(nsEvent) }
                if consumed { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
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
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // Without invalidating, every restart (e.g. after granting Accessibility) leaks a port.
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    var isRunning: Bool { eventTap != nil }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        // Events that arrived while the tap was disabled are lost. If the trigger key was released
        // in that window, deliver the release now so a hold does not record forever.
        guard let active = machine.heldAction else { return }
        let key = active == .dictate ? dictateKey : rewriteKey
        let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        let stillDown: Bool
        switch key {
        case .rightOption: stillDown = flags.rawValue & 0x40 != 0
        case .rightCommand: stillDown = flags.rawValue & 0x10 != 0
        case .rightControl: stillDown = flags.rawValue & 0x2000 != 0
        case .fn: stillDown = flags.contains(.function)
        }
        if !stillDown { emit(machine.triggerUp(active)) }
    }

    /// Events are delivered after the tap callback returned: with a filtering tap every key press
    /// waits for the callback, so starting the microphone there would make typing lag.
    private func emit(_ events: [HotkeyEvent]) {
        // Any outcome of the press other than its start ends the wait for "held long enough".
        if events.contains(where: { if case .begin = $0 { return false } else { return true } }) {
            confirmTimer?.invalidate()
        }
        for event in events {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    /// Called by the controller when a session ended by other means (error, cancel via menu).
    func reset() {
        machine.reset()
        confirmTimer?.invalidate()
    }

    /// Returns true when the event should not reach other apps.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            handleFlags(event)
            return false
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 /* Escape */ {
            let (events, consumed) = machine.escape()
            emit(events)
            return consumed
        }
        let events = machine.otherKey()
        if !events.isEmpty { Debug.log("cancel: key \(event.keyCode) pressed while holding") }
        emit(events)
        return false
    }

    private func handleFlags(_ event: NSEvent) {
        let action: HotkeyAction
        if event.keyCode == dictateKey.keyCode {
            action = .dictate
        } else if event.keyCode == rewriteKey.keyCode {
            action = .rewrite
        } else {
            // A different modifier pressed while holding: treat as shortcut.
            guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
            let events = machine.otherModifier()
            if !events.isEmpty { Debug.log("cancel: modifier \(event.keyCode) flags \(event.modifierFlags.rawValue) while holding") }
            emit(events)
            return
        }
        let key = action == .dictate ? dictateKey : rewriteKey
        if isDown(key, event) {
            keyDown(action)
        } else {
            emit(machine.triggerUp(action))
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
        let events = machine.triggerDown(action)
        guard events.contains(.begin(action)) else { return }
        emit(events)
        confirmTimer?.invalidate()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: machine.minimumHold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let confirmed = self.machine.confirmation() else { return }
                self.emit([confirmed])
            }
        }
    }
}
