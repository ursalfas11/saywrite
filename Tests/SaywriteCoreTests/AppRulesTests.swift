import XCTest
@testable import SaywriteCore

/// Decision logic behind the app target (secure input, selection drift, history, Ollama address).
final class AppRulesTests: XCTestCase {
    func testSecureInputElsewhereDoesNotDiscardTheText() {
        // Terminal's Secure Keyboard Entry is on, the focus is an ordinary text field: paste.
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: false, secureInputEnabled: true, target: .textField), .proceed)
        // Focus unknown (terminal prompt, bare browser): keep the text on the clipboard.
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: false, secureInputEnabled: true, target: .blind), .copyOnly)
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: false, secureInputEnabled: true, target: .none), .copyOnly)
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: false, secureInputEnabled: false, target: .blind), .proceed)
    }

    func testRealPasswordFieldIsStillBlocked() {
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: true, secureInputEnabled: false, target: .none), .secureField)
        XCTAssertEqual(SecureInputRules.decide(elementIsSecure: true, secureInputEnabled: true, target: .textField), .secureField)
    }

    func testRewriteOnlyReplacesTheCapturedSelection() {
        XCTAssertTrue(PasteTargetRules.rewriteMayReplace(captured: "Hallo Welt", current: .text("Hallo Welt")))
        XCTAssertFalse(PasteTargetRules.rewriteMayReplace(captured: "Hallo Welt", current: .text("Anderer Satz")))
        XCTAssertFalse(PasteTargetRules.rewriteMayReplace(captured: "Hallo Welt", current: .empty))
        XCTAssertTrue(PasteTargetRules.rewriteMayReplace(captured: "Hallo Welt", current: .unavailable))
    }

    func testManualAccessibilityForChromiumAndElectron() {
        XCTAssertTrue(PasteTargetRules.shouldEnableManualAccessibility(bundleID: "com.google.Chrome", isElectron: false))
        XCTAssertTrue(PasteTargetRules.shouldEnableManualAccessibility(bundleID: "com.example.App", isElectron: true))
        XCTAssertFalse(PasteTargetRules.shouldEnableManualAccessibility(bundleID: "com.apple.mail", isElectron: false))
    }

    func testSecureFieldMayBeInvisible() {
        XCTAssertTrue(PasteTargetRules.secureFieldMayBeInvisible(bundleID: "com.apple.Terminal", isElectron: false))
        XCTAssertTrue(PasteTargetRules.secureFieldMayBeInvisible(bundleID: "com.google.Chrome", isElectron: false))
        XCTAssertFalse(PasteTargetRules.secureFieldMayBeInvisible(bundleID: "com.apple.mail", isElectron: false))
    }

    func testRewriteHistoryKeepsNoSelection() {
        XCTAssertEqual(HistoryStore.rewriteRaw(instruction: "kürzer"), "[kürzer]")
    }

    func testHistoryDropsOldEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        let now = Date()
        let summary = ChangeSummarizer.summarize(raw: "a", final: "a", usedLLM: false, llmFailed: false)
        store.append(DictationResult(date: now.addingTimeInterval(-3 * 86_400), raw: "alt", final: "alt", style: .neutral, appBundleID: nil, summary: summary, latency: 0))
        store.append(DictationResult(date: now, raw: "neu", final: "neu", style: .neutral, appBundleID: nil, summary: summary, latency: 0))
        store.removeOlder(than: 86_400, now: now)
        XCTAssertEqual(store.items.map(\.final), ["neu"])
        XCTAssertEqual(HistoryStore(fileURL: url).items.map(\.final), ["neu"])
    }

    func testOllamaAddressValidation() {
        XCTAssertEqual(OllamaEndpoint.parse("http://localhost:11434")?.host, "localhost")
        XCTAssertEqual(OllamaEndpoint.parse("localhost:11434")?.absoluteString, "http://localhost:11434")
        XCTAssertEqual(OllamaEndpoint.parse("  http://10.0.0.5:11434 \n")?.host, "10.0.0.5")
        XCTAssertEqual(OllamaEndpoint.parse("https://ollama.example.com")?.scheme, "https")
        XCTAssertNil(OllamaEndpoint.parse(""))
        XCTAssertNil(OllamaEndpoint.parse("ftp://example.com"))
        XCTAssertNil(OllamaEndpoint.parse("http://"))
        // The scheme-less form of the local default now counts as local.
        XCTAssertTrue(OllamaClient.Configuration.isLocal(OllamaEndpoint.parse("localhost:11434")!))
    }

    func testRedirectsStayOnTheSameHost() {
        let a = URL(string: "http://10.0.0.5:11434/api/chat")
        XCTAssertTrue(SameHostRedirects.allows(from: a, to: URL(string: "http://10.0.0.5:11434/other")))
        XCTAssertFalse(SameHostRedirects.allows(from: a, to: URL(string: "http://evil.example.com/x")))
        XCTAssertFalse(SameHostRedirects.allows(from: URL(string: "https://a.example.com/x"), to: URL(string: "http://a.example.com/x")))
    }
}
