import AppKit
import SaywriteCore

/// Watches the trigger keys system-wide via an active CGEventTap (needs the Accessibility permission).
/// A trigger is a modifier held on its own, a key combination, or an extra mouse button
/// (`Hotkey`); combinations and mouse buttons are swallowed, so the app underneath never sees them. The tap is a filter, not listen-only, because Esc that cancels a
/// recording is swallowed; every key press therefore waits for the callback, which must stay fast.
/// The tap-or-hold logic lives in `HotkeyStateMachine`. Clicks and scrolling come through a second,
/// listen-only tap: they are never swallowed, and a busy main thread must not make the mouse lag.
@MainActor
final class HotkeyMonitor {
    private(set) var dictateKey: Hotkey
    private(set) var rewriteKey: Hotkey?
    private(set) var pasteLastKey: Hotkey?
    var onEvent: ((HotkeyEvent) -> Void)?
    /// The paste-last shortcut was pressed. Called on the main queue.
    var onPasteLast: (() -> Void)?
    /// While a key is being recorded in the settings, every key goes through untouched.
    var isSuspended = false {
        didSet { if isSuspended { reset() } }
    }
    /// While the controller processes a released recording, Esc cancels that instead of reaching the
    /// app underneath; `onProcessingEscape` is then called on the main queue.
    var escapeCancelsProcessing = false
    var onProcessingEscape: (() -> Void)?
    /// Every key the user presses (not our own simulated ones), with its modifiers. Runs inside the
    /// tap callback, so it must stay trivial.
    var onKeyDown: ((NSEvent) -> Void)?

    private var machine = HotkeyStateMachine()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pointerTap: CFMachPort?
    private var pointerSource: CFRunLoopSource?
    private var confirmTimer: Timer?
    /// Keys and mouse buttons of a combination trigger that went down and were swallowed: their
    /// repeats and their release are swallowed too, whatever happens to the modifiers meanwhile.
    private var swallowedKeys: [UInt16: Binding] = [:]
    private var swallowedButtons: [Int: Binding] = [:]
    /// The event types the tap listens to now; a change of the bindings may need a new tap.
    private var tapMask: CGEventMask = 0
    var handsFree: Bool { machine.handsFree }

    private enum Binding {
        case trigger(HotkeyAction)
        case pasteLast
    }

    init(dictateKey: Hotkey, rewriteKey: Hotkey?, pasteLastKey: Hotkey?, mode: TriggerMode) {
        self.dictateKey = dictateKey
        self.rewriteKey = rewriteKey
        self.pasteLastKey = pasteLastKey
        machine.mode = mode
    }

    /// Takes new bindings from the settings. Restarts the tap when it has to listen to other events
    /// (key releases for a combination, mouse buttons), so plain typing does not pay for what is unused.
    func configure(dictateKey: Hotkey, rewriteKey: Hotkey?, pasteLastKey: Hotkey?, mode: TriggerMode) {
        let changed = dictateKey != self.dictateKey || rewriteKey != self.rewriteKey
        self.dictateKey = dictateKey
        self.rewriteKey = rewriteKey
        self.pasteLastKey = pasteLastKey
        machine.mode = mode
        // A held key of the old binding would otherwise never see its release.
        if changed { reset() }
        if isRunning, requiredMask != tapMask { start() }
    }

    private var bindings: [Hotkey] { [dictateKey, rewriteKey, pasteLastKey].compactMap { $0 } }

