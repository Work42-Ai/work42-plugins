// PeopleStore.swift - SQLite-backed people store for the peers42 graph.
// Owns `~/.work42/peers42/people.db`, the minimal seed for the peers42
// entity-graph. Two tables:
//   `people`          — one row per person (by identity: lowercased email
//                       preferred; normalised name when no email).
//   `person_meetings` — join table recording which meetings each person
//                       appeared in, for `sharedMeetingCount`.
//
// Auto-populated at meeting-session mint from `event.attendees` via
// `upsertAttendees(eventId:attendees:at:)`. The People tile (subtask 14)
// and the end-of-meeting pass (subtask 16) consume `profile(forAttendees:)`.
//
// Both methods work directly with `CalendarEvent.Attendee` because
// PeopleStore lives in the same `Meet42Kit` module (meet42-plugin-conversion,
// M1/s6 — ported from Flow42Core/People, stripped of work42 coupling).
//
// Concurrency: @MainActor, single-thread connection, WAL at open time so
// meet42 CLI readers don't block the app writer. Mirrors the
// CalendarStore direct-libsqlite3 pattern — zero new dependencies, same SQL
// helpers, same additive-migration discipline.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PS = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

// MARK: - PersonProfile

/// A snapshot of one attendee's accumulated profile from `people.db`.
/// Returned by `PeopleStore.profile(forAttendees:)` for the People tile
/// (subtask 14) and the end-of-meeting pass (subtask 16).
///
/// `Codable` with snake_case keys (`person_id`, `shared_meeting_count`,
/// `last_seen`) so `meet42 people --json` can emit it directly.
public struct PersonProfile: Sendable, Equatable, Codable {
    /// Stable identifier — lowercased email, or normalised-name fallback.
    public let personId: String
    /// Display name from the most-recent event that supplied one.
    public let name: String?
    /// Email from the most-recent event that supplied one.
    public let email: String?
    /// Total number of meetings this person has shared with the user.
    public let sharedMeetingCount: Int
    /// ISO 8601 string of the last time this person appeared in an event.
    public let lastSeen: String?

    private enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case name
        case email
        case sharedMeetingCount = "shared_meeting_count"
        case lastSeen = "last_seen"
    }

    public init(
        personId: String,
        name: String?,
        email: String?,
        sharedMeetingCount: Int,
        lastSeen: String?
    ) {
        self.personId = personId
        self.name = name
        self.email = email
        self.sharedMeetingCount = sharedMeetingCount
        self.lastSeen = lastSeen
    }
}

// MARK: - PeopleStore

@MainActor
public final class PeopleStore {

    public enum StoreError: Error, CustomStringConvertible {
        case openFailed(path: String, code: Int32, message: String)
        case prepareFailed(sql: String, message: String)
        case stepFailed(sql: String, message: String)

        public var description: String {
            switch self {
            case .openFailed(let p, let c, let m):
                return "Couldn't open people.db at \(p) (code \(c)): \(m)"
            case .prepareFailed(let sql, let m):
                return "prepare failed for `\(sql)`: \(m)"
            case .stepFailed(let sql, let m):
                return "step failed for `\(sql)`: \(m)"
            }
        }
    }

    // MARK: - Schema

    private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;

