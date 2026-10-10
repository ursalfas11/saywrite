import Foundation

/// Diagnostic output to stderr, enabled with the environment variable SAYWRITE_DEBUG=1.
/// Dictated text is left out of it (only its length); SAYWRITE_DEBUG_TEXT=1 adds the text, so a log
/// that is passed on or redirected to a file does not carry private dictations by default.
public enum Debug {
    public static let enabled = ProcessInfo.processInfo.environment["SAYWRITE_DEBUG"] == "1"
    public static let textEnabled = ProcessInfo.processInfo.environment["SAYWRITE_DEBUG_TEXT"] == "1"

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[saywrite] " + message() + "\n").utf8))
    }

    /// Dictated text for a log line: the text itself only with SAYWRITE_DEBUG_TEXT=1.
    public static func text(_ text: String) -> String {
        textEnabled ? text : "<\(text.count) chars>"
    }
}
