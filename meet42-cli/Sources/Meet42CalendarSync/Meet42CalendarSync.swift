// Meet42CalendarSync.swift — EventKit ↔ CalendarStore bridge, standalone.
// (meet42-plugin-conversion, M1/s7).
//
// Ported from Work42Sessions/Calendar/CalendarSyncService, stripped of its one
// work42 coupling — the `Flow42Core.Permission.calendar` catalog — in favor of
// direct EventKit authorization (`requestFullAccessToEvents`, macOS 14+). Owns
// an `EKEventStore`, requests Calendar access, performs a full windowed sync
// into meet42's own `calendar.db` (via Meet42Kit.CalendarStore), subscribes to
// `EKEventStoreChanged` for live updates, and runs a 5-minute backstop timer.
//
// ⚠️ TCC / signing (NOT build-verifiable): EventKit calendar access is gated by
// macOS TCC, keyed to the binary's signing identity. For grants to survive
// updates the shipped `meet42` binary must embed `meet42-Info.plist`
// (NSCalendarsFullAccessUsageDescription, …) via `-sectcreate` and be signed
// with a persistent Developer ID (NOT ad-hoc) — see `scripts/build-meet42.sh`.
// A plain `swift build` produces an ad-hoc binary whose grant resets each
// rebuild; real calendar sync must be validated from a signed build on device.
//
// Concurrency: @MainActor. EventKit is MainActor-friendly on macOS;
// `EKEventStoreChanged` arrives on the queue we observe from.

import EventKit
import Foundation
import Meet42Kit

@MainActor
public final class Meet42CalendarSync {

    public enum AccessState: String, Sendable {
        case notDetermined
        case denied
        case restricted
        case writeOnly      // calendar-write-only (we treat as denied for our read needs)
        case fullAccess
    }

    /// The current TCC state. Surfaced through CalendarStore's
    /// `calendar_sync_state` table under the `access_granted` and
    /// `access_state` keys so a doctor/status verb can report without needing
    /// its own EventKit prompt.
    public private(set) var accessState: AccessState = .notDetermined

    /// Default sync window. Past-7-days covers "what did I do today/
    /// yesterday?" and the recently-canceled view; +90 days is enough for the
    /// scheduler to see anything plausible.
    public static let defaultPastWindow: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultFutureWindow: TimeInterval = 90 * 24 * 60 * 60

    private let store: CalendarStore
    private let eventStore: EKEventStore
    /// Invoked after every successful sync (e.g. to trigger the scheduler
    /// reconcile into work42 via `work42 schedule`).
    public var onSyncCompleted: (() -> Void)?

    private var changeObserver: (any NSObjectProtocol)?
    private var backstopTimer: Timer?

    public init(store: CalendarStore) {
        self.store = store
        self.eventStore = EKEventStore()
    }

    /// Bootstrap: request access, run an initial full sync, then subscribe to
    /// change notifications + start the backstop timer. Idempotent.
    public func start() async {
        let granted = await requestAccess()
        do {
            try store.setSyncState("access_state", value: accessState.rawValue)
            try store.setSyncState("access_granted", value: granted ? "1" : "0")
        } catch {
            log("Failed to persist access state: \(error)")
        }
        guard granted else {
            log("Calendar access not granted (state=\(accessState.rawValue)). Sync disabled.")
            return
        }

        await performFullSync()
        subscribeToChanges()
        scheduleBackstop()
    }

    /// Run a single full sync and return (for the one-shot `meet42 sync`
    /// verb). Requests access first; returns the number of events written, or
    /// nil if access was not granted.
    @discardableResult
    public func syncOnce() async -> Int? {
        let granted = await requestAccess()
        try? store.setSyncState("access_state", value: accessState.rawValue)
        try? store.setSyncState("access_granted", value: granted ? "1" : "0")
        guard granted else { return nil }
        return await performFullSync()
    }

