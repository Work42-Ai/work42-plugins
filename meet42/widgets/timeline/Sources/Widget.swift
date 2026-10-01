// Widget.swift — meet42's Timeline widget (meet42-plugin-conversion, s15).
//
// A calendar-only port of the app's DayTimelineView
// (`Sources/Work42App/Meetings/DayTimelineView.swift`) into a plugin widget
// that links ONLY Work42WidgetKit + Work42UI. The original rendered real
// EventKit meetings alongside app-internal PlannedDay "work-block" lanes and
// AI-schedule fires sourced from Flow42Core's CalendarStore / PlannedDayStore.
// A plugin widget can't import Flow42Core, and the meet42 CLI cannot provide
// work-blocks or AI schedules, so this is SCOPED TO CALENDAR EVENTS ONLY:
//
//   • The calendar-event day timeline (hour rail, gridlines, collision-laid-out
//     event blocks, the red current-time line, the all-day strip) is ported
//     faithfully.
//   • The per-event assist-mode picker ("Enable AI assistance") is kept — it is
//     the calendar's mode surface.
//   • DROPPED: all PlannedDay work-block lanes (WorkBlockEvent / PlannedDayStore
//     / draw-to-schedule / move+resize) and all AI-schedule fire pills.
//     TODO(meet42): work-blocks/AI-schedules re-added via a separate collection.
//
// DATA: a CLICalendarStore shells `meet42` (list + modes) and decodes local
// CalEvent / CalMode mirrors, refreshing on a ~2s timer while mounted (the CLI
// poll replaces the app store's db-mtime poller). No pill: a compact day
// timeline doesn't read well in a pill, so TimelineWidget does not conform to
// Work42WidgetPill (inherits the nil default behaviour).

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - CalMode (local mirror of CalendarStore.CalendarMode)

/// Per-calendar / per-event assistance level. Raw values match meet42's
/// `modes` vocabulary exactly (`view_only` / `assisted` / `ai_scheduled`).
enum CalMode: String, Codable, Sendable, Equatable, CaseIterable {
    case viewOnly = "view_only"
    case assisted = "assisted"
    case aiScheduled = "ai_scheduled"
}

// MARK: - CalEvent (local mirror of `meet42 list --json`)

/// Local mirror of `Meet42Kit.CalendarEvent.Item`. Only the fields the
/// timeline renders are declared; `JSONDecoder` ignores the rest (syncedAt,
/// lastModified, sessionId, …). Property names + raw-value enum cases match the
/// CLI's default JSON encoding, decoded with `.iso8601` dates.
struct CalEvent: Codable, Identifiable, Equatable {

    enum Source: String, Codable, Equatable {
        case exchange, icloud, google, caldav, local, other
    }
    enum Status: String, Codable, Equatable {
        case confirmed, tentative, canceled, none
    }
    enum AttendeeStatus: String, Codable, Equatable {
        case unknown, pending, accepted, declined, tentative
    }
    struct Attendee: Codable, Equatable {
        let name: String?
        let email: String?
        let status: AttendeeStatus
        let isOrganizer: Bool
        let isCurrentUser: Bool
    }

    let id: String
    let calendarId: String
    let calendarTitle: String?
    let source: Source
    let title: String
    let notes: String?
    let location: String?
    let startsAt: Date
    let endsAt: Date
    let allDay: Bool
    let organizer: String?
    let attendees: [Attendee]
    let status: Status
    let url: String?
    let meetingURL: String?
}

// MARK: - modes get --json payload

/// Mirror of `meet42 modes get --json` → `{"calendars":{id:mode},"events":{id:mode}}`.
private struct ModesPayload: Codable {
    let calendars: [String: CalMode]
    let events: [String: CalMode]
}

/// Shell-quote a single argument (single-quote wrap, escape embedded quotes).
func calShellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - CLICalendarStore (shared shape; duplicated per widget — no shared target)