    -- One row per unique person. `person_id` is derived from the
    -- attendee's identity at upsert time:
    --   - lowercased email when available (stable across event renames)
    --   - "name:<lowercased, whitespace-collapsed name>" as a fallback
    -- `name` and `email` are overwritten on every upsert so the row
    -- reflects the most-recent version. `first_seen_at` is written once
    -- (INSERT … ON CONFLICT DO UPDATE preserves it by not touching it).
    -- `last_seen_at` is always bumped to the latest upsert timestamp.
    CREATE TABLE IF NOT EXISTS people (
      person_id      TEXT PRIMARY KEY,
      name           TEXT,
      email          TEXT,
      first_seen_at  TEXT NOT NULL,
      last_seen_at   TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_people_email
      ON people(email) WHERE email IS NOT NULL;

    -- Join table: which meetings each person appeared in.
    -- Dedup key is (person_id, event_id) — upsert is idempotent.
    CREATE TABLE IF NOT EXISTS person_meetings (
      person_id    TEXT NOT NULL,
      event_id     TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      PRIMARY KEY (person_id, event_id)
    );
    CREATE INDEX IF NOT EXISTS idx_person_meetings_event
      ON person_meetings(event_id);
    CREATE INDEX IF NOT EXISTS idx_person_meetings_person
      ON person_meetings(person_id);
    """

    // MARK: - Open

    /// Default path: `~/.work42/peers42/people.db`.
    public static func defaultPath() -> String {
        let root = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".work42/peers42")
        return (root as NSString).appendingPathComponent("people.db")
    }

    public let databasePath: String
    private nonisolated(unsafe) var db: OpaquePointer?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Open (and create + bootstrap if needed) the people store.
    /// Creates the `peers42` directory if it does not yet exist.
    /// Idempotent across processes via WAL.
    public init(databasePath: String = PeopleStore.defaultPath()) throws {
        self.databasePath = databasePath
        let parent = (databasePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(databasePath, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw StoreError.openFailed(
                path: databasePath, code: rc, message: msg
            )
        }
        self.db = handle
        _ = sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil)
        try execBlock(Self.schema, label: "schema")
        try migrate()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Migration

    /// Additive-migration guard. Add any new columns here; never rename or
    /// remove (use a `_new` table + copy for destructive changes).
    private func migrate() throws {
        let peopleRequired: [(String, String)] = [
            ("name", "TEXT"),
            ("email", "TEXT"),
            ("first_seen_at", "TEXT"),
            ("last_seen_at", "TEXT"),
        ]
        let existingPeople = try queryColumns(table: "people")
        for (name, type) in peopleRequired where !existingPeople.contains(name) {
            try execBlock(
                "ALTER TABLE people ADD COLUMN \(name) \(type)",
                label: "alter-people-\(name)"
            )
        }

        let meetingsRequired: [(String, String)] = [
            ("last_seen_at", "TEXT"),
        ]
        let existingMeetings = try queryColumns(table: "person_meetings")
        for (name, type) in meetingsRequired where !existingMeetings.contains(name) {
            try execBlock(
                "ALTER TABLE person_meetings ADD COLUMN \(name) \(type)",
                label: "alter-person_meetings-\(name)"
            )
        }
    }

    private func queryColumns(table: String) throws -> Set<String> {
        let rows: [String] = try query(
            "PRAGMA table_info(\(table))",
            bind: { _ in },
            map: { stmt in stringColumn(stmt, 1) ?? "" }
        )
        return Set(rows.filter { !$0.isEmpty })
    }

    // MARK: - person_id derivation

    /// Derive a stable `person_id` for an attendee.
    /// - Prefers lowercased email (survives event renames).
    /// - Falls back to `"name:<lowercased, whitespace-collapsed name>"`.
    /// - Returns `nil` when both name and email are absent/blank.
    public static func personId(name: String?, email: String?) -> String? {
        if let email,
           !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return email.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let collapsed = name
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "name:\(collapsed)"
        }
        return nil
    }

    // MARK: - Writes

    /// Upsert attendees for a meeting event into `people` and
    /// `person_meetings`. For each attendee:
    ///   - Derives `person_id` (email-preferred).
    ///   - Inserts into `people` with `first_seen_at = at`; on conflict
    ///     updates `name`, `email`, and `last_seen_at` (first_seen_at
    ///     is preserved by not including it in the UPDATE SET clause).
    ///   - Upserts `person_meetings` (person_id, event_id, last_seen_at).
    ///
    /// Called from the registered Event Session seeder after
    /// `meeting.json` is written, so every session mint seeds the store.
    /// Skips attendees whose `person_id` cannot be derived (no name/email).
    /// Does NOT insert a row for the current user (`isCurrentUser == true`).
    public func upsertAttendees(
        eventId: String,
        attendees: [CalendarEvent.Attendee],
        at date: Date
    ) throws {
        guard let db else { return }
        let nowIso = Self.iso.string(from: date)

        try execRaw("BEGIN IMMEDIATE TRANSACTION")
        do {
            for attendee in attendees where !attendee.isCurrentUser {
                guard let pid = Self.personId(
                    name: attendee.name,
                    email: attendee.email
                ) else { continue }

                // people upsert: preserve first_seen_at; refresh all others.
                let peopleSql = """
                    INSERT INTO people
                      (person_id, name, email, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(person_id) DO UPDATE SET
                      name         = excluded.name,
                      email        = excluded.email,
                      last_seen_at = excluded.last_seen_at
                    """
                try exec(peopleSql, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, pid, -1, SQLITE_TRANSIENT_PS)
                    bindOpt(stmt, 2, attendee.name)
                    bindOpt(stmt, 3, attendee.email)
                    sqlite3_bind_text(stmt, 4, nowIso, -1, SQLITE_TRANSIENT_PS)
                    sqlite3_bind_text(stmt, 5, nowIso, -1, SQLITE_TRANSIENT_PS)
                })

                // person_meetings upsert: dedup by (person_id, event_id).
                let meetingSql = """
                    INSERT INTO person_meetings
                      (person_id, event_id, last_seen_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(person_id, event_id) DO UPDATE SET
                      last_seen_at = excluded.last_seen_at
                    """
                try exec(meetingSql, bind: { stmt in
                    sqlite3_bind_text(stmt, 1, pid, -1, SQLITE_TRANSIENT_PS)
                    sqlite3_bind_text(stmt, 2, eventId, -1, SQLITE_TRANSIENT_PS)
                    sqlite3_bind_text(stmt, 3, nowIso, -1, SQLITE_TRANSIENT_PS)
                })
            }
            try execRaw("COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Reads

    /// Per-attendee accumulated profile for a list of `CalendarEvent.Attendee`s.
    /// Returns one `PersonProfile` per attendee whose `person_id` can be
    /// derived. Order mirrors the input attendees list. Attendees with no
    /// resolvable `person_id` are silently omitted.
    ///
    /// Used by the People tile (subtask 14) and the end-of-meeting pass
    /// (subtask 16) to surface name, email, shared-meeting count, last-seen.
    public func profile(
        forAttendees attendees: [CalendarEvent.Attendee]
    ) throws -> [PersonProfile] {
        var results: [PersonProfile] = []
        for attendee in attendees {
            guard let pid = Self.personId(
                name: attendee.name,
                email: attendee.email
            ) else { continue }

            let sql = """
                SELECT p.person_id,
                       p.name,
                       p.email,
                       COUNT(pm.event_id) AS shared_meeting_count,
                       p.last_seen_at
                FROM people p
                LEFT JOIN person_meetings pm ON pm.person_id = p.person_id
                WHERE p.person_id = ?
                GROUP BY p.person_id
                """
            let rows: [PersonProfile] = try query(
                sql,
                bind: { stmt in
                    sqlite3_bind_text(stmt, 1, pid, -1, SQLITE_TRANSIENT_PS)
                },
                map: { stmt -> PersonProfile in
                    PersonProfile(
                        personId: stringColumn(stmt, 0) ?? pid,
                        name: stringColumn(stmt, 1),
                        email: stringColumn(stmt, 2),
                        sharedMeetingCount: Int(sqlite3_column_int64(stmt, 3)),
                        lastSeen: stringColumn(stmt, 4)
                    )
                }
            )
            if let profile = rows.first {
                results.append(profile)
            } else {
                // Person not yet in DB — zero-count placeholder so the
                // tile can still display the attendee.
                results.append(PersonProfile(
                    personId: pid,
                    name: attendee.name,
                    email: attendee.email,
                    sharedMeetingCount: 0,
                    lastSeen: nil
                ))
            }
        }
        return results
    }

    /// All profiles from `people`, ordered by `last_seen_at` descending.
    /// Convenience for debugging / future CLI verbs (e.g. `meet42 people`).
    public func allPeople() throws -> [PersonProfile] {
        let sql = """
            SELECT p.person_id,
                   p.name,
                   p.email,
                   COUNT(pm.event_id) AS shared_meeting_count,
                   p.last_seen_at
            FROM people p
            LEFT JOIN person_meetings pm ON pm.person_id = p.person_id
            GROUP BY p.person_id
            ORDER BY p.last_seen_at DESC
            """
        return try query(sql, bind: { _ in }, map: { stmt -> PersonProfile in
            PersonProfile(
                personId: stringColumn(stmt, 0) ?? "",
                name: stringColumn(stmt, 1),
                email: stringColumn(stmt, 2),
                sharedMeetingCount: Int(sqlite3_column_int64(stmt, 3)),
                lastSeen: stringColumn(stmt, 4)
            )
        })
    }

    // MARK: - Generic SQL helpers

    private func query<T>(
        _ sql: String,
        bind: (OpaquePointer?) -> Void,
        map: (OpaquePointer?) -> T
    ) throws -> [T] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(map(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StoreError.stepFailed(
                    sql: sql, message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
        return rows
    }

    private func exec(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    @discardableResult
    private func execRaw(_ sql: String) throws -> Int32 {
        guard let db else { return SQLITE_ERROR }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK && rc != SQLITE_DONE {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        return rc
    }

    private func execBlock(_ sql: String, label: String) throws {
        guard let db else { return }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        let msg = errmsg.map { String(cString: $0) } ?? "(no message)"
        sqlite3_free(errmsg)
        if rc != SQLITE_OK {
            throw StoreError.stepFailed(
                sql: "[\(label)] \(sql.prefix(80))…", message: msg
            )
        }
    }
}

// MARK: - File-private SQL helpers

@MainActor
private func stringColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}

@MainActor
private func bindOpt(
    _ stmt: OpaquePointer?, _ idx: Int32, _ value: String?
) {
    if let value {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_PS)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}
