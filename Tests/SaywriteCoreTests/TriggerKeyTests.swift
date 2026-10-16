import XCTest
@testable import SaywriteCore

/// Trigger key: clicks and stray keys while holding (round 4).
final class TriggerKeyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Other keys after the confirmation

    func testKeyBeforeConfirmationStillCancels() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.otherKey(), [.cancel(.dictate)])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.5), [])
    }

    func testStrayKeyDoesNotDiscardALongRecording() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.confirmation(), .confirmed(.dictate))
        XCTAssertEqual(machine.otherKey(), [])
        XCTAssertEqual(machine.otherModifier(), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 40), [.end(.dictate)])
        XCTAssertNil(machine.active)
    }

    func testSlowShortcutIsCancelledOnRelease() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.otherKey(), []) // ⌥ held a moment, then L for @
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.8), [.cancel(.dictate)])
        XCTAssertNil(machine.active)
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0 + 2), [.begin(.dictate)])
    }

    func testConfirmedHoldWithoutKeyEndsEvenWhenShort() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.8), [.end(.dictate)])
    }

    func testKeyFlagDoesNotLeakIntoTheNextPress() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        _ = machine.otherKey()
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.8), [.cancel(.dictate)])
        _ = machine.triggerDown(.dictate, at: t0 + 2)
        _ = machine.confirmation()
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 2.8), [.end(.dictate)])
    }

    func testKeysDuringHandsFreeStopTapAreIgnored() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.1), [.handsFree(.dictate)])
        _ = machine.triggerDown(.dictate, at: t0 + 30)
        XCTAssertEqual(machine.otherKey(), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 30.1), [.end(.dictate)])
    }

    func testEscapeStillCancelsAfterConfirmation() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        let escape = machine.escape()
        XCTAssertEqual(escape.events, [.cancel(.dictate)])
        XCTAssertTrue(escape.consumed)
    }

    // MARK: - Clicks while holding

    // After the confirmation a click counts like a key: a ⌘-click released soon after is a shortcut,
    // a long recording with a click in it is kept.
    func testClickAfterConfirmationCancelsOnlyOnAQuickRelease() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.rewrite, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.pointer(), []) // ⌘-click with the right ⌘
        XCTAssertEqual(machine.triggerUp(.rewrite, at: t0 + 1), [.cancel(.rewrite)])
        XCTAssertNil(machine.active)
    }

    func testClickInALongConfirmedHoldKeepsTheDictation() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.pointer(), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 20), [.end(.dictate)])
    }

    func testScrollAfterConfirmationIsIgnored() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.pointer(scroll: true), [])
        // Even a quick release after the scroll ends the dictation normally.
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.8), [.end(.dictate)])
    }

    func testScrollBeforeConfirmationStillCancels() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.pointer(scroll: true), [.cancel(.dictate)])
        XCTAssertNil(machine.confirmation())
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 2), [])
    }

    func testQuickClickCancelsAndNoConfirmationFollows() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.pointer(), [.cancel(.dictate)])
        XCTAssertNil(machine.confirmation())
    }

    func testClicksDoNotTouchHandsFreeOrIdle() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.pointer(), [])
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.triggerUp(.dictate, at: t0 + 0.1)
        XCTAssertEqual(machine.pointer(), []) // key up, user works with the mouse
        _ = machine.triggerDown(.dictate, at: t0 + 5)
        XCTAssertEqual(machine.pointer(), []) // the stop tap
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 5.1), [.end(.dictate)])
    }
}