/// Reproduces the subset of MeetingsStore's published surface the calendar-only
/// views read, sourced by shelling meet42 via `services.shell`. There is no
/// `meet42 status` verb, so the sync-status / access-state header chip is
/// dropped entirely (out of scope).
@Observable
@MainActor
final class CLICalendarStore {

    /// Events in the active window, sorted by `startsAt`.
    var events: [CalEvent] = []
    /// Per-calendar assistance preferences, keyed by `calendarId`.
    var calendarModes: [String: CalMode] = [:]
    /// Per-event overrides, keyed by `eventId`. Beats the calendar default.
    var eventModes: [String: CalMode] = [:]

    enum ViewMode: String, CaseIterable, Identifiable, Sendable {
        case day, week, agenda
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "Day"
            case .week: return "Week"
            case .agenda: return "Agenda"
            }
        }
    }

    var viewMode: ViewMode = .day
    var referenceDate: Date = Date()

    @ObservationIgnored private let services: SessionServices
    @ObservationIgnored private var timer: Timer?

    init(services: SessionServices) {
        self.services = services
    }

    // MARK: Window

    /// Active query window, derived from `viewMode + referenceDate`.
    var window: (from: Date, to: Date) {
        let cal = Calendar.current
        switch viewMode {
        case .day:
            let s = cal.startOfDay(for: referenceDate)
            return (s, cal.date(byAdding: .day, value: 1, to: s) ?? s)
        case .week:
            let s = Self.startOfWeek(referenceDate)
            return (s, cal.date(byAdding: .day, value: 7, to: s) ?? s)
        case .agenda:
            let s = cal.startOfDay(for: Date())
            return (s, cal.date(byAdding: .day, value: 30, to: s) ?? s)
        }
    }

    static func startOfWeek(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    func weekDays() -> [Date] {
        let cal = Calendar.current
        let start = Self.startOfWeek(referenceDate)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: Navigation

    func goToPrevious() {
        let cal = Calendar.current
        switch viewMode {
        case .day:  referenceDate = cal.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
        case .week: referenceDate = cal.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
        case .agenda: return
        }
        Task { await refresh() }
    }

    func goToNext() {
        let cal = Calendar.current
        switch viewMode {
        case .day:  referenceDate = cal.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
        case .week: referenceDate = cal.date(byAdding: .day, value: 7, to: referenceDate) ?? referenceDate
        case .agenda: return
        }
        Task { await refresh() }
    }

    func goToToday() {
        referenceDate = Date()
        Task { await refresh() }
    }

    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        Task { await refresh() }
    }

    // MARK: Refresh (the ~2s CLI poll)

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        let (from, to) = window
        let iso = ISO8601DateFormatter()
        let listCmd = "meet42 list --from \(calShellQuote(iso.string(from: from)))"
            + " --to \(calShellQuote(iso.string(from: to))) --json"
        if let r = try? await services.shell.run(command: listCmd), r.exitCode == 0,
           let data = r.stdout.data(using: .utf8) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let items = try? dec.decode([CalEvent].self, from: data) {
                events = items.sorted { $0.startsAt < $1.startsAt }
            }
        }
        if let r = try? await services.shell.run(command: "meet42 modes get --json"),
           r.exitCode == 0, let data = r.stdout.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ModesPayload.self, from: data) {
            calendarModes = payload.calendars
            eventModes = payload.events
        }
    }

    // MARK: Modes

    /// Resolution order: per-event override → owning-calendar preference →
    /// `.viewOnly`.
    func mode(for event: CalEvent) -> CalMode {
        if let override = eventModes[event.id] { return override }
        if let calMode = calendarModes[event.calendarId] { return calMode }
        return .viewOnly
    }

    func setCalendarMode(_ id: String, _ m: CalMode) {
        calendarModes[id] = m  // optimistic
        let cmd = "meet42 modes set calendar \(calShellQuote(id)) \(m.rawValue)"
        Task {
            _ = try? await services.shell.run(command: cmd)
            await refresh()
        }
    }

    func setEventMode(_ id: String, _ m: CalMode) {
        eventModes[id] = m  // optimistic
        let cmd = "meet42 modes set event \(calShellQuote(id)) \(m.rawValue)"
        Task {
            _ = try? await services.shell.run(command: cmd)
            await refresh()
        }
    }

    // MARK: Grouping / derived

    /// Calendars represented in the current events, paired with their mode —
    /// derived locally (the CLI has no calendar-choices verb).
    var calendarChoices: [CalChoice] {
        var map: [String: (title: String, source: CalEvent.Source, count: Int)] = [:]
        for e in events {
            var entry = map[e.calendarId] ?? (e.calendarTitle ?? e.calendarId, e.source, 0)
            entry.count += 1
            if entry.title.isEmpty, let t = e.calendarTitle, !t.isEmpty { entry.title = t }
            map[e.calendarId] = entry
        }
        return map
            .map { CalChoice(calendarId: $0.key, title: $0.value.title,
                             source: $0.value.source,
                             mode: calendarModes[$0.key] ?? .viewOnly,
                             eventCount: $0.value.count) }
            .sorted { $0.title < $1.title }
    }

    func eventsByDay() -> [(day: Date, items: [CalEvent])] {
        let cal = Calendar.current
        var buckets: [Date: [CalEvent]] = [:]
        for item in events {
            let day = cal.startOfDay(for: item.startsAt)
            buckets[day, default: []].append(item)
        }
        return buckets.map { (day: $0.key, items: $0.value) }.sorted { $0.day < $1.day }
    }
}

