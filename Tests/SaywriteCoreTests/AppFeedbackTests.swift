import XCTest
@testable import SaywriteCore

/// Feedback, pasting and settings (round 4): the testable rules behind the app changes.
final class AppFeedbackTests: XCTestCase {
    override func tearDown() { UILanguage.override = nil }

    // MARK: Clipboard snapshot (ux-07)

    // Every representation is saved again, as on main: keeping only cheap types lost the formulas and
    // formatting of an Excel range and turned an image copied in Safari into its URL. The cost of
    // reading them falls into prepare(), while the text is still being prepared.
    func testEveryRepresentationIsSaved() {
        let excel = ["public.utf8-plain-text", "com.microsoft.Excel.sheet", "public.html", "org.nspasteboard.source"]
        XCTAssertEqual(ClipboardSnapshotRules.typesToSave(excel), excel)
        let safariImage = ["public.tiff", "public.png", "public.url", "public.url-name"]
        XCTAssertEqual(ClipboardSnapshotRules.typesToSave(safariImage), safariImage)
        XCTAssertEqual(ClipboardSnapshotRules.typesToSave(["dyn.ah62d4rv4gu8y", "com.adobe.pdf"]), ["dyn.ah62d4rv4gu8y", "com.adobe.pdf"])
    }

    func testFilePromiseCannotBeSaved() {
        XCTAssertNil(ClipboardSnapshotRules.typesToSave(["com.apple.pasteboard.promised-file-url", "public.utf8-plain-text"]))
        XCTAssertNil(ClipboardSnapshotRules.typesToSave(["com.apple.NSFilePromiseItemMetaData"]))
    }

    func testEmptyAndMarkerOnlyItems() {
        XCTAssertEqual(ClipboardSnapshotRules.typesToSave([]), [])
        XCTAssertEqual(ClipboardSnapshotRules.typesToSave(["org.nspasteboard.TransientType"]), ["org.nspasteboard.TransientType"])
    }

    // MARK: Recording clock (ux-09, ux-12)

    func testClockText() {
        XCTAssertEqual(RecordingClock.text(0), "0:00")
        XCTAssertEqual(RecordingClock.text(42.9), "0:42")
        XCTAssertEqual(RecordingClock.text(545), "9:05")
        XCTAssertEqual(RecordingClock.text(600), "10:00")
        XCTAssertEqual(RecordingClock.text(-3), "0:00")
    }

    func testCountdownStartsInTheLastMinuteOrNearTheSilenceLimit() {
        XCTAssertNil(RecordingClock.countdown(elapsed: 120, silent: 5, maximum: 600, silenceLimit: 60))
        XCTAssertNil(RecordingClock.countdown(elapsed: 539, silent: 0, maximum: 600, silenceLimit: 60))
        XCTAssertEqual(RecordingClock.countdown(elapsed: 540, silent: 0, maximum: 600, silenceLimit: 60), 60)
        XCTAssertEqual(RecordingClock.countdown(elapsed: 200, silent: 50, maximum: 600, silenceLimit: 60), 10)
        // Whichever stop comes first.
        XCTAssertEqual(RecordingClock.countdown(elapsed: 590, silent: 55, maximum: 600, silenceLimit: 60), 5)
        XCTAssertEqual(RecordingClock.countdown(elapsed: 605, silent: 0, maximum: 600, silenceLimit: 60), 0)
    }

    // MARK: "Original" (ux-16)

    func testOriginalUndoesOnlyWhenNothingWasTypedInTheSameApp() {
        XCTAssertEqual(OriginalSwap.decide(frontmostApp: "com.apple.TextEdit", insertedInto: "com.apple.TextEdit", keysSinceInsert: 0), .undoAndPaste)
        XCTAssertEqual(OriginalSwap.decide(frontmostApp: "com.apple.TextEdit", insertedInto: "com.apple.TextEdit", keysSinceInsert: 3), .copyOnly)
        XCTAssertEqual(OriginalSwap.decide(frontmostApp: "com.apple.mail", insertedInto: "com.apple.TextEdit", keysSinceInsert: 0), .copyOnly)
        XCTAssertEqual(OriginalSwap.decide(frontmostApp: nil, insertedInto: nil, keysSinceInsert: 0), .copyOnly)
    }

    // MARK: Rewrite readiness (ux-15)

    func testRewriteBlockers() {
        XCTAssertEqual(RewriteBlocker.check(aiEnabled: false, builtinBackend: true, modelInstalled: true, withholdAI: false), .aiOff)
        XCTAssertEqual(RewriteBlocker.check(aiEnabled: true, builtinBackend: true, modelInstalled: false, withholdAI: false), .modelMissing)
        XCTAssertNil(RewriteBlocker.check(aiEnabled: true, builtinBackend: false, modelInstalled: false, withholdAI: false))
        XCTAssertEqual(RewriteBlocker.check(aiEnabled: true, builtinBackend: false, modelInstalled: false, withholdAI: true), .secureInput)
        XCTAssertNil(RewriteBlocker.check(aiEnabled: true, builtinBackend: true, modelInstalled: true, withholdAI: false))
    }

    // MARK: History (ux-22)

    func testRemoveDeletesOneEntryAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: file)
        let first = DictationResult(raw: "first note", final: "First note.", style: .neutral, appBundleID: nil,
                                    summary: ChangeSummary(), latency: 0.4)
        let second = DictationResult(raw: "second note", final: "Second note.", style: .neutral, appBundleID: nil,
                                     summary: ChangeSummary(), latency: 0.4)
        store.append(first)
        store.append(second)
        XCTAssertTrue(store.remove(id: first.id))
        XCTAssertFalse(store.remove(id: first.id))
        XCTAssertEqual(store.items.map(\.final), ["Second note."])
        XCTAssertEqual(HistoryStore(fileURL: file).items.map(\.id), [second.id])
    }

    // MARK: Download texts (ux-20)

    func testDownloadErrorsAreLocalized() {
        UILanguage.override = true
        XCTAssertEqual(ModelDownloadError.incomplete.localizedDescription, "Der Download wurde unterbrochen")
        XCTAssertTrue(ModelDownloadError.notEnoughDiskSpace(needed: 2_000_000_000, available: 500_000_000)
            .localizedDescription.hasPrefix("Nicht genug Speicherplatz"))
        UILanguage.override = false
        XCTAssertEqual(ModelDownloadError.hashMismatch.localizedDescription, "The downloaded file is corrupted")
    }

    func testByteSizeUsesGigabytes() {
        let text = ByteSize.text(1_930_000_000)
        XCTAssertTrue(text.contains("GB"), text)
        XCTAssertTrue(text.hasPrefix("1"), text)
    }
}
