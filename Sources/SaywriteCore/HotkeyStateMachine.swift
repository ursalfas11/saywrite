import Foundation

public enum HotkeyAction: Sendable {
    case dictate
    case rewrite
}

public enum HotkeyEvent: Sendable, Equatable {
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

/// The tap-or-hold logic of the trigger keys, without event tap and timer, so it can be tested.
/// The monitor feeds it key events and delivers the returned events.
public struct HotkeyStateMachine: Sendable {
    public let minimumHold: TimeInterval

    public private(set) var active: HotkeyAction?
    public private(set) var pressTime: Date?
    public private(set) var interrupted = false
    public private(set) var handsFree = false

    public init(minimumHold: TimeInterval = 0.3) {
        self.minimumHold = minimumHold
    }

    /// The trigger that is physically held right now, if any.
    public var heldAction: HotkeyAction? { pressTime != nil ? active : nil }

    /// A session ended by other means (error, cancel via menu).
    public mutating func reset() {
        active = nil
        pressTime = nil
        handsFree = false
        interrupted = false
    }

    /// Escape cancels a recording; `consumed` means it must not reach the app underneath.
    public mutating func escape() -> (events: [HotkeyEvent], consumed: Bool) {
        if let active, !interrupted {
            handsFree = false
            interrupted = true
            self.active = nil
            pressTime = nil
            return ([.cancel(active)], true)
        }
        return (otherKey(), false)
    }

    /// Another key while holding the trigger means the user typed a shortcut (e.g. ⌥L for @).
    public mutating func otherKey() -> [HotkeyEvent] {
        guard let active, pressTime != nil, !interrupted else { return [] }
        interrupted = true
        return [.cancel(active)]
    }

    /// A different modifier went down while holding the trigger: also a shortcut.
    public mutating func otherModifier() -> [HotkeyEvent] {
        otherKey()
    }

    public mutating func triggerDown(_ action: HotkeyAction, at now: Date = Date()) -> [HotkeyEvent] {
        guard pressTime == nil else { return [] }
        if handsFree {
            // Only the key that started hands-free mode ends it; handled on release.
            guard action == active else { return [] }
            pressTime = now
            interrupted = false
            return []
        }
        guard active == nil else { return [] }
        active = action
        pressTime = now
        interrupted = false
        return [.begin(action)]
    }

    /// The hold timer started with `.begin` fired.
    public func confirmation() -> HotkeyEvent? {
        guard let active, pressTime != nil, !interrupted else { return nil }
        return .confirmed(active)
    }

    public mutating func triggerUp(_ action: HotkeyAction, at now: Date = Date()) -> [HotkeyEvent] {
        guard let pressTime, active == action else { return [] }
        let held = now.timeIntervalSince(pressTime)
        self.pressTime = nil

        if handsFree {
            handsFree = false
            active = nil
            return [.end(action)]
        }
        if interrupted {
            active = nil
            return []
        }
        if held >= minimumHold {
            active = nil
            return [.end(action)]
        }
        // Short tap: the recording that started on key down simply continues hands-free.
        handsFree = true
        return [.handsFree(action)]
    }
}
