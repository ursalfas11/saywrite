import Foundation

/// Which representations of the user's clipboard are saved before a paste and written back after it.
///
/// All of them, as before round 4: saving only cheap types lost data (an Excel range came back
/// without formulas and formatting, an image copied in Safari as its URL). Reading every type can
/// make apps such as Excel or Photoshop render their formats for a moment; the snapshot is taken
/// early in `TextInserter.prepare()`, while the text is still being prepared, so that wait does not
/// fall on the paste itself. Kept free of AppKit so the rules can be tested.
public enum ClipboardSnapshotRules {
    /// File promises are produced on demand by the source app and cannot be copied.
    public static func isPromise(_ type: String) -> Bool {
        type.lowercased().contains("promise")
    }

    /// The types of one pasteboard item to save, in their original order, or nil when the item cannot
    /// be saved (a file promise): then the clipboard is not restored at all rather than half-restored.
    public static func typesToSave(_ types: [String]) -> [String]? {
        if types.contains(where: isPromise) { return nil }
        return types
    }
}

/// Elapsed time and the auto-stop countdown of a hands-free recording, shown in the panel.
public enum RecordingClock {
    /// "0:42", "9:05", "10:00".
    public static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// Seconds until the recording stops by itself, when that is near enough to show a countdown: the
    /// last minute before the maximum length, the last `silenceWarning` seconds of a long silence.
    public static func countdown(elapsed: TimeInterval, silent: TimeInterval, maximum: TimeInterval,
                                 silenceLimit: TimeInterval, silenceWarning: TimeInterval = 15) -> TimeInterval? {
        let untilMaximum = maximum - elapsed
        let untilSilence = silenceLimit - silent
        var shown: [TimeInterval] = []
        if untilMaximum <= 60 { shown.append(untilMaximum) }
        if untilSilence <= silenceWarning { shown.append(untilSilence) }
        return shown.min().map { max(0, $0) }
    }
}

/// File sizes as Finder shows them ("1.9 GB", "1,9 GB" with a German region).
public enum ByteSize {
    public static func text(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// What the "Original" button does with the version without AI.
public enum OriginalSwap: Equatable, Sendable {
    /// ⌘Z removes the inserted text, then the original is pasted in its place.
    case undoAndPaste
    /// Only put the original on the clipboard: ⌘Z would undo something else.
    case copyOnly

    /// ⌘Z only hits the inserted text in the app that received it, and only while the user has not
    /// typed there since: after typing it would undo the typing instead.
    public static func decide(frontmostApp: String?, insertedInto: String?, keysSinceInsert: Int) -> OriginalSwap {
        guard let insertedInto, frontmostApp == insertedInto, keysSinceInsert == 0 else { return .copyOnly }
        return .undoAndPaste
    }
}

/// Why a rewrite cannot run, known before the user speaks the instruction.
public enum RewriteBlocker: Equatable, Sendable {
    case aiOff
    /// The built-in model is selected but not on this Mac.
    case modelMissing
    /// Secure input may hide a password field: the selection must not reach the AI.
    case secureInput

    public static func check(aiEnabled: Bool, builtinBackend: Bool, modelInstalled: Bool, withholdAI: Bool) -> RewriteBlocker? {
        if !aiEnabled { return .aiOff }
        if builtinBackend && !modelInstalled { return .modelMissing }
        if withholdAI { return .secureInput }
        return nil
    }
}
