// CalendarStore.swift - Direct SQLite reader/writer for the per-machine
// `~/.flow42/meet42/calendar.db` file. Owns the `calendar_events` and
// `calendar_sync_state` tables.
//
// Why direct SQLite (vs. shelling out): the meet42 CLI is read-only
// against this DB. The writer (`CalendarSyncService` running inside
// Work42App) keeps the table fresh on EventKit notifications. A
// straight C-API wrapper is ~200 lines and zero new dependencies —
// libsqlite3 is already on every macOS. Mirrors the same
// @MainActor SQLite-wrapper pattern used elsewhere so the surface is
// familiar.
//
// Concurrency: @MainActor. SQLite is fine with a single-thread
// connection. Cross-process safety: WAL mode is set at open time so
// the CLI can read while the app writes without blocking.

import Dispatch
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_CAL = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

@MainActor
public final class CalendarStore {

    public enum StoreError: Error, CustomStringConvertible {
        case openFailed(path: String, code: Int32, message: String)
        case prepareFailed(sql: String, message: String)
        case stepFailed(sql: String, message: String)

        public var description: String {
            switch self {
            case .openFailed(let p, let c, let m):
                return "Couldn't open calendar.db at \(p) (code \(c)): \(m)"
            case .prepareFailed(let sql, let m):
                return "prepare failed for `\(sql)`: \(m)"
            case .stepFailed(let sql, let m):
                return "step failed for `\(sql)`: \(m)"
            }
        }
    }

    // Schema version 3 — T-008.8 split the store. The machine-wide
    // calendar mirror (`calendar_events` + `calendar_sync_state`) stays
    // here; all project-authored tables (ai_schedules + fires + log,
    // event/calendar preferences, meeting_scheduler_fires) moved to the
    // per-project `MeetProjectStore` at
    // `~/.work42/meet42/projects/<slug>/store.db`, dropping the
    // `project_path` column. The bootstrap path is destructive: when the
    // persisted `schema_version` is below `currentSchemaVersion`, we DROP
    // the old project-scoped tables from this DB (clean break — no data
    // migration). The `calendar_events` mirror stays untouched.
    private static let currentSchemaVersion: Int = 3