/// A calendar + its mode for the settings popover (derived locally).
struct CalChoice: Identifiable, Equatable {
    let calendarId: String
    var title: String
    let source: CalEvent.Source
    var mode: CalMode
    var eventCount: Int
    var id: String { calendarId }
}

// MARK: - EventVisual

enum EventVisual {
    /// Mode-driven palette (mirrors the app's EventVisual.tint):
    ///   .assisted → brand violet, .viewOnly → calm blue, .aiScheduled → orange.
    static func tint(for mode: CalMode) -> Color {
        switch mode {
        case .assisted:    return DT.magentaMid
        case .viewOnly:    return Color(red: 0.20, green: 0.55, blue: 0.92)
        case .aiScheduled: return DT.orange
        }
    }

    static func timeRange(_ e: CalEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return "\(f.string(from: e.startsAt))–\(f.string(from: e.endsAt))"
    }
}

// MARK: - Timeline primitives

enum Timeline {
    static let pixelsPerHour: CGFloat = 56
    static let hourRailWidth: CGFloat = 56
    static let dayHours: Int = 24
    static var dayHeight: CGFloat { CGFloat(dayHours) * pixelsPerHour }

    static func offset(of date: Date, in dayStart: Date) -> CGFloat {
        let hours = date.timeIntervalSince(dayStart) / 3600.0
        return max(0, min(CGFloat(hours), CGFloat(dayHours))) * pixelsPerHour
    }

    struct Lane: Equatable {
        let column: Int
        let totalColumns: Int
    }

    /// macOS Calendar.app-style collision layout: cluster overlapping events,
    /// assign each the lowest free column, and share the column count across a
    /// cluster so lane widths stay consistent.
    static func resolveCollisions(_ events: [CalEvent]) -> [(item: CalEvent, lane: Lane)] {
        let sorted = events.sorted { $0.startsAt < $1.startsAt }
        var output: [(item: CalEvent, lane: Lane)] = []
        var cluster: [(item: CalEvent, column: Int)] = []
        var clusterMaxEnd: Date?

        func flush() {
            guard !cluster.isEmpty else { return }
            let total = (cluster.map { $0.column }.max() ?? 0) + 1
            for c in cluster {
                output.append((item: c.item, lane: Lane(column: c.column, totalColumns: total)))
            }
            cluster.removeAll()
            clusterMaxEnd = nil
        }

        for event in sorted {
            if let maxEnd = clusterMaxEnd, event.startsAt >= maxEnd { flush() }
            let occupied = Set(cluster.filter { $0.item.endsAt > event.startsAt }.map { $0.column })
            var col = 0
            while occupied.contains(col) { col += 1 }
            cluster.append((event, col))
            clusterMaxEnd = max(clusterMaxEnd ?? event.endsAt, event.endsAt)
        }
        flush()
        return output
    }
}

