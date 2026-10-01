// DataCommands.swift — snapshot / people / modes verbs. These bridge the
// calendar mirror into the per-session meeting.json snapshot, the people
// graph (peers42), and the per-calendar/-event assistance flags.

import Foundation
import Meet42Kit

@MainActor
enum DataCommands {

    // MARK: - snapshot <eventId> --session-dir <dir>

    private struct SnapshotResult: Encodable {
        let event_id: String
        let session_dir: String
        let meeting_json: String
        let attendees_upserted: Int
        let snapshot_at: String
    }

    static func snapshot(args: [String]) {
        guard let eventId = CLI.firstPositional(args) else {
            CLI.fail("meet42 snapshot: missing <eventId>")
        }
        guard let sessionDir = CLI.argValue(args, "--session-dir") else {
            CLI.fail("meet42 snapshot: missing --session-dir <dir>")
        }
        let store = CLI.openReadOnlyStore()
        let event: CalendarEvent.Item?
        do {
            event = try store.event(id: eventId)
        } catch {
            CLI.fail("meet42 snapshot: query failed: \(error)", code: 2)
        }
        // Fail loud on an unknown event id (nonzero exit).
        guard let event else {
            CLI.fail("meet42 snapshot: no event matches '\(eventId)'.")
        }

        let snapshotAt = CLI.nowISO()
        do {
            try MeetingMeta.write(
                MeetingMeta.File(event: event, snapshotAt: snapshotAt),
                sessionDir: sessionDir
            )
        } catch {
            CLI.fail("meet42 snapshot: failed to write meeting.json: \(error)", code: 2)
        }

        let upserted: Int
        do {
            let people = try PeopleStore()
            try people.upsertAttendees(
                eventId: event.id, attendees: event.attendees, at: Date()
            )
            upserted = event.attendees.filter { !$0.isCurrentUser }.count
        } catch {
            CLI.fail("meet42 snapshot: failed to upsert attendees: \(error)", code: 2)
        }

        let result = SnapshotResult(
            event_id: event.id,
            session_dir: sessionDir,
            meeting_json: MeetingMeta.path(sessionDir: sessionDir),
            attendees_upserted: upserted,
            snapshot_at: snapshotAt
        )
        if CLI.wantsJSON(args) {
            CLI.emitJSON(result)
        } else {
            print("Snapshotted event \(event.id) → \(result.meeting_json)")
            print("Upserted \(upserted) attendee(s) into the people graph.")
        }
    }

    // MARK: - people (--session-dir <dir> | --meeting-json <path>)

    static func people(args: [String]) {
        let file: MeetingMeta.File
        if let sessionDir = CLI.argValue(args, "--session-dir") {
            guard let loaded = MeetingMeta.read(sessionDir: sessionDir) else {
                CLI.fail("meet42 people: no meeting.json under session dir '\(sessionDir)'.")
            }
            file = loaded
        } else if let path = CLI.argValue(args, "--meeting-json") {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                CLI.fail("meet42 people: couldn't read meeting-json at '\(path)'.")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let loaded = try? decoder.decode(MeetingMeta.File.self, from: data) else {
                CLI.fail("meet42 people: couldn't decode meeting.json at '\(path)'.")
            }
            file = loaded
        } else {
            CLI.fail("meet42 people: pass --session-dir <dir> or --meeting-json <path>.")
        }

        let profiles: [PersonProfile]
        do {
            let store = try PeopleStore()
            profiles = try store.profile(forAttendees: file.event.attendees)
        } catch {
            CLI.fail("meet42 people: people store failed: \(error)", code: 2)
        }

        if CLI.wantsJSON(args) {
            CLI.emitJSON(profiles)
            return
        }
        if profiles.isEmpty {
            print("No resolvable attendees for \(file.event.title).")
            return
        }
        for p in profiles {
            let label = p.name ?? p.email ?? p.personId
            let seen = p.lastSeen.map { " last seen \($0)" } ?? ""
            print("\(CLI.padded(label, 32)) shared \(p.sharedMeetingCount) meeting(s)\(seen)")
        }
    }

    // MARK: - link-session <eventId> <sessionId>

    /// Write `session_id` back onto a `calendar_events` row so `meet42 now`'s
    /// `sessionId` field resolves for dedup. Idempotent — calling it twice for
    /// the same eventId is safe and does NOT error or create inconsistent state.
    static func linkSession(args: [String]) {
        let pos = CLI.positionals(args)
        guard pos.count >= 2 else {
            CLI.fail("meet42 link-session: usage: link-session <eventId> <sessionId>")
        }
        let eventId = pos[0]
        let sessionId = pos[1]

        // Open read-write so the UPDATE can land.
        let store: CalendarStore
        do {
            store = try CalendarStore()
        } catch {
            CLI.fail("meet42 link-session: couldn't open calendar.db: \(error)", code: 2)
        }

        do {
            try store.linkSession(eventId: eventId, sessionId: sessionId)
        } catch {
            CLI.fail("meet42 link-session: failed to link session: \(error)", code: 2)
        }

        if CLI.wantsJSON(args) {
            if let event = try? store.event(id: eventId) {
                CLI.emitJSON(event)
            } else {
                print("null")
            }
        } else {
            print("Linked session \(sessionId) → event \(eventId)")
        }
    }

    // MARK: - modes get / set

    static func modes(args: [String]) {
        guard let sub = CLI.firstPositional(args) else {
            CLI.fail("meet42 modes: expected 'get' or 'set'.")
        }
        switch sub {
        case "get":
            modesGet(args: args)
        case "set":
            modesSet(args: args)
        default:
            CLI.fail("meet42 modes: unknown subcommand '\(sub)'. Use 'get' or 'set'.")
        }
    }

    private static func modesGet(args: [String]) {
        let store = ModesStore()
        let all = store.all()
        if CLI.wantsJSON(args) {
            CLI.emitJSON(all)
            return
        }
        print("Calendars:")
        if all.calendars.isEmpty {
            print("  (none — all default to view_only)")
        } else {
            for (id, mode) in all.calendars.sorted(by: { $0.key < $1.key }) {
                print("  \(CLI.padded(id, 40)) \(mode.rawValue)")
            }
        }
        print("Events:")
        if all.events.isEmpty {
            print("  (none)")
        } else {
            for (id, mode) in all.events.sorted(by: { $0.key < $1.key }) {
                print("  \(CLI.padded(id, 40)) \(mode.rawValue)")
            }
        }
    }

    private static func modesSet(args: [String]) {
        // positionals: ["set", <calendar|event>, <id>, <mode>]
        let pos = CLI.positionals(args)
        guard pos.count >= 4 else {
            CLI.fail("meet42 modes set: usage: modes set <calendar|event> <id> <view_only|assisted|ai_scheduled>")
        }
        let scope = pos[1]
        let id = pos[2]
        let modeRaw = pos[3]
        guard let mode = CalendarStore.CalendarMode(rawValue: modeRaw) else {
            CLI.fail("meet42 modes set: unknown mode '\(modeRaw)'. Use view_only, assisted, or ai_scheduled.")
        }
        let store = ModesStore()
        do {
            switch scope {
            case "calendar":
                try store.setCalendarMode(mode, for: id)
            case "event":
                try store.setEventMode(mode, for: id)
            default:
                CLI.fail("meet42 modes set: scope must be 'calendar' or 'event'.")
            }
        } catch {
            CLI.fail("meet42 modes set: failed to persist: \(error)", code: 2)
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(store.all())
        } else {
            print("Set \(scope) \(id) → \(mode.rawValue)")
        }
    }
}
