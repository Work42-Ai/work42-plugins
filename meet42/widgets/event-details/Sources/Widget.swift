// Widget.swift — meet42's Event Details widget (meet42-plugin-conversion, s12).
//
// A faithful, identical-UI port of the app's EventDetailsWidgetView
// (`Sources/Work42App/Meetings/EventDetailsWidgetView.swift`) into a plugin
// widget that links ONLY Work42WidgetKit + Work42UI. The original took a
// `Flow42Core.CalendarEvent.Item` + snapshot timestamp handed down by the
// session panel; a plugin widget can't import Flow42Core, so this reads the
// session's `<dir>/meeting.json` snapshot directly and decodes it through a
// LOCAL Codable mirror (`MeetingSnapshot`) whose property names + Codable
// keys match meet42's on-disk JSON exactly (see MeetingMeta.File /
// CalendarEvent.Item in meet42-cli). A small Timer-based file watcher
// reloads the view when meet42 rewrites the snapshot on sync.
//
// SESSION FILE (read-only):
//   <dir>/meeting.json — the snapshot meet42 writes around a meeting session.

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - MeetingSnapshot (local Flow42Core mirror)

/// Local mirror of `Meet42Kit.MeetingMeta.File` + `CalendarEvent.Item`. Only
/// the fields this widget renders are declared; JSONDecoder ignores the rest.
/// Property names + raw-value enum cases match the on-disk JSON exactly
/// (`JSONEncoder` default key strategy + `.iso8601` dates, per MeetingMeta.write).
struct MeetingSnapshot: Codable {

    struct Event: Codable {
        let title: String
        let startsAt: Date
        let endsAt: Date
        let location: String?
        let organizer: String?
        let notes: String?
        let url: String?
        let meetingURL: String?
        let calendarTitle: String?
        let source: Source
        let status: Status
        let attendees: [Attendee]
    }

    struct Attendee: Codable {
        let name: String?
        let email: String?
        let status: AttendeeStatus
        let isOrganizer: Bool
        let isCurrentUser: Bool
    }

    enum Source: String, Codable {
        case exchange, icloud, google, caldav, local, other
    }

    enum Status: String, Codable {
        case confirmed, tentative, canceled, none
    }

    enum AttendeeStatus: String, Codable {
        case unknown, pending, accepted, declined, tentative
    }

    let event: Event
    let snapshotAt: String

