import XCTest
@testable import SaywriteCore

// MARK: - Hotkeys

final class HotkeyStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testHoldBeginsConfirmsAndEnds() {
        var machine = HotkeyStateMachine()
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0), [.begin(.dictate)])
        XCTAssertEqual(machine.confirmation(), .confirmed(.dictate))
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 1), [.end(.dictate)])
        XCTAssertNil(machine.active)
    }

    func testTapGoesHandsFreeAndSecondTapEnds() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 0.1), [.handsFree(.dictate)])
        XCTAssertTrue(machine.handsFree)
        XCTAssertEqual(machine.triggerDown(.dictate, at: t0 + 2), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 2.1), [.end(.dictate)])
        XCTAssertFalse(machine.handsFree)
    }

    func testOtherTriggerDuringHandsFreeIsIgnored() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.triggerUp(.dictate, at: t0 + 0.1)
        XCTAssertEqual(machine.triggerDown(.rewrite, at: t0 + 1), [])
        XCTAssertEqual(machine.triggerUp(.rewrite, at: t0 + 1.1), [])
        XCTAssertTrue(machine.handsFree)
    }

    func testShortcutWhileHoldingCancelsAndReleaseIsSilent() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        XCTAssertEqual(machine.otherKey(), [.cancel(.dictate)])
        XCTAssertNil(machine.confirmation())
        XCTAssertEqual(machine.otherKey(), [])
        XCTAssertEqual(machine.triggerUp(.dictate, at: t0 + 1), [])
        XCTAssertNil(machine.active)
    }

    func testEscapeCancelsAndIsSwallowedOnlyWhileRecording() {
        var machine = HotkeyStateMachine()
        let idle = machine.escape()
        XCTAssertEqual(idle.events, [])
        XCTAssertFalse(idle.consumed)

        _ = machine.triggerDown(.dictate, at: t0)
        _ = machine.triggerUp(.dictate, at: t0 + 0.1) // hands-free
        let cancel = machine.escape()
        XCTAssertEqual(cancel.events, [.cancel(.dictate)])
        XCTAssertTrue(cancel.consumed)
        XCTAssertFalse(machine.handsFree)
        XCTAssertNil(machine.active)
    }

    func testHeldActionOnlyWhilePhysicallyDown() {
        var machine = HotkeyStateMachine()
        XCTAssertNil(machine.heldAction)
        _ = machine.triggerDown(.rewrite, at: t0)
        XCTAssertEqual(machine.heldAction, .rewrite)
        _ = machine.triggerUp(.rewrite, at: t0 + 0.1)
        XCTAssertNil(machine.heldAction) // hands-free, but the key is up
    }

    func testResetClearsEverything() {
        var machine = HotkeyStateMachine()
        _ = machine.triggerDown(.dictate, at: t0)
        machine.reset()
        XCTAssertNil(machine.active)
        XCTAssertEqual(machine.triggerDown(.rewrite, at: t0 + 1), [.begin(.rewrite)])
    }
}

// MARK: - Paste target

final class PasteTargetRulesTests: XCTestCase {
    func testNativeTextFieldSupportsUndo() {
        let focus = PasteTargetRules.Focus(role: "AXTextArea", selectedRangeSettable: true)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.apple.TextEdit", focus: focus, isElectron: false), .textField)
    }

    func testTerminalIsBlindEvenWithTextArea() {
        let focus = PasteTargetRules.Focus(role: "AXTextArea", selectedRangeSettable: true)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.apple.Terminal", focus: focus, isElectron: false), .blind)
    }

    func testReadOnlyWebPageIsNotATarget() {
        let focus = PasteTargetRules.Focus(role: "AXWebArea", selectedRangeSettable: false, editableDocument: false)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.apple.Safari", focus: focus, isElectron: false), .none)
        XCTAssertTrue(PasteTargetRules.needsEditableDocumentCheck(role: "AXWebArea", selectedRangeSettable: false))
    }

    func testEditableWebDocumentIsATextField() {
        let focus = PasteTargetRules.Focus(role: "AXWebArea", selectedRangeSettable: false, editableDocument: true)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.apple.mail", focus: focus, isElectron: false), .textField)
    }

    func testElectronWithoutFocusIsBlind() {
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.tinyspeck.slackmacgap", focus: nil, isElectron: false), .blind)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.example.unknown", focus: nil, isElectron: true), .blind)
    }

    func testFinderIsNotATarget() {
        let focus = PasteTargetRules.Focus(role: "AXList", selectedRangeSettable: false)
        XCTAssertEqual(PasteTargetRules.decide(bundleID: "com.apple.finder", focus: focus, isElectron: false), .none)
    }
}

// MARK: - Output guards

final class GuardHardeningTests: XCTestCase {
    func testShortWordsDoNotCountAsSharedStems() {
        XCTAssertFalse(LLMOutputGuard.sharesStem("i", "in"))
        XCTAssertFalse(LLMOutputGuard.sharesStem("ab", "abend"))
        XCTAssertTrue(LLMOutputGuard.sharesStem("komme", "kommen"))
    }

    func testOutputBuiltOnSingleLettersIsRejected() {
        // Same length, but no word in common: the old prefix rule counted every output word as
        // shared because each starts with one of the one-letter input words.
        XCTAssertNil(LLMOutputGuard.acceptCleanup(
            input: "a b c d e f", output: "Alle bleiben cool, danke euch fürs Kommen.", style: .neutral))
    }

