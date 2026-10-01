// Widget.swift — meet42's People widget (meet42-plugin-conversion, M2/s13).
//
// Ported from Work42App/Meetings/PeopleWidgetView, rendered identically (AC12):
// an "ATTENDEES (n)" section with a per-person row (stable palette avatar +
// name + organizer/you chips + a single info line "email · N shared meetings ·
// last seen …"). The only change is the DATA SOURCE: instead of opening
// Flow42Core's PeopleStore directly (plugin widgets can't link Flow42Core), it
// shells the standalone `meet42 people --session-dir <dir> --json` verb and
// decodes a local [PersonRow] mirror. Organizer/you badges + the email
// fallback come from `<dir>/meeting.json`'s attendee list (a local Codable
// mirror), paired with the profiles by order — exactly as the original paired
// PeopleStore profiles with meeting.json attendees.
//
// Links only Work42WidgetKit + Work42UI. `personColor` / `initialsString` / the
// DT tokens are all public in Work42UI.

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - PersonRow (local mirror of `meet42 people --json`)

/// One row of `meet42 people --json` output — a local mirror of meet42's
/// `PersonProfile` (snake_case keys, per its Codable conformance).
struct PersonRow: Codable, Identifiable {
    let personId: String
    let name: String?
    let email: String?
    let sharedMeetingCount: Int
    let lastSeen: String?

    var id: String { personId }

    private enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case name
        case email
        case sharedMeetingCount = "shared_meeting_count"
        case lastSeen = "last_seen"
    }
}

// MARK: - MeetingSnapshot (local mirror of <dir>/meeting.json, attendees only)

/// Minimal local mirror of meet42's `MeetingMeta.File` — only the attendee
/// fields the People widget needs for the organizer/you chips + email fallback.
/// Keys match `CalendarEvent.Item`/`.Attendee`'s default JSON encoding verbatim.
private struct PeopleMeetingSnapshot: Codable {
    struct Event: Codable { let attendees: [Attendee] }
    struct Attendee: Codable {
        let name: String?
        let email: String?
        let isOrganizer: Bool
        let isCurrentUser: Bool
    }
    let event: Event

