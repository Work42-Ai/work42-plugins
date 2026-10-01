// Meet42Paths.swift — standalone path helper for the meet42 CLI
// (meet42-plugin-conversion, M1/s6).
//
// The standalone meet42 tool has NO dependency on work42/Flow42Core, so it
// cannot use `Flow42Paths`/`Work42Paths`. These are the same on-disk
// locations those helpers resolve to (`~/.work42/meet42/…`,
// `~/.work42/peers42/…`), reproduced here so the stores keep reading/writing
// the exact files the app used to — no data migration (a move, not a
// redesign).

import Foundation

public enum Meet42Paths {

    /// `~/.work42` — the shared work42 data root (meet42 reuses it so the
    /// calendar/people mirrors live where every tool already looks).
    public static func root() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".work42")
    }

    /// `~/.work42/meet42/` — the meet42 subsystem root (calendar sync +
    /// per-meeting session directories). Per-machine, not per-project.
    public static func meet42Root() -> String {
        (root() as NSString).appendingPathComponent("meet42")
    }

    /// `~/.work42/meet42/calendar.db` — the `calendar_events` +
    /// `calendar_sync_state` SQLite mirror.
    public static func calendarDB() -> String {
        (meet42Root() as NSString).appendingPathComponent("calendar.db")
    }

    /// `~/.work42/peers42/people.db` — the attendee/people SQLite store.
    public static func peopleDB() -> String {
        let peers = (root() as NSString).appendingPathComponent("peers42")
        return (peers as NSString).appendingPathComponent("people.db")
    }
}