    private var requiredMask: CGEventMask {
        var mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        if bindings.contains(where: { if case .key = $0 { return true } else { return false } }) {
            mask |= 1 << CGEventType.keyUp.rawValue
        }
        if bindings.contains(where: { if case .mouse = $0 { return true } else { return false } }) {
            mask |= (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        }
        return mask
    }

    /// Starts listening. Returns false when macOS refused the event tap (Accessibility missing).
    @discardableResult
    func start() -> Bool {
        stop()
        let mask = requiredMask
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
            if type == .otherMouseDown || type == .otherMouseUp {
                let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                let consumed = MainActor.assumeIsolated { monitor.handleMouse(button: button, down: type == .otherMouseDown) }
                return consumed ? nil : Unmanaged.passUnretained(event)
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
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Debug.log("event tap refused")
            return false
        }
        tapMask = mask
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        startPointerTap()
        return true
    }

    /// A click with the trigger held (⌘-click, ⌥-click) is a shortcut too. Without this tap it would
    /// start a recording. Not having it is no reason to fail: the keys still work.
    private func startPointerTap() {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                MainActor.assumeIsolated { monitor.reenablePointerTap() }
            case .scrollWheel:
                // Momentum scrolling runs on after the fingers left the trackpad: no gesture of the user.
                if event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 {
                    MainActor.assumeIsolated { monitor.handlePointer(scroll: true) }
                }
            default:
                MainActor.assumeIsolated { monitor.handlePointer(scroll: false) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Debug.log("pointer tap refused")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pointerTap = tap
        pointerSource = source
    }

    private func reenablePointerTap() {
        if let pointerTap { CGEvent.tapEnable(tap: pointerTap, enable: true) }
    }

    private func handlePointer(scroll: Bool) {
        // Most clicks happen with no trigger held: nothing to do.
        guard machine.heldAction != nil else { return }
        let events = machine.pointer(scroll: scroll)
        if !events.isEmpty { Debug.log("cancel: click or scroll while holding") }
        emit(events)
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
        tapMask = 0
        if let pointerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), pointerSource, .commonModes) }
        if let pointerTap {
            CGEvent.tapEnable(tap: pointerTap, enable: false)
            CFMachPortInvalidate(pointerTap)
        }
        pointerTap = nil
        pointerSource = nil
    }

    var isRunning: Bool { eventTap != nil }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        // Events that arrived while the tap was disabled are lost. If the trigger key was released
        // in that window, deliver the release now so a hold does not record forever.
        swallowedKeys = swallowedKeys.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0.key)) }
        swallowedButtons = swallowedButtons.filter { Self.buttonDown($0.key) }
        guard let active = machine.heldAction, let key = hotkey(for: active) else { return }
        let stillDown: Bool
        switch key {
        case .modifier(let modifier):
            stillDown = modifier.isDown(inFlags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        case .key(let code, _):
            stillDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        case .mouse(let button):
            stillDown = Self.buttonDown(button)
        }
        if !stillDown { emit(machine.triggerUp(active)) }
    }

    private static func buttonDown(_ button: Int) -> Bool {
        guard let mouseButton = CGMouseButton(rawValue: UInt32(button)) else { return false }
        return CGEventSource.buttonState(.combinedSessionState, button: mouseButton)
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

    private func hotkey(for action: HotkeyAction) -> Hotkey? {
        action == .dictate ? dictateKey : rewriteKey
    }

    /// Which action a modifier key starts when held alone.
    private func modifierAction(keyCode: UInt16) -> HotkeyAction? {
        if dictateKey.modifierKey?.keyCode == keyCode { return .dictate }
        if rewriteKey?.modifierKey?.keyCode == keyCode { return .rewrite }
        return nil
    }

    private func binding(for hotkey: Hotkey) -> Binding? {
        if hotkey == dictateKey { return .trigger(.dictate) }
        if hotkey == rewriteKey { return .trigger(.rewrite) }
        if hotkey == pasteLastKey { return .pasteLast }
        return nil
    }

    /// A combination or mouse binding went down (`true`) or up.
    private func press(_ binding: Binding, down: Bool) {
        switch binding {
        case .trigger(let action):
            if down { keyDown(action) } else { emit(machine.triggerUp(action)) }
        case .pasteLast:
            // Not while a trigger is held: the paste would land in the middle of that recording.
            guard down, machine.active == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.onPasteLast?() }
        }
    }

    /// A modifier trigger held right now is part of the combination that was just pressed (right ⌥ for
    /// dictating, ⌃⌥R for rewriting): the press becomes that shortcut, the modifier's recording is dropped.
    /// A hands-free recording is kept; it waits for its own key.
    private func yieldHeldModifierTrigger() {
        guard let held = machine.heldAction, !machine.handsFree, hotkey(for: held)?.modifierKey != nil else { return }
        machine.reset()
        confirmTimer?.invalidate()
        emit([.cancel(held)])
    }

    /// Returns true when the mouse event must not reach the app (it is one of our buttons).
    fileprivate func handleMouse(button: Int, down: Bool) -> Bool {
        guard !isSuspended else { return false }
        if down {
            guard let binding = binding(for: .mouse(button: button)) else { return false }
            yieldHeldModifierTrigger()
            swallowedButtons[button] = binding
            press(binding, down: true)
            return true
        }
        guard let binding = swallowedButtons.removeValue(forKey: button) else { return false }
        press(binding, down: false)
        return true
    }

    /// Returns true when the event should not reach other apps.
    private func handle(_ event: NSEvent) -> Bool {
        guard !isSuspended else { return false }
        switch event.type {
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        case .flagsChanged:
            handleFlags(event)
            return false
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // A combination trigger that is down: its auto-repeat must not type into the app, also when
        // a modifier of it was let go meanwhile.
        if swallowedKeys[event.keyCode] != nil {
            if event.isARepeat { return true }
            // A fresh press: the release of the last one was lost (tap disabled). Never swallow the
            // key for good, it may be a letter the user types.
            swallowedKeys[event.keyCode] = nil
        }
        let combination = Hotkey.key(code: event.keyCode, modifiers: ModifierSet(flags: event.modifierFlags.rawValue))
        if let binding = binding(for: combination) {
            guard !event.isARepeat else { return true }
            yieldHeldModifierTrigger()
            swallowedKeys[event.keyCode] = binding
            press(binding, down: true)
            return true
        }
        onKeyDown?(event)
        if event.keyCode == 53 /* Escape */ {
            let (events, consumed) = machine.escape()
            emit(events)
            if !consumed, escapeCancelsProcessing {
                DispatchQueue.main.async { [weak self] in self?.onProcessingEscape?() }
                return true
            }
            return consumed
        }
        // After the hold is confirmed, keys no longer cancel (see HotkeyStateMachine.otherKey).
        let events = machine.otherKey()
        if !events.isEmpty { Debug.log("cancel: key \(event.keyCode) pressed while holding") }
        emit(events)
        return false
    }

    /// The release of a swallowed combination key ends that press.
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let binding = swallowedKeys.removeValue(forKey: event.keyCode) else { return false }
        press(binding, down: false)
        return true
    }

    private func handleFlags(_ event: NSEvent) {
        // A combination or mouse trigger is held: letting go of its modifiers first, or pressing
        // another one, changes nothing. Only the key or button itself ends the press.
        if let held = machine.heldAction, hotkey(for: held)?.modifierKey == nil { return }
        let action: HotkeyAction
        if let match = modifierAction(keyCode: event.keyCode) {
            action = match
        } else {
            // A different modifier pressed while holding: treat as shortcut.
            guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
            let events = machine.otherModifier()
            if !events.isEmpty { Debug.log("cancel: modifier \(event.keyCode) flags \(event.modifierFlags.rawValue) while holding") }
            emit(events)
            return
        }
        guard let key = hotkey(for: action)?.modifierKey else { return }
        if key.isDown(inFlags: event.modifierFlags.rawValue) {
            keyDown(action)
        } else {
            emit(machine.triggerUp(action))
        }
    }

    private func keyDown(_ action: HotkeyAction) {
        let events = machine.triggerDown(action)
        guard events.contains(.begin(action)) else { return }
        emit(events)
        confirmTimer?.invalidate()
        let timer = Timer(timeInterval: machine.minimumHold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let confirmed = self.machine.confirmation() else { return }
                self.emit([confirmed])
            }
        }
        // Common modes: the confirmation also fires while a menu or a drag tracks events, instead of
        // waiting until the release has overtaken it.
        RunLoop.main.add(timer, forMode: .common)
        confirmTimer = timer
    }
}