    static func load(dir: String) -> PeopleMeetingSnapshot? {
        let path = (dir as NSString).appendingPathComponent("meeting.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PeopleMeetingSnapshot.self, from: data)
    }

    static func path(dir: String) -> String {
        (dir as NSString).appendingPathComponent("meeting.json")
    }
}

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher` — polls the
/// file's (mtime, size) signature every second and bumps `version` on change,
/// so the view reloads profiles when meet42 rewrites `meeting.json`.
@Observable
@MainActor
private final class WidgetFileWatcher {

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

// MARK: - PeopleWidget

@Observable
@MainActor
final class PeopleWidget: Work42Widget, Work42WidgetPill {

    let id = "people"
    let title = "People"
    let icon = "person.2"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 260, height: 200) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(PeopleWidgetBody(services: services))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(PeoplePillView(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 240),
            title: title,
            icon: icon
        )
    }
}

// MARK: - Model

/// A fetched profile paired with its source meeting.json attendee (for the
/// organizer/you chips + email fallback), mirroring the original
/// `PeopleWidgetView.AttendeeProfile`.
private struct AttendeeProfile: Identifiable {
    let attendee: PeopleMeetingSnapshot.Attendee?
    let profile: PersonRow
    var id: String { profile.personId }
}

/// Loads `[AttendeeProfile]` by shelling `meet42 people --json` and pairing the
/// result with `meeting.json`'s attendees by order.
@MainActor
private func loadProfiles(services: SessionServices) async -> [AttendeeProfile] {
    guard let dir = services.worktreePath else { return [] }
    let attendees = PeopleMeetingSnapshot.load(dir: dir)?.event.attendees ?? []
    let command = "meet42 people --session-dir '"
        + dir.replacingOccurrences(of: "'", with: "'\\''") + "' --json"
    guard let result = try? await services.shell.run(command: command),
          result.exitCode == 0,
          let data = result.stdout.data(using: .utf8),
          let rows = try? JSONDecoder().decode([PersonRow].self, from: data)
    else { return [] }
    return rows.enumerated().map { idx, row in
        AttendeeProfile(attendee: idx < attendees.count ? attendees[idx] : nil, profile: row)
    }
}

// MARK: - Body view

private struct PeopleWidgetBody: View {
    let services: SessionServices

    @State private var profiles: [AttendeeProfile] = []
    @State private var watcher = WidgetFileWatcher()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s16) {
                if profiles.isEmpty {
                    emptyState
                } else {
                    attendeesBlock
                }
            }
            .padding(.horizontal, DT.s16)
            .padding(.vertical, DT.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { profiles = await loadProfiles(services: services) }
        .onAppear { if let dir = services.worktreePath { watcher.watch(PeopleMeetingSnapshot.path(dir: dir)) } }
        .onDisappear { watcher.stop() }
        .onChange(of: watcher.version) { _, _ in
            Task { profiles = await loadProfiles(services: services) }
        }
    }

    private var attendeesBlock: some View {
        let nonEmpty = profiles.filter { $0.profile.sharedMeetingCount > 0 }
        let allZero = nonEmpty.isEmpty
        return VStack(alignment: .leading, spacing: DT.s16) {
            Text("ATTENDEES (\(profiles.count))")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)

            if allZero {
                noDataYetMessage
            } else {
                VStack(alignment: .leading, spacing: DT.s12) {
                    ForEach(profiles) { entry in
                        personRow(entry)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func personRow(_ entry: AttendeeProfile) -> some View {
        let displayName = entry.profile.name ?? entry.profile.email
            ?? entry.attendee?.name ?? entry.attendee?.email ?? "(unknown)"
        let color = personColor(for: entry.profile.personId)
        return HStack(spacing: DT.s8) {
            personAvatar(displayName, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DT.s8) {
                    Text(displayName)
                        .font(.system(size: DT.f13, weight: .semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    if entry.attendee?.isOrganizer == true {
                        chip("organizer", tint: DT.systemAccent)
                    }
                    if entry.attendee?.isCurrentUser == true {
                        chip("you", tint: .green)
                    }
                    Spacer(minLength: 0)
                }
                Text(metaLine(for: entry))
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func personAvatar(_ name: String, color: Color, size: CGFloat) -> some View {
        Text(initialsString(for: name))
            .font(.system(size: size * 0.35, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
    }

    private func metaLine(for entry: AttendeeProfile) -> String {
        var parts: [String] = []
        if let email = entry.profile.email ?? entry.attendee?.email { parts.append(email) }
        let n = entry.profile.sharedMeetingCount
        parts.append(n == 0 ? "no meetings yet" : "\(n) shared meeting\(n == 1 ? "" : "s")")
        if let lastSeen = entry.profile.lastSeen {
            parts.append("last seen \(Self.relativeIso(lastSeen))")
        }
        return parts.joined(separator: " · ")
    }

    private func chip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: DT.f9, weight: .semibold))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.16)))
            .foregroundStyle(tint)
    }

    private var emptyState: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)
            Text("No attendee data")
                .font(.system(size: DT.f13, weight: .medium))
            Text("No `meeting.json` found or no attendees listed. People data appears once a meeting session has been minted with attendees.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDataYetMessage: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            ForEach(profiles) { entry in
                HStack(spacing: DT.s8) {
                    personAvatar(
                        entry.profile.name ?? entry.profile.email ?? "(unknown)",
                        color: personColor(for: entry.profile.personId),
                        size: 26
                    )
                    Text(entry.profile.name ?? entry.profile.email ?? "(unknown)")
                        .font(.system(size: DT.f12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if entry.attendee?.isOrganizer == true { chip("organizer", tint: DT.systemAccent) }
                    if entry.attendee?.isCurrentUser == true { chip("you", tint: .green) }
                    Spacer(minLength: 0)
                }
            }
            Divider().opacity(0.3)
            HStack(spacing: DT.s8) {
                Image(systemName: "info.circle")
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
                Text("No accumulated data yet — people data builds up across meetings.")
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
            }
            .padding(.top, 2)
        }
    }

    static func relativeIso(_ s: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            let r = RelativeDateTimeFormatter()
            r.unitsStyle = .abbreviated
            return r.localizedString(for: d, relativeTo: Date())
        }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) {
            let r = RelativeDateTimeFormatter()
            r.unitsStyle = .abbreviated
            return r.localizedString(for: d, relativeTo: Date())
        }
        return s
    }
}

// MARK: - Pill view (compact)

private struct PeoplePillView: View {
    let services: SessionServices
    @State private var profiles: [AttendeeProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            if profiles.isEmpty {
                HStack(spacing: DT.s8) {
                    Image(systemName: "person.2.slash").foregroundStyle(DT.textTertiary)
                    Text("No attendees").font(.system(size: DT.f11)).foregroundStyle(.secondary)
                }
            } else {
                Text("ATTENDEES (\(profiles.count))")
                    .font(.system(size: DT.f9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DT.textTertiary)
                ForEach(profiles.prefix(6)) { entry in
                    let displayName = entry.profile.name ?? entry.profile.email ?? "(unknown)"
                    HStack(spacing: DT.s8) {
                        Text(initialsString(for: displayName))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(personColor(for: entry.profile.personId), in: Circle())
                        Text(displayName)
                            .font(.system(size: DT.f12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(DT.s12)
        .task { profiles = await loadProfiles(services: services) }
    }
}