    func testRewriteStripsPreambleLine() {
        XCTAssertEqual(LLMOutputGuard.acceptRewrite(
            selection: "hey, can't make it tomorrow", instruction: "more formal",
            output: "Here is the more formal version:\n\nUnfortunately, I cannot attend tomorrow."),
            "Unfortunately, I cannot attend tomorrow.")
    }

    func testRewriteWithOnlyPreambleIsRejected() {
        XCTAssertNil(LLMOutputGuard.acceptRewrite(selection: "Hallo", instruction: "förmlicher", output: "Hier ist die überarbeitete Fassung:"))
    }

    func testRewriteThatTurnsIntoAnEssayIsRejected() {
        let essay = Array(repeating: "Dies ist ein sehr langer Absatz über etwas ganz anderes.", count: 10).joined(separator: " ")
        XCTAssertNil(LLMOutputGuard.acceptRewrite(selection: "Danke dir", instruction: "förmlicher", output: essay))
    }

    func testRewriteEchoingTheInstructionIsRejected() {
        XCTAssertNil(LLMOutputGuard.acceptRewrite(selection: "Wir sehen uns", instruction: "kürzer", output: "Kürzer."))
    }

    func testTranslationAndLegitimateOpenersPass() {
        XCTAssertEqual(LLMOutputGuard.acceptRewrite(
            selection: "Danke für deine Hilfe", instruction: "auf Englisch", output: "Thanks for your help."),
            "Thanks for your help.")
        XCTAssertEqual(LLMOutputGuard.acceptRewrite(
            selection: "ich komm gern morgen vorbei", instruction: "förmlicher", output: "Gerne komme ich morgen vorbei."),
            "Gerne komme ich morgen vorbei.")
    }

    func testSelectionThatStartsWithAHeadingKeepsIt() {
        XCTAssertEqual(LLMOutputGuard.acceptRewrite(
            selection: "Version 2:\nwir machen das so", instruction: "förmlicher", output: "Version 2:\nWir gehen so vor."),
            "Version 2:\nWir gehen so vor.")
    }
}

// MARK: - Circuit breaker

actor CountingLLMLog {
    var calls = 0
    func record() { calls += 1 }
}

struct ThrowingLLM: LLMClient {
    let log = CountingLLMLog()
    let error: LLMError
    func prewarm(forRewrite: Bool) async {}
    func cleanup(text: String, style: Style, language: DictationLanguage) async throws -> String {
        await log.record()
        throw error
    }
    func rewrite(selection: String, instruction: String) async throws -> String { throw error }
}

final class CircuitBreakerTests: XCTestCase {
    override func setUp() { UILanguage.override = true }
    override func tearDown() { UILanguage.override = nil }

    private let twoCorrections = [1: "um drei, nein, um vier.", 2: "am Montag, nein, am Dienstag."]

    func testTimeoutStopsFurtherCallsInTheSameDictation() async {
        let llm = ThrowingLLM(error: .timeout)
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: twoCorrections), llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        let result = await session.finish()
        XCTAssertEqual(result?.final, "Um drei, nein, um vier. Am Montag, nein, am Dienstag.")
        XCTAssertEqual(result?.summary.llmFailed, true)
        let calls = await llm.log.calls
        XCTAssertEqual(calls, 1)
    }

    func testRejectedAnswerDoesNotStopTheNextSentence() async {
        let llm = ThrowingLLM(error: .rejectedOutput)
        let session = DictationSession(
            transcriber: FakeTranscriber(texts: twoCorrections), llm: llm, style: .neutral, appBundleID: nil)
        await session.addSegment([1])
        await session.addSegment([2])
        _ = await session.finish()
        let calls = await llm.log.calls
        XCTAssertEqual(calls, 2)
    }

    func testBreakerTripsOnlyOnUnavailability() {
        let breaker = LLMCircuitBreaker()
        breaker.record(LLMError.rejectedOutput)
        breaker.record(LLMError.http(500))
        XCTAssertFalse(breaker.isOpen)
        breaker.record(LLMError.unreachable)
        XCTAssertTrue(breaker.isOpen)
    }
}

// MARK: - Privacy

final class PrivacyTests: XCTestCase {
    func testOnlyLoopbackCountsAsLocal() {
        XCTAssertTrue(OllamaClient.Configuration().isLocal)
        XCTAssertTrue(OllamaClient.Configuration.isLocal(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertTrue(OllamaClient.Configuration.isLocal(URL(string: "http://[::1]:11434")!))
        XCTAssertFalse(OllamaClient.Configuration.isLocal(URL(string: "http://192.168.1.20:11434")!))
        XCTAssertFalse(OllamaClient.Configuration.isLocal(URL(string: "https://ollama.example.com")!))
        XCTAssertFalse(OllamaClient.Configuration.isLocal(URL(string: "http://localhost.example.com")!))
        XCTAssertFalse(OllamaClient.Configuration.isLocal(URL(string: "http://127.example.com")!))
    }

    func testHistoryFileIsReadableByOwnerOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: url)
        store.append(DictationResult(
            raw: "a", final: "A.", style: .neutral, appBundleID: nil,
            summary: ChangeSummarizer.summarize(raw: "a", final: "A.", usedLLM: false, llmFailed: false), latency: 0))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

final class OllamaSessionTests: XCTestCase {
    func testClientsShareOneSession() {
        // A session per client would leak its delegate and connection pool.
        let a = Mirror(reflecting: OllamaClient(configuration: .init())).children.first { $0.label == "session" }?.value as? URLSession
        let b = Mirror(reflecting: OllamaClient(configuration: .init())).children.first { $0.label == "session" }?.value as? URLSession
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b)
        XCTAssertTrue(a === OllamaClient.sharedSession)
    }
}
