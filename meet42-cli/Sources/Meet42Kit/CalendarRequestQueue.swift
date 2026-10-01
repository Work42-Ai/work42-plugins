// CalendarRequestQueue.swift - File-based RPC between the meet42 CLI
// (any process) and Work42App's CalendarSyncService /
// MeetingScheduler (the only writer for these resources).
//
// Why a request queue (vs a socket or XPC): zero new infrastructure,
// matches the rest of the codebase's "drop a file, watch a dir"
// pattern (state.json, input.jsonl, agent-input.jsonl). The CLI
// drops a request file, the app picks it up via an mtime poll on
// the requests directory and acts. Requests are idempotent — a
// duplicate request file does no harm. Pickup deletes the file.
//
// Path: `~/.flow42/meet42/requests/<uuid>.json`. The app watches the
// directory and processes any file with a recognised `verb`.

import Foundation

public nonisolated enum CalendarRequest {

    public enum Verb: String, Sendable, Codable {
        case sync                 // force CalendarSyncService.performFullSync
        case aiScheduleChanged    // AI Scheduler row inserted/updated/deleted; reconcile timers
    }

    public struct Envelope: Sendable, Codable {
        public let id: UUID
        public let verb: Verb
        public let eventId: String?
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            verb: Verb,
            eventId: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.verb = verb
            self.eventId = eventId
            self.createdAt = createdAt
        }
    }

    /// Directory the app watches for incoming requests.
    public static func directory() -> String {
        (Meet42Paths.meet42Root() as NSString)
            .appendingPathComponent("requests")
    }

    /// Drop a request file. Returns the absolute path of the dropped
    /// file so callers can wait for its removal if they want
    /// confirmation that the app picked it up.
    @discardableResult
    public static func enqueue(_ envelope: Envelope) throws -> String {
        let dir = directory()
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys, .withoutEscapingSlashes, .prettyPrinted,
        ]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let path = (dir as NSString)
            .appendingPathComponent("\(envelope.id.uuidString).json")
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// Drain every queued request, oldest first. Atomically removes
    /// each file before returning the parsed envelope so a partial
    /// crash mid-processing doesn't replay actions.
    public static func drain() -> [Envelope] {
        let dir = directory()
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: dir) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Envelope] = []
        for name in entries.sorted() where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = try? Data(
                contentsOf: URL(fileURLWithPath: path)
            ) else { continue }
            // Remove before parsing — a malformed file is dropped
            // rather than replayed forever.
            try? FileManager.default.removeItem(atPath: path)
            if let env = try? decoder.decode(Envelope.self, from: data) {
                out.append(env)
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }
}