struct HourRail: View {
    let currentTime: Date?
    let dayStart: Date

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24) { hour in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(hourLabel(hour))
                            .font(.system(size: DT.f10, weight: .medium))
                            .foregroundStyle(DT.textTertiary)
                            .padding(.trailing, 6)
                            .offset(y: -7)
                    }
                    .frame(height: Timeline.pixelsPerHour, alignment: .top)
                }
            }
            if let now = currentTime {
                let y = Timeline.offset(of: now, in: dayStart)
                Text(timeLabel(now))
                    .font(.system(size: DT.f10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.red))
                    .offset(x: 6, y: y - 9)
            }
        }
        .frame(width: Timeline.hourRailWidth, height: Timeline.dayHeight, alignment: .topLeading)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12 AM"
        case 12: return "Noon"
        default:
            let h = hour > 12 ? hour - 12 : hour
            return "\(h) \(hour < 12 ? "AM" : "PM")"
        }
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f.string(from: d)
    }
}

struct AllDayBlock: View {
    let item: CalEvent
    let mode: CalMode
    let coordinateSpaceName: String
    let onTap: (CalEvent, CGPoint) -> Void

    private var tint: Color { EventVisual.tint(for: mode) }

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(tint.opacity(0.8)).frame(width: 3)
            Text(item.title.isEmpty ? "(Untitled)" : item.title)
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint.opacity(0.18)))
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named(coordinateSpaceName)) { loc in onTap(item, loc) }
    }
}

/// Calendar-only event block (work-block + AI-routine variants dropped).
/// TODO(meet42): work-blocks/AI-schedules re-added via a separate collection.
struct EventBlock: View {
    let item: CalEvent
    let mode: CalMode
    let dayStart: Date
    let lane: Timeline.Lane
    let coordinateSpaceName: String
    let onTap: (CalEvent, CGPoint) -> Void

