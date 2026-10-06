// CalendarEvent.swift - Data model namespace for one row in the
// `calendar_events` table.
//
// Why a namespace (`CalendarEvent.Item`, `CalendarEvent.Source`,
// `CalendarEvent.Attendee`): keeps the type names obvious at call
// sites without colliding with EventKit's `EKEvent` or with anything
// else named `Event`. Same namespaced-value-type pattern used elsewhere.
//
// Storage is owned by the Swift side: the calendar reflects the
// user's macOS Calendar.app aggregate and the only writer is
// `CalendarSyncService` running inside `Work42App`. The `meet42` CLI
// is a read-only consumer via `CalendarStore`.

import Foundation

public nonisolated enum CalendarEvent {

    /// Where the event originated. Derived best-effort from the
    /// `EKCalendar.source.sourceType` (Exchange, CalDAV, MobileMe,
    /// Local, …). Stored as a string column so we can add new
    /// providers without a schema migration.
    public enum Source: String, Sendable, Hashable, Codable, CaseIterable {
        case exchange  // Outlook / Microsoft Exchange (work or personal)
        case icloud    // iCloud via Apple ID
        case google    // Google Calendar via CalDAV bridge in macOS
        case caldav    // Generic CalDAV (FastMail, Fastmail, NextCloud, …)
        case local     // On-device "Calendar" calendars
        case other     // Anything we couldn't classify — kept for forward-compat
    }

    /// Free-busy / RSVP status as exposed by EventKit. Not the same as
    /// the meeting's `status` (confirmed / tentative / canceled) — see
    /// `Item.status` for that. Surfaced separately because attendee
    /// status drives "did I accept?" UX.
    public enum AttendeeStatus: String, Sendable, Hashable, Codable {
        case unknown
        case pending
        case accepted
        case declined
        case tentative
    }

    /// One attendee row. Persisted as JSON inside the
    /// `attendees_json` column rather than a separate table — the
    /// list is small (typically <30) and we never query it.
    public struct Attendee: Sendable, Hashable, Codable {
        public let name: String?
        public let email: String?
        public let status: AttendeeStatus
        public let isOrganizer: Bool
        public let isCurrentUser: Bool

        public init(
            name: String?,
            email: String?,
            status: AttendeeStatus,
            isOrganizer: Bool,
            isCurrentUser: Bool
        ) {
            self.name = name
            self.email = email
            self.status = status
            self.isOrganizer = isOrganizer
            self.isCurrentUser = isCurrentUser
        }
    }

    /// Confirmed / tentative / canceled.
    public enum Status: String, Sendable, Hashable, Codable {
        case confirmed
        case tentative
        case canceled
        case none
    }

    /// One row from `calendar_events`.
    public struct Item: Sendable, Hashable, Codable, Identifiable {
        /// `EKEvent.eventIdentifier`. Stable per source — survives
        /// re-sync. Used as the primary key.
        public let id: String
        public let calendarId: String
        public let calendarTitle: String?
        public let source: Source
        public let title: String
        public let notes: String?
        public let location: String?
        /// ISO 8601 UTC. Sorted by this column for board listings.
        public let startsAt: Date
        public let endsAt: Date
        public let allDay: Bool
        public let organizer: String?
        public let attendees: [Attendee]
        public let status: Status
        /// Plain URL from `EKEvent.url` (e.g. an https:// link the
        /// organizer attached) — not the same as `meetingURL`.
        public let url: String?
        /// Best-effort extracted Teams / Meet / Zoom / Webex link
        /// from `url`, `location`, or `notes`. Drives `meet42 join`.
        public let meetingURL: String?
        public let lastModified: Date?
        public let syncedAt: Date
        /// `ChatSession.id` of the session minted for this meeting,
        /// once `MeetingScheduler` has done so. Nil until T-20 min.
        public let sessionId: String?
        /// Absolute path to the session's `ownerDir`. Lets the CLI
        /// open the right transcript without recomputing.
        public let sessionDir: String?
        /// ISO 8601 UTC of when the T-15 prep `.systemPrompt` was
        /// appended to the session's `input.jsonl`. Idempotency
        /// guard against re-firing across app restarts.
        public let prepFiredAt: Date?

        public init(
            id: String,
            calendarId: String,
            calendarTitle: String?,
            source: Source,
            title: String,
            notes: String?,
            location: String?,
            startsAt: Date,
            endsAt: Date,
            allDay: Bool,
            organizer: String?,
            attendees: [Attendee],
            status: Status,
            url: String?,
            meetingURL: String?,
            lastModified: Date?,
            syncedAt: Date,
            sessionId: String?,
            sessionDir: String?,
            prepFiredAt: Date?
        ) {
            self.id = id
            self.calendarId = calendarId
            self.calendarTitle = calendarTitle
            self.source = source
            self.title = title
            self.notes = notes
            self.location = location
            self.startsAt = startsAt
            self.endsAt = endsAt
            self.allDay = allDay
            self.organizer = organizer
            self.attendees = attendees
            self.status = status
            self.url = url
            self.meetingURL = meetingURL
            self.lastModified = lastModified
            self.syncedAt = syncedAt
            self.sessionId = sessionId
            self.sessionDir = sessionDir
            self.prepFiredAt = prepFiredAt
        }
    }

    // MARK: - Meeting URL extraction
    //
    // Outlook / Teams / Zoom / Meet / Webex bury the join URL in
    // different places: `EKEvent.url` for some senders, the location
    // field for room+link hybrids, and inline text in `notes`. We
    // scan all three so `meet42 join` works regardless of which
    // calendar produced the event.

    private static let urlPatterns: [String] = [
        // Microsoft Teams meeting URLs
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s\"<>]+"#,
        #"https?://teams\.live\.com/meet/[^\s\"<>]+"#,
        // Google Meet
        #"https?://meet\.google\.com/[a-zA-Z0-9\-_?=&]+"#,
        // Zoom
        #"https?://[a-zA-Z0-9\-_.]*zoom\.us/(j|w|my)/[^\s\"<>]+"#,
        // Webex
        #"https?://[a-zA-Z0-9\-_.]*webex\.com/(meet|join)/[^\s\"<>]+"#,
        // Generic — last so the more specific patterns win.
        #"https?://[a-zA-Z0-9\-_.]+/[a-zA-Z0-9\-_/?=&%.]*meet[a-zA-Z0-9\-_/?=&%.]*"#,
    ]

    /// Best-effort scan for a meeting join URL across `url`,
    /// `location`, `notes`. Returns the first match using the
    /// provider-specific patterns (which take precedence over the
    /// generic catch-all).
    public static func extractMeetingURL(
        url: String?,
        location: String?,
        notes: String?
    ) -> String? {
        let haystacks = [url, location, notes].compactMap { $0 }
        for pattern in urlPatterns {
            for haystack in haystacks {
                if let range = haystack.range(
                    of: pattern, options: .regularExpression
                ) {
                    return String(haystack[range])
                }
            }
        }
        // Last resort: if `url` looks like a URL at all, return it.
        if let url, !url.isEmpty,
           url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
        return nil
    }
}