    /// Load + decode `<dir>/meeting.json`, or nil when absent/unreadable.
    static func load(dir: String) -> MeetingSnapshot? {
        let path = (dir as NSString).appendingPathComponent("meeting.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSnapshot.self, from: data)
    }

    static func path(dir: String) -> String {
        (dir as NSString).appendingPathComponent("meeting.json")
    }
}

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher`. Polls the
/// file's (mtime, size) signature every second and bumps `version` on change,
/// so a SwiftUI view that reads `version` re-renders when the file is rewritten
/// out-of-band (e.g. meet42's calendar sync).
@Observable
@MainActor
final class WidgetFileWatcher {

    private(set) var version = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var lastSignature = ""

    func watch(_ path: String) {
        guard self.path != path else { return }
        self.path = path
        lastSignature = Self.signature(of: path)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let path else { return }
        let sig = Self.signature(of: path)
        guard sig != lastSignature else { return }
        lastSignature = sig
        version &+= 1
    }

    private static func signature(of path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "\(mtime)-\(size)"
    }
}

// MARK: - EventDetailsWidget

@Observable
@MainActor
final class EventDetailsWidget: Work42Widget, Work42WidgetPill {

    let id = "eventDetails"
    let title = "Meet42 Event"
    let icon = "calendar"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 260, height: 200) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(EventDetailsWidgetView(services: services))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(EventDetailsPillView(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 160),
            title: title,
            icon: icon
        )
    }
}

// MARK: - EventDetailsWidgetView

/// Faithful port of the app's EventDetailsWidgetView. Reads the session's
/// `meeting.json` snapshot and renders the full event detail; shows an empty
/// state until the snapshot exists.
private struct EventDetailsWidgetView: View {
    let services: SessionServices

    @State private var watcher = WidgetFileWatcher()

    var body: some View {
        let _ = watcher.version
        let dir = services.worktreePath
        let snapshot = dir.flatMap { MeetingSnapshot.load(dir: $0) }

        Group {
            if let snapshot {
                EventDetailBody(event: snapshot.event, snapshotAt: snapshot.snapshotAt)
            } else {
                emptyState
            }
        }
        .onAppear {
            if let dir { watcher.watch(MeetingSnapshot.path(dir: dir)) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("No event snapshot")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("This widget renders the meeting captured in the session's meeting.json. It appears once the event has been synced here.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
        }
        .padding(DT.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - EventDetailBody (the ported detail layout)

private struct EventDetailBody: View {

    let event: MeetingSnapshot.Event
    /// ISO 8601 of when the snapshot was last refreshed. Surfaced
    /// as a small "synced 12s ago" footer so the user can tell
    /// whether the data is stale.
    let snapshotAt: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s16) {
                titleBlock
                Divider().opacity(0.4)
                metaBlock
                if !event.attendees.isEmpty {
                    Divider().opacity(0.4)
                    attendeesBlock
                }
                if let notes = event.notes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().opacity(0.4)
                    notesBlock(notes)
                }
                snapshotFooter
                    .padding(.top, DT.s8)
            }
            .padding(.horizontal, DT.s16)
            .padding(.vertical, DT.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Title + Status

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title.isEmpty ? "(Untitled)" : event.title)
                .font(.system(size: DT.f17, weight: .bold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: DT.s8) {
                Label(EventDetailBody.formatRange(event.startsAt, event.endsAt),
                      systemImage: "clock")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: DT.s8) {
                rsvpBadge
                statusBadge
                Spacer(minLength: 0)
            }
            if let url = event.meetingURL ?? event.url, !url.isEmpty,
               let parsed = URL(string: url) {
                Link(destination: parsed) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("Join meeting")
                    }
                    .font(.system(size: DT.f12, weight: .medium))
                    .padding(.horizontal, DT.s12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DT.rButton)
                            .fill(DT.systemAccent.opacity(0.16))
                    )
                    .foregroundStyle(DT.systemAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Going" / "Maybe" / "Declined" — what the user RSVP'd, if
    /// the snapshot includes them as an attendee. Hidden when the
    /// user isn't on the attendee list (organizer-only meetings,
    /// holiday calendars).
    @ViewBuilder
    private var rsvpBadge: some View {
        if let me = event.attendees.first(where: { $0.isCurrentUser }) {
            let (label, color): (String, Color) = {
                switch me.status {
                case .accepted:  return ("Going", .green)
                case .declined:  return ("Declined", .red)
                case .tentative: return ("Maybe", .orange)
                case .pending:   return ("No reply", .gray)
                case .unknown:   return ("—", .gray.opacity(0.5))
                }
            }()
            chip(label, tint: color)
        }
    }

    /// Confirmed / tentative / canceled — the meeting's overall
    /// status. Pulls dual duty alongside the user's RSVP.
    private var statusBadge: some View {
        let label: String
        let color: Color
        switch event.status {
        case .confirmed: label = "Confirmed"; color = .green
        case .tentative: label = "Tentative"; color = .orange
        case .canceled:  label = "Canceled";  color = .red
        case .none:      label = "—";         color = .gray
        }
        return chip(label, tint: color)
    }

    private func chip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: DT.f9, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, DT.s8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(.secondary)
    }

    // MARK: - Meta block

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            if let loc = event.location, !loc.isEmpty {
                metaRow(symbol: "mappin.and.ellipse", text: loc)
            }
            if let org = event.organizer, !org.isEmpty {
                metaRow(symbol: "person.crop.circle", text: "Organized by \(org)")
            }
            if let cal = event.calendarTitle {
                metaRow(
                    symbol: "calendar",
                    text: "\(cal) · \(event.source.rawValue)"
                )
            }
        }
    }

    private func metaRow(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DT.s8) {
            Image(systemName: symbol)
                .font(.system(size: DT.f10))
                .foregroundStyle(DT.textTertiary)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.system(size: DT.f12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Attendees

    private var attendeesBlock: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("ATTENDEES (\(event.attendees.count))")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, a in
                    HStack(spacing: DT.s8) {
                        statusDot(a.status)
                        Text(a.name ?? a.email ?? "(unknown)")
                            .font(.system(size: DT.f11, weight: a.isCurrentUser ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if a.isOrganizer {
                            Text("organizer")
                                .font(.system(size: DT.f9, weight: .semibold))
                                .tracking(0.4)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DT.systemAccent.opacity(0.16)))
                                .foregroundStyle(DT.systemAccent)
                        }
                        if a.isCurrentUser {
                            Text("you")
                                .font(.system(size: DT.f9, weight: .semibold))
                                .tracking(0.4)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.16)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func statusDot(_ status: MeetingSnapshot.AttendeeStatus) -> some View {
        let color: Color
        switch status {
        case .accepted:  color = .green
        case .declined:  color = .red
        case .tentative: color = .orange
        case .pending:   color = .gray
        case .unknown:   color = .gray.opacity(0.5)
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    // MARK: - Notes + footer

    private func notesBlock(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("NOTES")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            Text(notes)
                .font(.system(size: DT.f11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var snapshotFooter: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: DT.f9))
            Text("Snapshot \(EventDetailBody.relativeIso(snapshotAt))")
                .font(.system(size: DT.f9))
        }
        .foregroundStyle(DT.textTertiary)
    }

    // MARK: - Formatters

    static func formatRange(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: start)) — \(f.string(from: end))"
    }

    static func relativeIso(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            let r = RelativeDateTimeFormatter()
            r.unitsStyle = .abbreviated
            return r.localizedString(for: d, relativeTo: Date())
        }
        return s
    }
}

// MARK: - EventDetailsPillView (compact)

/// Compact pill rendering: title + time + attendee count. Reuses the same
/// snapshot + file-watch path as the full widget.
private struct EventDetailsPillView: View {
    let services: SessionServices

    @State private var watcher = WidgetFileWatcher()

    var body: some View {
        let _ = watcher.version
        let dir = services.worktreePath
        let snapshot = dir.flatMap { MeetingSnapshot.load(dir: $0) }

        Group {
            if let event = snapshot?.event {
                VStack(alignment: .leading, spacing: DT.s8) {
                    Text(event.title.isEmpty ? "(Untitled)" : event.title)
                        .font(.system(size: DT.f13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Label(EventDetailBody.formatRange(event.startsAt, event.endsAt),
                          systemImage: "clock")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !event.attendees.isEmpty {
                        Label("\(event.attendees.count) attendees",
                              systemImage: "person.2")
                            .font(.system(size: DT.f11))
                            .foregroundStyle(DT.textTertiary)
                    }
                }
                .padding(DT.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No event synced yet")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .padding(DT.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            if let dir { watcher.watch(MeetingSnapshot.path(dir: dir)) }
        }
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(EventDetailsWidget())
    }
    return result
}