    private var tint: Color { EventVisual.tint(for: mode) }
    private var startOffset: CGFloat { Timeline.offset(of: item.startsAt, in: dayStart) }
    private var height: CGFloat {
        max(Timeline.offset(of: item.endsAt, in: dayStart) - startOffset, 18)
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: startOffset)
            HStack(spacing: 1) {
                if lane.column > 0 {
                    ForEach(0..<lane.column, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                blockContent
                    .frame(maxWidth: .infinity)
                    .onTapGesture(coordinateSpace: .named(coordinateSpaceName)) { loc in onTap(item, loc) }
                let trailing = lane.totalColumns - lane.column - 1
                if trailing > 0 {
                    ForEach(0..<trailing, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: max(18, height))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var blockContent: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "(Untitled)" : item.title)
                    .font(.system(size: DT.f11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if height > 32 {
                    Text(EventVisual.timeRange(item))
                        .font(.system(size: DT.f9))
                        .foregroundStyle(DT.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.16)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct HourGridlines: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24) { _ in
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                Spacer(minLength: 0).frame(height: Timeline.pixelsPerHour - 1)
            }
        }
        .frame(height: Timeline.dayHeight, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct CurrentTimeLine: View {
    let dayStart: Date
    let now: Date
    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(height: 1)
            .offset(y: Timeline.offset(of: now, in: dayStart))
            .allowsHitTesting(false)
    }
}

// MARK: - Day timeline

struct DayTimelineView: View {
    let referenceDate: Date
    let events: [CalEvent]
    let modeFor: (CalEvent) -> CalMode
    let onEnableAssistance: (CalEvent) -> Void

    @State private var clickedEvent: CalEvent?
    @State private var clickPoint: CGPoint?

    private let coordSpace = "day-timeline"
    private var dayStart: Date { Calendar.current.startOfDay(for: referenceDate) }
    private var allDay: [CalEvent] { events.filter { $0.allDay } }
    private var timed: [CalEvent] { events.filter { !$0.allDay } }

    var body: some View {
        VStack(spacing: 0) {
            allDayStrip
            DT.systemAccent.opacity(0.15).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        HourRail(
                            currentTime: Calendar.current.isDateInToday(referenceDate) ? context.date : nil,
                            dayStart: dayStart
                        )
                    }
                    ZStack(alignment: .topLeading) {
                        HourGridlines()
                        ForEach(Timeline.resolveCollisions(timed), id: \.item.id) { entry in
                            EventBlock(
                                item: entry.item,
                                mode: modeFor(entry.item),
                                dayStart: dayStart,
                                lane: entry.lane,
                                coordinateSpaceName: coordSpace,
                                onTap: handleTap
                            )
                        }
                        if Calendar.current.isDateInToday(referenceDate) {
                            TimelineView(.periodic(from: Date(), by: 60)) { context in
                                CurrentTimeLine(dayStart: dayStart, now: context.date)
                            }
                        }
                        clickPopoverAnchor
                    }
                    .frame(height: Timeline.dayHeight, alignment: .topLeading)
                    .coordinateSpace(name: coordSpace)
                }
                .padding(.bottom, DT.s24)
            }
        }
    }

    private var allDayStrip: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: DT.f9, weight: .medium))
                .foregroundStyle(DT.textTertiary)
                .frame(width: Timeline.hourRailWidth - 6, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(allDay) { item in
                    AllDayBlock(item: item, mode: modeFor(item),
                                coordinateSpaceName: coordSpace, onTap: handleTap)
                }
            }
            .padding(.top, allDay.isEmpty ? 0 : 4)
            .padding(.bottom, allDay.isEmpty ? 0 : 4)
            .padding(.trailing, DT.s12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private var clickPopoverAnchor: some View {
        if let p = clickPoint {
            ClickAnchor(
                point: p,
                clickedEvent: $clickedEvent,
                modeFor: modeFor,
                onClear: { clickedEvent = nil; clickPoint = nil },
                onEnableAssistance: onEnableAssistance
            )
        }
    }

    private func handleTap(_ item: CalEvent, _ point: CGPoint) {
        clickedEvent = item
        clickPoint = point
    }
}

// MARK: - Click-anchored popover host

struct ClickAnchor: View {
    let point: CGPoint
    @Binding var clickedEvent: CalEvent?
    let modeFor: (CalEvent) -> CalMode
    let onClear: () -> Void
    let onEnableAssistance: (CalEvent) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popover(
                isPresented: Binding(
                    get: { clickedEvent != nil },
                    set: { if !$0 { onClear() } }
                ),
                attachmentAnchor: .point(.center)
            ) {
                if let e = clickedEvent {
                    EventDetailPopover(
                        item: e,
                        mode: modeFor(e),
                        onEnableAssistance: { onEnableAssistance(e) },
                        onDismiss: onClear
                    )
                }
            }
            .allowsHitTesting(false)
            .position(x: point.x, y: point.y)
    }
}

// MARK: - Popover content (calendar-event + per-event assist picker)

struct EventDetailPopover: View {
    let item: CalEvent
    let mode: CalMode
    let onEnableAssistance: () -> Void
    let onDismiss: () -> Void