    /// Stop the change observer and the backstop timer.
    public func stop() {
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
            changeObserver = nil
        }
        backstopTimer?.invalidate()
        backstopTimer = nil
    }

    // MARK: - Access

    /// Request full calendar access directly through EventKit
    /// (`requestFullAccessToEvents`, macOS 14+). Returns whether read access
    /// ended up granted (`.fullAccess`).
    private func requestAccess() async -> Bool {
        _ = try? await eventStore.requestFullAccessToEvents()
        accessState = currentAuthorization()
        return accessState == .fullAccess
    }

    /// Current calendar access projected onto this service's DB-surfaced
    /// `AccessState`, read from EventKit's raw authorization status.
    private func currentAuthorization() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:    return .fullAccess
        case .writeOnly:     return .writeOnly
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        @unknown default:    return .denied
        }
    }

    // MARK: - Full sync

    /// Pull every event in `[now − pastWindow, now + futureWindow)` and
    /// overwrite the corresponding slice of `calendar_events`. Returns the
    /// number of events written (nil on write failure).
    @discardableResult
    public func performFullSync(
        pastWindow: TimeInterval = Meet42CalendarSync.defaultPastWindow,
        futureWindow: TimeInterval = Meet42CalendarSync.defaultFutureWindow
    ) async -> Int? {
        guard accessState == .fullAccess else { return nil }
        let now = Date()
        let from = now.addingTimeInterval(-pastWindow)
        let to = now.addingTimeInterval(futureWindow)
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: from, end: to, calendars: calendars
        )
        let ekEvents = eventStore.events(matching: predicate)
        let items = ekEvents.compactMap { ek -> CalendarEvent.Item? in
            mapEKEvent(ek, syncedAt: now)
        }
        do {
            try store.replaceWindow(from: from, to: to, items: items)
            try store.setSyncState("last_full_sync", value: iso(now))
            try store.setSyncState("last_full_sync_count", value: String(items.count))
            onSyncCompleted?()
            return items.count
        } catch {
            log("Full sync write failed: \(error)")
            return nil
        }
    }

    // MARK: - Change observer

    private func subscribeToChanges() {
        guard changeObserver == nil else { return }
        let center = NotificationCenter.default
        changeObserver = center.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? self.store.setSyncState("last_notification_at", value: self.iso(Date()))
                await self.performFullSync()
            }
        }
    }

    // MARK: - Backstop

    private func scheduleBackstop() {
        backstopTimer?.invalidate()
        backstopTimer = Timer.scheduledTimer(
            withTimeInterval: 300, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performFullSync()
            }
        }
    }

    // MARK: - Mapping

    private func mapEKEvent(_ ek: EKEvent, syncedAt: Date) -> CalendarEvent.Item? {
        guard let eventId = ek.eventIdentifier, !eventId.isEmpty else { return nil }
        // eventIdentifier is the same for every occurrence of a recurring
        // event. Append the start date so each occurrence gets its own row.
        let occurrenceId = "\(eventId):\(iso(ek.startDate))"
        let source = mapSource(ek.calendar?.source)
        let attendees: [CalendarEvent.Attendee] = (ek.attendees ?? []).map { p in
            CalendarEvent.Attendee(
                name: p.name,
                email: extractEmail(from: p.url),
                status: mapAttendeeStatus(p.participantStatus),
                isOrganizer: p.isCurrentUser
                    ? (ek.organizer?.isCurrentUser ?? false)
                    : (p.url == ek.organizer?.url),
                isCurrentUser: p.isCurrentUser
            )
        }
        let url = ek.url?.absoluteString
        let meetingURL = CalendarEvent.extractMeetingURL(
            url: url, location: ek.location, notes: ek.notes
        )
        let status: CalendarEvent.Status
        switch ek.status {
        case .confirmed: status = .confirmed
        case .tentative: status = .tentative
        case .canceled: status = .canceled
        case .none: status = .none
        @unknown default: status = .none
        }
        return CalendarEvent.Item(
            id: occurrenceId,
            calendarId: ek.calendar?.calendarIdentifier ?? "",
            calendarTitle: ek.calendar?.title,
            source: source,
            title: ek.title ?? "(Untitled)",
            notes: ek.notes,
            location: ek.location,
            startsAt: ek.startDate,
            endsAt: ek.endDate,
            allDay: ek.isAllDay,
            organizer: ek.organizer?.name,
            attendees: attendees,
            status: status,
            url: url,
            meetingURL: meetingURL,
            lastModified: ek.lastModifiedDate,
            syncedAt: syncedAt,
            sessionId: nil,
            sessionDir: nil,
            prepFiredAt: nil
        )
    }

    private func mapSource(_ src: EKSource?) -> CalendarEvent.Source {
        guard let src else { return .other }
        switch src.sourceType {
        case .local: return .local
        case .calDAV:
            let title = src.title.lowercased()
            if title.contains("google") || title.contains("gmail") {
                return .google
            }
            return .caldav
        case .exchange: return .exchange
        case .mobileMe: return .icloud
        case .subscribed: return .caldav
        case .birthdays: return .local
        @unknown default: return .other
        }
    }

    private func mapAttendeeStatus(_ status: EKParticipantStatus) -> CalendarEvent.AttendeeStatus {
        switch status {
        case .unknown: return .unknown
        case .pending: return .pending
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .delegated: return .accepted
        case .completed: return .accepted
        case .inProcess: return .pending
        @unknown default: return .unknown
        }
    }

    private func extractEmail(from url: URL?) -> String? {
        guard let url else { return nil }
        let s = url.absoluteString
        if s.hasPrefix("mailto:") { return String(s.dropFirst(7)) }
        return nil
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[meet42:sync] \(message)\n".utf8))
    }
}
