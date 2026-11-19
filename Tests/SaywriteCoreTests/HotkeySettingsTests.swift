import XCTest
@testable import SaywriteCore

/// Free choice of the trigger (modifier, key combination, mouse button) and the trigger modes.
final class HotkeySettingsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Modes

    func testTapOrHoldIsTheDefault() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.mode, .tapOrHold)
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.1), [.handsFree(.dictate)])
        _ = machine.triggerDown(.dictate, at: t0 + 5)
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 5.1), [.end(.dictate)])
    }

    func testHoldOnlyDropsAShortTap() {
        var machine = HotkeyStateMachine()
        machine.mode = .holdOnly
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0), [.begin(.dictate)])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.1), [.cancel(.dictate)])
        XCTAssertNil(machine.active)
        XCTAssertFalse(machine.handsFree)
        // The next press starts a fresh recording.
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0 + 1), [.begin(.dictate)])
    }

    func testHoldOnlyFinishesOnRelease() {
        var machine = HotkeyStateMachine()
        machine.mode = .holdOnly
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.confirmation(), .confirmed(.dictate))
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 4), [.end(.dictate)])
        XCTAssertNil(machine.active)
    }

    func testTapOnlyKeepsRecordingAfterAHold() {
        var machine = HotkeyStateMachine()
        machine.mode = .tapOnly
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.confirmation()
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 3), [.handsFree(.dictate)])
        XCTAssertTrue(machine.handsFree)
        // The next press finishes, however long it is held.
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0 + 10), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 12), [.end(.dictate)])
        XCTAssertNil(machine.active)
    }

    func testTapOnlyShortTapStartsHandsFree() {
        var machine = HotkeyStateMachine()
        machine.mode = .tapOnly
        _ = machine.triggerDown(.rewrite, at: t0)
        XCTAssertEqual(machine.triggerUp(.rewrite, at: t0 + 0.1), [.handsFree(.rewrite)])
    }

    func testSlowShortcutStillCancelsInEveryMode() {
        for mode in TriggerMode.allCases {
            var machine = HotkeyStateMachine()
            machine.mode = mode
            _ = machine.triggerDown(.dictate, at: t0)
            _ = machine.confirmation()
            XCTAssertEqual(machine.otherKey(), [], "\(mode)")
            XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.8), [.cancel(.dictate)], "\(mode)")
            XCTAssertNil(machine.active, "\(mode)")
        }
    }

    func testModeSurvivesReset() {
        var machine = HotkeyStateMachine()
        machine.mode = .holdOnly
        machine.reset()
        XCTAssertEqual(machine.mode, .holdOnly)
    }

    // MARK: - Which keys may be a trigger

    func testModifiersAlwaysWork() {
        for key in ModifierKey.allCases {
            XCTAssertNil(Hotkey.modifier(key).problem(), "\(key)")
        }
    }

    func testCombinationsWithControlOrOption() {
        let d: UInt16 = 2
        XCTAssertNil(Hotkey.key(code: d, modifiers: [.control, .option]).problem())
        XCTAssertNil(Hotkey.key(code: 49, modifiers: .option).problem()) // ⌥Space
        XCTAssertNil(Hotkey.key(code: d, modifiers: [.command, .option]).problem())
        XCTAssertNil(Hotkey.key(code: d, modifiers: [.control, .shift, .command]).problem())
    }

    func testFunctionKeysWorkAlone() {
        for code in Hotkey.functionKeyCodes {
            XCTAssertNil(Hotkey.key(code: code, modifiers: []).problem(), "F-key \(code)")
        }
    }

    func testPlainKeysAndShiftAloneAreRefused() {
        XCTAssertEqual(Hotkey.key(code: 2, modifiers: []).problem(), .needsModifier)
        XCTAssertEqual(Hotkey.key(code: 49, modifiers: []).problem(), .needsModifier) // Space
        XCTAssertEqual(Hotkey.key(code: 2, modifiers: .shift).problem(), .needsModifier)
    }

    func testCommandAloneIsRefused() {
        XCTAssertEqual(Hotkey.key(code: 9, modifiers: .command).problem(), .commandOnly) // ⌘V
        XCTAssertEqual(Hotkey.key(code: 9, modifiers: [.command, .shift]).problem(), .commandOnly)
    }

    func testEscapeStaysReserved() {
        XCTAssertEqual(Hotkey.key(code: Hotkey.escapeKeyCode, modifiers: []).problem(), .escapeReserved)
        XCTAssertEqual(Hotkey.key(code: Hotkey.escapeKeyCode, modifiers: [.control, .option]).problem(), .escapeReserved)
    }

    func testMouseButtons() {
        XCTAssertEqual(Hotkey.mouse(button: 0).problem(), .primaryMouseButton)
        XCTAssertEqual(Hotkey.mouse(button: 1).problem(), .primaryMouseButton)
        XCTAssertNil(Hotkey.mouse(button: 2).problem())
        XCTAssertNil(Hotkey.mouse(button: 4).problem())
    }

    func testABindingCannotServeTwoActions() {
        let taken = Hotkey.key(code: 2, modifiers: [.control, .option])
        XCTAssertEqual(taken.problem(others: [.defaultDictate, taken]), .alreadyUsed)
        XCTAssertEqual(Hotkey.defaultDictate.problem(others: [.defaultDictate]), .alreadyUsed)
        XCTAssertNil(Hotkey.defaultRewrite.problem(others: [.defaultDictate, nil]))
    }

    // MARK: - Flags

    func testModifierSetIgnoresFnAndKeypad() {
        // ⌥ + an arrow key: macOS adds fn (bit 23) and the keypad flag (bit 21).
        let flags: UInt = (1 << 19) | (1 << 23) | (1 << 21)
        XCTAssertEqual(ModifierSet(flags: flags), .option)
        XCTAssertEqual(ModifierSet(flags: (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)).symbols, "⌃⌥⇧⌘")
    }

    func testLeftAndRightAreToldApart() {
        let rightOption: UInt = (1 << 19) | 0x40
        XCTAssertTrue(ModifierKey.rightOption.isDown(inFlags: rightOption))
        XCTAssertFalse(ModifierKey.leftOption.isDown(inFlags: rightOption))
        XCTAssertTrue(ModifierKey.fn.isDown(inFlags: 1 << 23))
        XCTAssertFalse(ModifierKey.rightCommand.isDown(inFlags: 0x10)) // device bit without ⌘ is stale
    }

    func testKeyCodesRoundTrip() {
        for key in ModifierKey.allCases {
            XCTAssertEqual(ModifierKey(keyCode: key.keyCode), key)
        }
        XCTAssertNil(ModifierKey(keyCode: 57)) // Caps Lock is no trigger
    }

    // MARK: - Settings

    func testEarlierSettingsAreTakenOver() {
        XCTAssertEqual(Hotkey(legacy: "rightOption"), .modifier(.rightOption))
        XCTAssertEqual(Hotkey(legacy: "rightCommand"), .modifier(.rightCommand))
        XCTAssertEqual(Hotkey(legacy: "rightControl"), .modifier(.rightControl))
        XCTAssertEqual(Hotkey(legacy: "fn"), .modifier(.fn))
        XCTAssertNil(Hotkey(legacy: "somethingElse"))
        for name in ["rightOption", "rightCommand", "rightControl", "fn"] {
            XCTAssertEqual(Hotkey(legacy: name)?.legacyName, name)
        }
        XCTAssertNil(Hotkey.key(code: 2, modifiers: [.control, .option]).legacyName)
    }

    func testBindingsSurviveStorage() throws {
        let all: [Hotkey?] = [
            .modifier(.leftOption), .key(code: 2, modifiers: [.control, .option]), .key(code: 96, modifiers: []),
            .mouse(button: 3), nil,
        ]
        let data = try JSONEncoder().encode(all)
        XCTAssertEqual(try JSONDecoder().decode([Hotkey?].self, from: data), all)
        XCTAssertEqual(try JSONDecoder().decode(TriggerMode.self, from: JSONEncoder().encode(TriggerMode.holdOnly)), .holdOnly)
    }
}
