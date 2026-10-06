// Log.swift — local logging shim for the Meet42Capture target.
//
// The capture engine was ported from Flow42Core / Work42App, where it logged
// through `Flow42Core`'s `Log` enum (debug/info/warn/error, all writing to
// stderr). This standalone package has NO dependency on Flow42Core, so this
// file provides a drop-in `Log` with the SAME API surface the ported call
// sites use, writing to stderr with a `[meet42:capture]` prefix.
//
// stdout is deliberately left untouched — it is reserved for CLI protocol
// output. All diagnostics go to stderr. Never use print().

import Foundation

/// Log levels ordered by severity.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    public nonisolated static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    nonisolated var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }
}

/// Structured logger that always writes to stderr. API-compatible drop-in for
/// Flow42Core's `Log` so the ported capture sources compile unchanged.
public enum Log {
    /// Minimum level to output. Set to .debug for verbose, .info for normal.
    public nonisolated(unsafe) static var minimumLevel: LogLevel = .info

    public nonisolated static func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public nonisolated static func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public nonisolated static func warn(_ message: @autoclosure () -> String) {
        log(.warn, message())
    }

    public nonisolated static func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    private nonisolated static func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] [meet42:capture] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