    private var tint: Color { EventVisual.tint(for: mode) }
    private var assistedTint: Color { EventVisual.tint(for: .assisted) }

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title.isEmpty ? "(Untitled)" : item.title)
                    .font(.system(size: DT.f17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Text(rangeLabel)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.secondary)
                if let cal = item.calendarTitle, !cal.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: DT.f10, weight: .semibold))
                        Text(cal).font(.system(size: DT.f11, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
                }
            }
            if let loc = item.location, !loc.isEmpty {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            if !item.attendees.isEmpty {
                Divider().opacity(0.4)
                Text("ATTENDEES (\(item.attendees.count))")
                    .font(.system(size: DT.f9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DT.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(item.attendees.prefix(8).enumerated()), id: \.offset) { _, a in
                        HStack(spacing: 6) {
                            statusDot(a.status)
                            Text(a.name ?? a.email ?? "(unknown)")
                                .font(.system(size: DT.f11, weight: a.isCurrentUser ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    if item.attendees.count > 8 {
                        Text("+\(item.attendees.count - 8) more")
                            .font(.system(size: DT.f10))
                            .foregroundStyle(DT.textTertiary)
                    }
                }
            }
            if let notes = item.notes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().opacity(0.4)
                Text("NOTES")
                    .font(.system(size: DT.f9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DT.textTertiary)
                Text(notes)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            Divider().opacity(0.4)
            actionRow
        }
        .padding(DT.s16)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: DT.s8) {
            if let url = item.meetingURL ?? item.url, !url.isEmpty,
               let parsed = URL(string: url) {
                Link(destination: parsed) {
                    actionLabel("Join meeting", symbol: "link", filled: true)
                }
                .buttonStyle(.plain)
                .help(url)
            }
            switch mode {
            case .assisted:
                actionLabel("AI Assisted", symbol: "sparkles", filled: true)
            case .viewOnly:
                Button(action: onEnableAssistance) {
                    actionLabel("Enable AI assistance", symbol: "sparkles",
                                filled: false, tint: assistedTint)
                }
                .buttonStyle(.plain)
                .help("Opt this single event into AI assistance. The rest of the calendar stays view-only.")
            case .aiScheduled:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actionLabel(_ text: String, symbol: String, filled: Bool,
                             tint overrideTint: Color? = nil) -> some View {
        let color = overrideTint ?? tint
        return HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).fixedSize()
        }
        .font(.system(size: DT.f11, weight: .medium))
        .padding(.horizontal, DT.s8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: DT.rButton).fill(filled ? color.opacity(0.16) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: DT.rButton)
            .strokeBorder(color.opacity(filled ? 0 : 0.45), lineWidth: 0.5))
        .foregroundStyle(color)
    }

    private var rangeLabel: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: item.startsAt)) — \(f.string(from: item.endsAt))"
    }

    private func statusDot(_ status: CalEvent.AttendeeStatus) -> some View {
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
}

// MARK: - TimelineWidget

@Observable
@MainActor
final class TimelineWidget: Work42Widget {
    let id = "timeline"
    let title = "Timeline"
    let icon = "calendar.day.timeline.left"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 320, height: 320) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(TimelineRootView(services: services))
    }
}

// MARK: - TimelineRootView

private struct TimelineRootView: View {
    let services: SessionServices

    @State private var store: CLICalendarStore?

    var body: some View {
        Group {
            if let store {
                VStack(alignment: .leading, spacing: 0) {
                    header(store)
                    DT.systemAccent.opacity(0.25).frame(height: 1)
                    DayTimelineView(
                        referenceDate: store.referenceDate,
                        events: store.events,
                        modeFor: { store.mode(for: $0) },
                        onEnableAssistance: { store.setEventMode($0.id, .assisted) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if store == nil {
                let s = CLICalendarStore(services: services)
                s.viewMode = .day
                store = s
                s.start()
            }
        }
        .onDisappear { store?.stop() }
    }

    private func header(_ store: CLICalendarStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DT.s12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(store.referenceDate))
                    .font(.system(size: DT.f17, weight: .bold))
                    .foregroundStyle(.primary)
                Text(weekdayLabel(store.referenceDate))
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DT.s8) {
                navButton("chevron.left") { store.goToPrevious() }
                Button { store.goToToday() } label: {
                    Text("Today").font(.system(size: DT.f12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                navButton("chevron.right") { store.goToNext() }
            }
        }
        .padding(.horizontal, DT.s16)
        .padding(.top, DT.s12)
        .padding(.bottom, DT.s8)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f.string(from: d)
    }
    private func weekdayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: d)
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(TimelineWidget())
    }
    return result
}
