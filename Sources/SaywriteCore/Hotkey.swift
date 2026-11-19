import Foundation

/// How a trigger behaves when it is pressed and released.
public enum TriggerMode: String, CaseIterable, Codable, Sendable {
    /// Tap to start and tap again to finish, or hold while speaking and release (the default).
    case tapOrHold
    /// Push to talk: records only while held. A short tap does nothing.
    case holdOnly
    /// On/off: every press starts or finishes, however long it is held.
    case tapOnly
}

/// A modifier key that can be a trigger on its own.
public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case rightOption, rightCommand, rightControl, rightShift, fn
    case leftOption, leftCommand, leftControl, leftShift

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .rightShift: return 60
        case .fn: return 63
        case .leftOption: return 58
        case .leftCommand: return 55
        case .leftControl: return 59
        case .leftShift: return 56
        }
    }

    /// The NX_DEVICE* bit in the event flags that tells this key from its twin on the other side.
    /// nil for fn, which has only the device-independent flag.
    public var deviceMask: UInt? {
        switch self {
        case .leftControl: return 0x0001
        case .leftShift: return 0x0002
        case .rightShift: return 0x0004
        case .leftCommand: return 0x0008
        case .rightCommand: return 0x0010
        case .leftOption: return 0x0020
        case .rightOption: return 0x0040
        case .rightControl: return 0x2000
        case .fn: return nil
        }
    }

    /// The device-independent modifier this key sets (NSEvent.ModifierFlags raw values).
    public var flag: UInt {
        switch self {
        case .leftShift, .rightShift: return 1 << 17
        case .leftControl, .rightControl: return 1 << 18
        case .leftOption, .rightOption: return 1 << 19
        case .leftCommand, .rightCommand: return 1 << 20
        case .fn: return 1 << 23
        }
    }

    public init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// Whether the key is down according to the raw modifier flags of an event.
    public func isDown(inFlags flags: UInt) -> Bool {
        guard flags & flag != 0 else { return false }
        guard let deviceMask else { return true }
        return flags & deviceMask != 0
    }

    /// The keys a user picks from a list. The left ones are also possible, through recording a key.
    public static let presets: [ModifierKey] = [.rightOption, .rightCommand, .rightControl, .rightShift, .fn]
}

/// The modifiers of a key combination, without left and right.
public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    /// From raw event flags (NSEvent.ModifierFlags / CGEventFlags). fn and the keypad flag are left out:
    /// macOS sets fn on every arrow and function key.
    public init(flags: UInt) {
        var set: ModifierSet = []
        if flags & (1 << 18) != 0 { set.insert(.control) }
        if flags & (1 << 19) != 0 { set.insert(.option) }
        if flags & (1 << 17) != 0 { set.insert(.shift) }
        if flags & (1 << 20) != 0 { set.insert(.command) }
        self = set
    }

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// What starts a dictation or a rewrite: a modifier held on its own, a key (usually with modifiers),
/// or an extra mouse button.
public enum Hotkey: Codable, Hashable, Sendable {
    case modifier(ModifierKey)
    case key(code: UInt16, modifiers: ModifierSet)
    /// Mouse button number as macOS counts it: 2 is the middle button, 3 and 4 the side buttons.
    case mouse(button: Int)

    public static let escapeKeyCode: UInt16 = 53

    /// F1 to F20: they may be a trigger without a modifier, since nobody types with them.
    public static let functionKeyCodes: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Why a recorded key cannot be used.
    public enum Problem: Equatable, Sendable {
        /// Esc cancels a recording and stays reserved for that.
        case escapeReserved
        /// A plain key or ⇧ plus a key would block normal typing.
        case needsModifier
        /// ⌘ plus a key is mostly taken already (⌘C, ⌘V, ⌘Z …), and swallowing it would break that.
        case commandOnly
        /// The left and right mouse buttons are needed for everything else.
        case primaryMouseButton
        /// Another action already uses it.
        case alreadyUsed
    }

    /// nil when `self` can be a trigger. `others` are the bindings of the other actions.
    public func problem(others: [Hotkey?] = []) -> Problem? {
        switch self {
        case .modifier:
            break
        case .key(let code, let modifiers):
            if code == Self.escapeKeyCode { return .escapeReserved }
            let isFunctionKey = Self.functionKeyCodes.contains(code)
            if !isFunctionKey {
                if modifiers.isEmpty || modifiers == .shift { return .needsModifier }
                if modifiers == .command || modifiers == [.command, .shift] { return .commandOnly }
            }
        case .mouse(let button):
            if button < 2 { return .primaryMouseButton }
        }
        if others.contains(where: { $0 == self }) { return .alreadyUsed }
        return nil
    }

    public var modifierKey: ModifierKey? {
        if case .modifier(let key) = self { return key }
        return nil
    }

    /// The earlier settings stored one of four modifier names.
    public init?(legacy name: String) {
        switch name {
        case "rightOption": self = .modifier(.rightOption)
        case "rightCommand": self = .modifier(.rightCommand)
        case "rightControl": self = .modifier(.rightControl)
        case "fn": self = .modifier(.fn)
        default: return nil
        }
    }

    /// The name an earlier version understands, so going back to it keeps the key where possible.
    public var legacyName: String? {
        switch self {
        case .modifier(.rightOption): return "rightOption"
        case .modifier(.rightCommand): return "rightCommand"
        case .modifier(.rightControl): return "rightControl"
        case .modifier(.fn): return "fn"
        default: return nil
        }
    }

    public static let defaultDictate = Hotkey.modifier(.rightOption)
    public static let defaultRewrite = Hotkey.modifier(.rightCommand)
}