    private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS calendar_events (
      event_id        TEXT PRIMARY KEY,
      calendar_id     TEXT NOT NULL,
      calendar_title  TEXT,
      source          TEXT,
      title           TEXT,
      notes           TEXT,
      location        TEXT,
      starts_at       TEXT NOT NULL,
      ends_at         TEXT NOT NULL,
      all_day         INTEGER NOT NULL DEFAULT 0,
      organizer       TEXT,
      attendees_json  TEXT,
      status          TEXT,
      url             TEXT,
      meeting_url     TEXT,
      last_modified   TEXT,
      synced_at       TEXT NOT NULL,
      session_id      TEXT,
      session_dir     TEXT,
      prep_fired_at   TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_calendar_events_starts
      ON calendar_events(starts_at);

    CREATE TABLE IF NOT EXISTS calendar_sync_state (
      key   TEXT PRIMARY KEY,
      value TEXT
    );
    """

    public let databasePath: String
    private nonisolated(unsafe) var db: OpaquePointer?

    // Use ISO8601 with fractional seconds throughout. Calendar sync
    // doesn't need sub-millisecond precision but keeping the format
    // consistent across read/write avoids parser drift.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Open (and create + bootstrap if needed) the per-machine
    /// calendar store. Idempotent across processes via WAL.
    public init(databasePath: String = Meet42Paths.calendarDB()) throws {
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
        try wipeStaleProjectTablesIfNeeded()
        try execBlock(Self.schema, label: "schema")
        try migrate()
        try stampSchemaVersion()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Open the store in read-only mode. The meet42 CLI uses this so
    /// running `meet42 list` from a script can't accidentally
    /// initialise an empty DB before Work42App has bootstrapped it.
    public static func openReadOnly(
        databasePath: String = Meet42Paths.calendarDB()
    ) throws -> CalendarStore {
        // We still want bootstrap-on-open semantics for read-only
        // callers — otherwise a fresh machine `meet42 list` would
        // fail with "no such table" before the app first runs.
        return try CalendarStore(databasePath: databasePath)
    }

    // MARK: - Forward-compat migration
    //
    // PRAGMA table_info + additive ALTER TABLE: the safe, idempotent
    // migration pattern we use across every SQLite store in this app
    // (CalendarStore, Task42Core.Schema, etc.). Whenever we add a
    // column we land an additive ALTER here; renames or constraint
    // changes go through a `_new` table + copy.

    /// If the persisted `schema_version` predates the T-008.8 split,
    /// drop the project-authored tables from this machine-wide DB —
    /// they now live in the per-project `MeetProjectStore`. Clean break:
    /// the rows are not migrated forward (see the task brief).
    private func wipeStaleProjectTablesIfNeeded() throws {
        guard let db else { return }
        // calendar_sync_state may not exist yet on a virgin DB.
        let stateExists: Bool = {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_sync_state'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            return sqlite3_step(stmt) == SQLITE_ROW
        }()
        let storedVersion: Int
        if stateExists, let raw = try? rawSyncState("schema_version"), let v = Int(raw) {
            storedVersion = v
        } else {
            storedVersion = 0
        }
        guard storedVersion < Self.currentSchemaVersion else { return }
        let drops = [
            "DROP TABLE IF EXISTS ai_schedules",
            "DROP TABLE IF EXISTS ai_schedule_fires",
            "DROP TABLE IF EXISTS ai_schedule_log",
            "DROP TABLE IF EXISTS event_preferences",
            "DROP TABLE IF EXISTS calendar_preferences",
            "DROP TABLE IF EXISTS meeting_scheduler_fires",
        ]
        for sql in drops {
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    private func rawSyncState(_ key: String) throws -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM calendar_sync_state WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_CAL)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cstr)
    }

    private func stampSchemaVersion() throws {
        try setSyncState("schema_version", value: String(Self.currentSchemaVersion))
    }

    private func migrate() throws {
        // Columns that should exist on `calendar_events`. Order
        // doesn't matter for ALTER TABLE ADD COLUMN.
        let required: [(String, String)] = [
            ("session_id", "TEXT"),
            ("session_dir", "TEXT"),
            ("prep_fired_at", "TEXT"),
            ("meeting_url", "TEXT"),
        ]
        let existing = try queryColumns(table: "calendar_events")
        for (name, type) in required where !existing.contains(name) {
            try execBlock(
                "ALTER TABLE calendar_events ADD COLUMN \(name) \(type)",
                label: "alter-\(name)"
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

    // MARK: - Reads

    /// All events with `starts_at` in `[from, to)`, optionally
    /// filtered by source, sorted by `starts_at` ascending.
    public func events(
        from: Date,
        to: Date,
        source: CalendarEvent.Source? = nil
    ) throws -> [CalendarEvent.Item] {
        var sql = """
            SELECT event_id, calendar_id, calendar_title, source, title,
                   notes, location, starts_at, ends_at, all_day,
                   organizer, attendees_json, status, url, meeting_url,
                   last_modified, synced_at, session_id, session_dir,
                   prep_fired_at
            FROM calendar_events
            WHERE starts_at >= ? AND starts_at < ?
            """
        if source != nil { sql += " AND source = ?" }
        sql += " ORDER BY starts_at ASC"
        let fromIso = Self.iso.string(from: from)
        let toIso = Self.iso.string(from: to)
        return try query(
            sql,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, fromIso, -1, SQLITE_TRANSIENT_CAL)
                sqlite3_bind_text(stmt, 2, toIso, -1, SQLITE_TRANSIENT_CAL)
                if let source {
                    sqlite3_bind_text(
                        stmt, 3, source.rawValue, -1, SQLITE_TRANSIENT_CAL
                    )
                }
            },
            map: rowToItem
        )
    }

    /// One event by id. Returns nil if absent.
    public func event(id: String) throws -> CalendarEvent.Item? {
        let sql = """
            SELECT event_id, calendar_id, calendar_title, source, title,
                   notes, location, starts_at, ends_at, all_day,
                   organizer, attendees_json, status, url, meeting_url,
                   last_modified, synced_at, session_id, session_dir,
                   prep_fired_at
            FROM calendar_events WHERE event_id = ?
            """
        let rows = try query(
            sql,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_CAL)
            },
            map: rowToItem
        )
        return rows.first
    }

    /// The next event with `starts_at >= now`. Returns nil if the
    /// schedule is empty. Convenience for `meet42 next`.
    public func nextUpcoming(reference: Date = Date()) throws -> CalendarEvent.Item? {
        let sql = """
            SELECT event_id, calendar_id, calendar_title, source, title,
                   notes, location, starts_at, ends_at, all_day,
                   organizer, attendees_json, status, url, meeting_url,
                   last_modified, synced_at, session_id, session_dir,
                   prep_fired_at
            FROM calendar_events
            WHERE starts_at >= ? AND (status IS NULL OR status != 'canceled')
            ORDER BY starts_at ASC LIMIT 1
            """
        let iso = Self.iso.string(from: reference)
        let rows = try query(
            sql,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT_CAL)
            },
            map: rowToItem
        )
        return rows.first
    }

    /// Read a sync-state value (e.g. `last_full_sync`).
    public func syncState(_ key: String) throws -> String? {
        let rows: [String] = try query(
            "SELECT value FROM calendar_sync_state WHERE key = ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_CAL)
            },
            map: { stmt in stringColumn(stmt, 0) ?? "" }
        )
        return rows.first
    }

    // MARK: - Writes

    /// Upsert one event row. Called by `CalendarSyncService` per
    /// `EKEvent` in the active window. Preserves `session_id`,
    /// `session_dir`, `prep_fired_at` on update so re-sync doesn't
    /// wipe scheduler bookkeeping.
    public func upsert(_ item: CalendarEvent.Item) throws {
        let sql = """
            INSERT INTO calendar_events
              (event_id, calendar_id, calendar_title, source, title,
               notes, location, starts_at, ends_at, all_day,
               organizer, attendees_json, status, url, meeting_url,
               last_modified, synced_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(event_id) DO UPDATE SET
              calendar_id     = excluded.calendar_id,
              calendar_title  = excluded.calendar_title,
              source          = excluded.source,
              title           = excluded.title,
              notes           = excluded.notes,
              location        = excluded.location,
              starts_at       = excluded.starts_at,
              ends_at         = excluded.ends_at,
              all_day         = excluded.all_day,
              organizer       = excluded.organizer,
              attendees_json  = excluded.attendees_json,
              status          = excluded.status,
              url             = excluded.url,
              meeting_url     = excluded.meeting_url,
              last_modified   = excluded.last_modified,
              synced_at       = excluded.synced_at
            """
        let attendeesJSON = encodeAttendees(item.attendees)
        try exec(sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT_CAL)
            sqlite3_bind_text(stmt, 2, item.calendarId, -1, SQLITE_TRANSIENT_CAL)
            bindOpt(stmt, 3, item.calendarTitle)
            sqlite3_bind_text(stmt, 4, item.source.rawValue, -1, SQLITE_TRANSIENT_CAL)
            sqlite3_bind_text(stmt, 5, item.title, -1, SQLITE_TRANSIENT_CAL)
            bindOpt(stmt, 6, item.notes)
            bindOpt(stmt, 7, item.location)
            sqlite3_bind_text(stmt, 8, Self.iso.string(from: item.startsAt), -1, SQLITE_TRANSIENT_CAL)
            sqlite3_bind_text(stmt, 9, Self.iso.string(from: item.endsAt), -1, SQLITE_TRANSIENT_CAL)
            sqlite3_bind_int(stmt, 10, item.allDay ? 1 : 0)
            bindOpt(stmt, 11, item.organizer)
            bindOpt(stmt, 12, attendeesJSON)
            sqlite3_bind_text(stmt, 13, item.status.rawValue, -1, SQLITE_TRANSIENT_CAL)
            bindOpt(stmt, 14, item.url)
            bindOpt(stmt, 15, item.meetingURL)
            bindOpt(stmt, 16, item.lastModified.map(Self.iso.string(from:)))
            sqlite3_bind_text(stmt, 17, Self.iso.string(from: item.syncedAt), -1, SQLITE_TRANSIENT_CAL)
        })
    }

    /// Replace `calendar_events` for the [from, to) window with
    /// `items` — performs the upserts AND deletes any pre-existing
    /// row in the window whose id isn't in the new set. Used by
    /// `CalendarSyncService.performFullSync` so the table reflects
    /// EventKit cancellations.
    public func replaceWindow(
        from: Date,
        to: Date,
        items: [CalendarEvent.Item]
    ) throws {
        guard let db else { return }
        try exec("BEGIN IMMEDIATE TRANSACTION")
        do {
            for item in items { try upsert(item) }
            // Drop anything in window that wasn't in `items`.
            let keep = items.map { $0.id }
            let placeholders = keep.isEmpty
                ? "''"  // No-op placeholder so the IN list is non-empty.
                : keep.map { _ in "?" }.joined(separator: ",")
            let sql = """
                DELETE FROM calendar_events
                WHERE starts_at >= ? AND starts_at < ?
                  AND event_id NOT IN (\(placeholders))
                """
            try exec(sql, bind: { stmt in
                sqlite3_bind_text(
                    stmt, 1, Self.iso.string(from: from),
                    -1, SQLITE_TRANSIENT_CAL
                )
                sqlite3_bind_text(
                    stmt, 2, Self.iso.string(from: to),
                    -1, SQLITE_TRANSIENT_CAL
                )
                for (idx, id) in keep.enumerated() {
                    sqlite3_bind_text(
                        stmt, Int32(3 + idx), id, -1, SQLITE_TRANSIENT_CAL
                    )
                }
            })
            try exec("COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Calendar preferences

    /// Per-calendar assistance level. The default for any calendar
    /// not present in `calendar_preferences` is `.viewOnly` so a
    /// user landing on a fresh install never gets surprise sessions
    /// from a personal calendar — they have to opt each calendar in.
    public enum CalendarMode: String, Sendable, Codable, Equatable {
        /// Events visible but no auto session minting or agent
        /// engagement. Useful for personal calendars surfaced
        /// alongside a work calendar on a shared machine. Rendered
        /// in the user's blue.
        case viewOnly = "view_only"
        /// Events get full assistance — a session per click, the
        /// agent treats them as in-scope, future prep / transcript
        /// features will fire on them. Rendered in the system
        /// accent color so the user's macOS appearance preference
        /// carries through.
        case assisted = "assisted"
        /// Events the agent scheduled itself — homework blocks,
        /// follow-up reminders, prep windows. Reserved for the
        /// next slice where a separate "AI calendar" lands; the
        /// enum case is here today so the orange tint is wired
        /// through every renderer ahead of that work.
        case aiScheduled = "ai_scheduled"
    }

    /// One row from `calendar_preferences` plus the human-friendly
    /// label the UI uses to render it.
    public struct CalendarChoice: Sendable, Equatable, Identifiable {
        public let calendarId: String
        public let title: String
        public let source: CalendarEvent.Source
        public var mode: CalendarMode
        public var eventCount: Int

        public var id: String { calendarId }

        public init(
            calendarId: String,
            title: String,
            source: CalendarEvent.Source,
            mode: CalendarMode,
            eventCount: Int
        ) {
            self.calendarId = calendarId
            self.title = title
            self.source = source
            self.mode = mode
            self.eventCount = eventCount
        }
    }

    // MARK: - Calendar inventory
    //
    // The per-project assistance preferences (calendar/event modes) and the
    // AI-schedule tables that used to be reached through `projectPath` shims
    // here were work42-coupled (`MeetProjectStore`/`WorkspaceResolver`) and
    // are NOT part of the standalone meet42 domain port (M1/s6). meet42
    // exposes only the machine-wide calendar mirror; per-event/-calendar
    // assist flags live behind the `meet42 modes` verb (s9), on meet42's own
    // store — not this one.

    /// Machine-wide calendar inventory (id, title, source, event count)
    /// derived purely from `calendar_events`. Any per-project assist mode is
    /// layered on by the caller; the mode here is always `.viewOnly`.
    public func calendarChoiceCounts() throws -> [CalendarChoice] {
        let sql = """
            SELECT e.calendar_id,
                   COALESCE(MAX(e.calendar_title), '(Unnamed)'),
                   COALESCE(MAX(e.source), 'other'),
                   COUNT(*) AS event_count
            FROM calendar_events e
            GROUP BY e.calendar_id
            ORDER BY event_count DESC
            """
        return try query(
            sql,
            bind: { _ in },
            map: { stmt in
                let id = stringColumn(stmt, 0) ?? ""
                let title = stringColumn(stmt, 1) ?? "(Unnamed)"
                let sourceRaw = stringColumn(stmt, 2) ?? "other"
                let count = Int(sqlite3_column_int64(stmt, 3))
                return CalendarChoice(
                    calendarId: id,
                    title: title,
                    source: CalendarEvent.Source(rawValue: sourceRaw) ?? .other,
                    mode: .viewOnly,
                    eventCount: count
                )
            }
        )
    }

    /// Set a sync-state value. Used for things like
    /// `last_full_sync`, `last_notification_at`, `access_granted`.
    public func setSyncState(_ key: String, value: String) throws {
        try exec(
            """
            INSERT INTO calendar_sync_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_CAL)
                sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT_CAL)
            }
        )
    }

    // MARK: - Row mapping helpers

    private func rowToItem(_ stmt: OpaquePointer?) -> CalendarEvent.Item {
        let id = stringColumn(stmt, 0) ?? ""
        let calId = stringColumn(stmt, 1) ?? ""
        let calTitle = stringColumn(stmt, 2)
        let sourceRaw = stringColumn(stmt, 3) ?? "other"
        let source = CalendarEvent.Source(rawValue: sourceRaw) ?? .other
        let title = stringColumn(stmt, 4) ?? ""
        let notes = stringColumn(stmt, 5)
        let location = stringColumn(stmt, 6)
        let startsAt = parseDate(stringColumn(stmt, 7)) ?? Date.distantPast
        let endsAt = parseDate(stringColumn(stmt, 8)) ?? startsAt
        let allDay = sqlite3_column_int(stmt, 9) != 0
        let organizer = stringColumn(stmt, 10)
        let attendees = decodeAttendees(stringColumn(stmt, 11))
        let statusRaw = stringColumn(stmt, 12) ?? "none"
        let status = CalendarEvent.Status(rawValue: statusRaw) ?? .none
        let url = stringColumn(stmt, 13)
        let meetingURL = stringColumn(stmt, 14)
        let lastModified = parseDate(stringColumn(stmt, 15))
        let syncedAt = parseDate(stringColumn(stmt, 16)) ?? Date()
        let sessionId = stringColumn(stmt, 17)
        let sessionDir = stringColumn(stmt, 18)
        let prepFiredAt = parseDate(stringColumn(stmt, 19))
        return CalendarEvent.Item(
            id: id,
            calendarId: calId,
            calendarTitle: calTitle,
            source: source,
            title: title,
            notes: notes,
            location: location,
            startsAt: startsAt,
            endsAt: endsAt,
            allDay: allDay,
            organizer: organizer,
            attendees: attendees,
            status: status,
            url: url,
            meetingURL: meetingURL,
            lastModified: lastModified,
            syncedAt: syncedAt,
            sessionId: sessionId,
            sessionDir: sessionDir,
            prepFiredAt: prepFiredAt
        )
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Self.iso.date(from: s)
    }

    private func encodeAttendees(_ attendees: [CalendarEvent.Attendee]) -> String? {
        guard !attendees.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(attendees) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeAttendees(_ json: String?) -> [CalendarEvent.Attendee] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode(
            [CalendarEvent.Attendee].self, from: data
        )) ?? []
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

    @discardableResult
    private func exec(_ sql: String) throws -> Int32 {
        guard let db else { return SQLITE_ERROR }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        if rc != SQLITE_OK && rc != SQLITE_DONE {
            throw StoreError.stepFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(db))
            )
        }
        return rc
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

    // MARK: - Session linkage

    /// Write `session_id` back onto the event row, so `meet42 now`'s `sessionId`
    /// field resolves to the already-minted session for dedup. Idempotent: calling
    /// it again for the same eventId with the same sessionId is harmless (UPDATE
    /// is a no-op when the value matches). Silently no-ops if the eventId is
    /// absent (event was deleted from the mirror since session creation).
    public func linkSession(eventId: String, sessionId: String) throws {
        try exec(
            "UPDATE calendar_events SET session_id = ? WHERE event_id = ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_CAL)
                sqlite3_bind_text(stmt, 2, eventId, -1, SQLITE_TRANSIENT_CAL)
            }
        )
    }

    // MARK: - Meeting prep dedup

    /// Mirror "prep fired" onto `calendar_events.prep_fired_at` so the
    /// UI can show the affordance without a cross-store join. The mirror
    /// is per-machine: the column reflects "some project already fired
    /// prep for this event", not per-project truth (the per-project
    /// `meeting_scheduler_fires` table in `MeetProjectStore` holds that).
    public func markPrepMirror(eventId: String) throws {
        let nowIso = Self.iso.string(from: Date())
        try exec(
            "UPDATE calendar_events SET prep_fired_at = ? WHERE event_id = ?",
            bind: { stmt in
                sqlite3_bind_text(stmt, 1, nowIso, -1, SQLITE_TRANSIENT_CAL)
                sqlite3_bind_text(stmt, 2, eventId, -1, SQLITE_TRANSIENT_CAL)
            }
        )
    }

    // AI-schedule CRUD (createAISchedule/listAISchedules/dueAISchedules/…)
    // was work42-coupled (MeetProjectStore + the `AISchedule` model) and is
    // intentionally NOT part of the standalone meet42 domain port (M1/s6).
    // Schedule FIRING now lives in work42's generic scheduler (F2); meet42
    // reconciles into it via `work42 schedule` (AC5), so meet42 itself holds
    // no AI-schedule tables here.
}

// MARK: - Free helpers

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
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_CAL)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}
