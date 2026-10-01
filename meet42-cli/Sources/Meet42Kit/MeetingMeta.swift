// MeetingMeta.swift - Snapshot of the EventKit event a session was
// minted around. Persisted to `<session.ownerDir>/meeting.json` next
// to ChatSession's `meta.json` so the session detail panel can
// render an Event Details widget without re-reading the calendar
// store on every refresh.
//
// We snapshot deliberately: EventKit events can vanish (organizer
// cancels, account is removed) but the conversation that happened
// around them shouldn't lose its context. The snapshot is what we
// rebuild the widget from when EventKit no longer has the event.
// When the event IS still present and live, `CalendarSyncService`
// can rewrite this file on every sync so the widget stays in sync
// with the latest title / time / attendees.

import Foundation

public nonisolated enum MeetingMeta {

    /// What lands in `meeting.json`. Mirrors `CalendarEvent.Item`
    /// because we already have a Codable shape for it; the wrapper
    /// gives us room to add session-only fields later (e.g. user
    /// notes scribbled before the meeting) without bending the
    /// canonical `CalendarEvent.Item` shape.
    public struct File: Sendable, Codable, Equatable {
        public let event: CalendarEvent.Item
        /// ISO 8601 — when this snapshot was last written. Lets the
        /// widget show "synced 12s ago" without consulting the
        /// calendar.db.
        public let snapshotAt: String

        public init(event: CalendarEvent.Item, snapshotAt: String) {
            self.event = event
            self.snapshotAt = snapshotAt
        }
    }

    /// Snapshot path inside a session directory. One snapshot per
    /// session — sibling to `transcript.jsonl` / `meta.json`.
    public static func path(sessionDir: String) -> String {
        (sessionDir as NSString).appendingPathComponent("meeting.json")
    }

    public static func read(sessionDir: String) -> File? {
        let p = path(sessionDir: sessionDir)
        guard FileManager.default.fileExists(atPath: p),
              let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    public static func write(_ file: File, sessionDir: String) throws {
        try FileManager.default.createDirectory(
            atPath: sessionDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(
            to: URL(fileURLWithPath: path(sessionDir: sessionDir)),
            options: .atomic
        )
    }
}
