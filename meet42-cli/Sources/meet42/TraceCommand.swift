// TraceCommand.swift — `meet42 trace`: read the pipeline trace log.
//
// Reads ~/.work42/meet42/trace.jsonl (and the rotated .1 file when --tail
// needs more history than the active file contains) and pretty-prints the
// last N events. Optionally filters by callId (--call) and emits raw JSON
// lines instead of the human format (--json).
//
// The env var MEET42_TRACE=0 gates WRITES via Meet42Trace.log; it does NOT
// affect reads — `meet42 trace` always works regardless of that var.

import Foundation
import Meet42Capture

enum TraceCommand {

    static func trace(args: [String]) {
        // --tail N (default 50)
        let tail: Int
        if let s = CLI.argValue(args, "--tail"), let n = Int(s), n > 0 {
            tail = n
        } else {
            tail = 50
        }
        let callFilter = CLI.argValue(args, "--call")
        let wantsJSON  = CLI.wantsJSON(args)

        let path    = tracePath()
        let lines   = readLines(from: path, tail: tail, callFilter: callFilter)

        if lines.isEmpty {
            print("no trace entries yet")
            return
        }

        for line in lines {
            if wantsJSON {
                print(line)
            } else {
                print(humanFormat(line))
            }
        }
    }

    // MARK: - Path

    private static func tracePath() -> String {
        let home = NSHomeDirectory()
        let root = (home as NSString).appendingPathComponent(".work42/meet42")
        return (root as NSString).appendingPathComponent("trace.jsonl")
    }

    // MARK: - Reading

    /// Read up to `tail` lines from the trace file (and the rotated .1 backup
    /// when the active file has fewer lines than requested), then apply the
    /// optional callId filter.
    private static func readLines(
        from path: String,
        tail: Int,
        callFilter: String?
    ) -> [String] {
        let primary = nonEmptyLines(fromFile: path)
        // When there are enough lines in the primary file, skip the .1 backup.
        let combined: [String]
        if primary.count >= tail {
            combined = Array(primary.suffix(tail))
        } else {
            let older = nonEmptyLines(fromFile: path + ".1")
            combined = Array((older + primary).suffix(tail))
        }

        guard let callId = callFilter else { return combined }
        return combined.filter { jsonField($0, "callId") == callId }
    }

    private static func nonEmptyLines(fromFile path: String) -> [String] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return raw
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Formatting

    private static func parsed(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func jsonField(_ line: String, _ key: String) -> String? {
        parsed(line)?[key] as? String
    }

    /// Human-readable one-liner: `<ts> [<src>] <evt> key=val …`
    private static func humanFormat(_ line: String) -> String {
        guard let obj = parsed(line) else { return line }
        let ts  = obj["ts"]  as? String ?? "?"
        let src = obj["src"] as? String ?? "?"
        let evt = obj["evt"] as? String ?? "?"
        let skip = Set(["ts", "pid", "src", "evt"])
        let extras = obj
            .filter { !skip.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = extras.isEmpty ? "" : " \(extras)"
        return "\(ts) [\(src)] \(evt)\(suffix)"
    }
}
