// Meet42Trace.swift — shared pipeline trace helper for meet42.
//
// Appends one structured JSON line per event to ~/.work42/meet42/trace.jsonl.
// All writes use O_APPEND for cross-process atomicity (small writes), are
// best-effort (never throws, never blocks), and are size-rotated at 5 MB.
// Gated: set MEET42_TRACE=0 to disable all writes (reads via `meet42 trace`
// are unaffected by the gate).

import Foundation
import Meet42Kit

public enum Meet42Trace {

    // MARK: - Configuration

    private static let maxBytes = 5 * 1024 * 1024  // 5 MB

    private static let tracePath: String = {
        (Meet42Paths.meet42Root() as NSString).appendingPathComponent("trace.jsonl")
    }()

    // MARK: - Public API

    /// Append one JSON-line trace event.
    ///
    /// - Parameters:
    ///   - src:    Which component is logging, e.g. "watch", "detect", "record".
    ///   - evt:    The event name, e.g. "call-open", "start-claimed".
    ///   - fields: Optional extra fields merged into the row (callId, app, …).
    public nonisolated static func log(
        _ src: String,
        _ evt: String,
        _ fields: [String: Any] = [:]
    ) {
        // Honor the kill-switch.
        guard ProcessInfo.processInfo.environment["MEET42_TRACE"] != "0" else { return }

        var row = fields
        row["ts"]  = iso8601Now()
        row["pid"] = Int(getpid())
        row["src"] = src
        row["evt"] = evt

        guard let data = try? JSONSerialization.data(withJSONObject: row,
                                                      options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let path = tracePath
        rotateIfNeeded(path: path)
        appendAtomically(line, to: path)
    }

    // MARK: - Internals

    private nonisolated static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private nonisolated static func rotateIfNeeded(path: String) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              size > maxBytes else { return }
        // rename(2) overwrites an existing .1 atomically.
        rename(path, path + ".1")
    }

    private nonisolated static func appendAtomically(_ line: String, to path: String) {
        // Ensure the parent directory exists before opening the file.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        // O_APPEND|O_CREAT|O_WRONLY: the kernel guarantees the offset is set to
        // end-of-file before every write(2), making small appends atomic across
        // processes (POSIX §2.9.7). Do NOT use FileHandle.seekToEndOfFile which
        // races across processes.
        let fd = open(path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }
}
