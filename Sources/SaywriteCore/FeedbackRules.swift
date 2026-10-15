import Foundation

/// Which representations of the user's clipboard are saved before a paste and written back after it.
///
/// Reading a representation can be expensive: apps such as Excel, Numbers or Photoshop provide most
/// types lazily and render them only when asked, and the read blocks the thread that asks (the main
/// thread, which also serves the hotkey event tap every key press waits for). So only cheap, common
/// types are saved; an expensive one only when an item has nothing else. Kept free of AppKit so the
/// rules can be tested.
public enum ClipboardSnapshotRules {
    /// Plain and rich text, links, file references and PNG: what a paste target usually reads.
    public static let cheapTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text", "public.plain-text",
        "NSStringPboardType", "public.rtf", "NeXT Rich Text Format v1.0 pasteboard type", "public.html",
        "Apple HTML pasteboard type", "public.file-url", "NSFilenamesPboardType", "public.url", "public.url-name",
        "Apple URL pasteboard type", "public.png",
    ]

    /// Markers clipboard managers read (no data worth mentioning); kept so a restored entry keeps them.
    public static func isMarker(_ type: String) -> Bool {
        type.hasPrefix("org.nspasteboard.") || type == "com.apple.is-remote-clipboard"
    }

    /// File promises are produced on demand by the source app and cannot be copied.
    public static func isPromise(_ type: String) -> Bool {
        type.lowercased().contains("promise")
    }

    /// The types of one pasteboard item to save, in their original order, or nil when the item cannot
    /// be saved (a file promise): then the clipboard is not restored at all rather than half-restored.
    public static func typesToSave(_ types: [String]) -> [String]? {
        if types.contains(where: isPromise) { return nil }
        let cheap = types.filter { cheapTypes.contains($0) || isMarker($0) }
        if cheap.contains(where: { !isMarker($0) }) { return cheap }
        // Nothing cheap (an image from Photoshop, a PDF, a table only as a private type): keep the
        // first, richest representation, which is what a paste uses, and leave the alternatives out.
        guard let first = types.first(where: { !isMarker($0) && !$0.hasPrefix("dyn.") })
            ?? types.first(where: { !isMarker($0) }) else { return cheap }
        return cheap + [first]
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
