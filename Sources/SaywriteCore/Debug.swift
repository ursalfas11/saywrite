import Foundation

/// Diagnostic output to stderr, enabled with the environment variable SAYWRITE_DEBUG=1.
public enum Debug {
    public static let enabled = ProcessInfo.processInfo.environment["SAYWRITE_DEBUG"] == "1"

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[saywrite] " + message() + "\n").utf8))
    }
}
