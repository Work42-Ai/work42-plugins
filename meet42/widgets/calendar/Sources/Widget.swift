// Widget.swift — meet42's Calendar widget (meet42-plugin-conversion, s15).
//
// A calendar-only port of the app's MeetingsView
// (`Sources/Work42App/Meetings/MeetingsView.swift`) + the shared day timeline
// (`DayTimelineView.swift`) into a plugin widget that links ONLY
// Work42WidgetKit + Work42UI. The original drove everything through Flow42Core's
// MeetingsStore / CalendarStore / PlannedDayStore / CalendarSyncService and
// mixed real EventKit meetings with AI-schedule fires and work-blocks. A plugin
// widget can't import Flow42Core, and the meet42 CLI only exposes calendar
// events + per-calendar/-event assist modes, so this is SCOPED TO CALENDAR
// DATA ONLY:
//
//   • Day / Week / Agenda calendar-event rendering is ported faithfully.
//   • The per-calendar assist-mode picker (settings popover) and the per-event
//     "Enable AI assistance" picker (event popover) are kept — they are the
//     calendar's mode surface, backed by `meet42 modes get/set`.
//   • DROPPED: all AI-schedule UI/code (the "+ New schedule" sheet, the AI
//     Scheduler toggle, AISchedulesView, the AIPopover, AI-fire pills, the
//     All/My/AI display filter, AI-schedule session handoff). DROPPED too: the
//     sync-status / access-state header chip (there is no `meet42 status` verb)
//     and the "Open in Calendar" / session-minting actions (AppKit / Flow42Core).
//     TODO(meet42): work-blocks/AI-schedules re-added via a separate collection.
//
// DATA: a CLICalendarStore shells `meet42` (list + modes) and decodes local
// CalEvent / CalMode mirrors, refreshing on a ~2s timer while mounted (the CLI
// poll replaces the app store's db-mtime poller).

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

/// Local mirror of `Meet42Kit.CalendarEvent.Item`. Only the fields the calendar
/// renders are declared; `JSONDecoder` ignores the rest. Property names +
/// raw-value enum cases match the CLI's default JSON encoding, `.iso8601` dates.
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

    var viewMode: ViewMode = .week
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

// MARK: - Week timeline

struct WeekTimeline: View {
    let referenceDate: Date
    let events: [CalEvent]
    let modeFor: (CalEvent) -> CalMode
    let onEnableAssistance: (CalEvent) -> Void

    @State private var clickedEvent: CalEvent?
    @State private var clickPoint: CGPoint?

    private let coordSpace = "week-timeline"

    private var days: [Date] {
        let cal = Calendar.current
        let start = CLICalendarStore.startOfWeek(referenceDate)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func eventsFor(day: Date) -> [CalEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDate($0.startsAt, inSameDayAs: day) }
    }

    var body: some View {
        VStack(spacing: 0) {
            weekDaysHeader
            DT.systemAccent.opacity(0.15).frame(height: 1)
            allDayRow
            DT.systemAccent.opacity(0.15).frame(height: 1)
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        HourRail(
                            currentTime: nowIfThisWeek(at: context.date),
                            dayStart: Calendar.current.startOfDay(for: context.date)
                        )
                    }
                    ZStack(alignment: .topLeading) {
                        HourGridlines()
                        HStack(spacing: 0) {
                            ForEach(days, id: \.self) { day in
                                DayColumn(
                                    day: day,
                                    items: eventsFor(day: day).filter { !$0.allDay },
                                    modeFor: modeFor,
                                    coordinateSpaceName: coordSpace,
                                    onTap: handleTap
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        TimelineView(.periodic(from: Date(), by: 60)) { context in
                            if let now = nowIfThisWeek(at: context.date) {
                                CurrentTimeLine(dayStart: Calendar.current.startOfDay(for: now), now: now)
                            }
                        }
                        clickPopoverAnchor
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: Timeline.dayHeight, alignment: .topLeading)
                    .coordinateSpace(name: coordSpace)
                }
                .padding(.bottom, DT.s24)
            }
        }
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

    private var weekDaysHeader: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Timeline.hourRailWidth)
            ForEach(days, id: \.self) { day in
                weekDayCell(day).frame(maxWidth: .infinity)
            }
        }
        .padding(.top, DT.s12)
        .padding(.bottom, DT.s8)
    }

    private func weekDayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let weekdayFmt = DateFormatter(); weekdayFmt.dateFormat = "EEE"
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "d"
        return HStack(spacing: 6) {
            Text(weekdayFmt.string(from: day))
                .font(.system(size: DT.f10, weight: .medium))
                .foregroundStyle(isToday ? Color.white : DT.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(isToday ? DT.systemAccent : Color.clear))
            Text(dayFmt.string(from: day))
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(isToday ? DT.systemAccent : .primary)
        }
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: DT.f9, weight: .medium))
                .foregroundStyle(DT.textTertiary)
                .frame(width: Timeline.hourRailWidth - 6, alignment: .trailing)
                .padding(.trailing, 6).padding(.top, 8)
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let allDay = eventsFor(day: day).filter { $0.allDay }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allDay) { item in
                            AllDayBlock(item: item, mode: modeFor(item),
                                        coordinateSpaceName: coordSpace, onTap: handleTap)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 2)
                    .padding(.top, allDay.isEmpty ? 0 : 4)
                    .padding(.bottom, allDay.isEmpty ? 0 : 4)
                }
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private func nowIfThisWeek(at now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let start = CLICalendarStore.startOfWeek(referenceDate)
        guard let end = cal.date(byAdding: .day, value: 7, to: start) else { return nil }
        return (now >= start && now < end) ? now : nil
    }
}

private struct DayColumn: View {
    let day: Date
    let items: [CalEvent]
    let modeFor: (CalEvent) -> CalMode
    let coordinateSpaceName: String
    let onTap: (CalEvent, CGPoint) -> Void

    private var dayStart: Date { Calendar.current.startOfDay(for: day) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                .frame(maxWidth: .infinity)
                .frame(height: Timeline.dayHeight)
            ForEach(Timeline.resolveCollisions(items), id: \.item.id) { entry in
                EventBlock(
                    item: entry.item,
                    mode: modeFor(entry.item),
                    dayStart: dayStart,
                    lane: entry.lane,
                    coordinateSpaceName: coordinateSpaceName,
                    onTap: onTap
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Timeline.dayHeight, alignment: .topLeading)
    }
}

// MARK: - Agenda list (condensed calendar-event port)

struct AgendaList: View {
    let groups: [(day: Date, items: [CalEvent])]
    let modeFor: (CalEvent) -> CalMode
    let onEnableAssistance: (CalEvent) -> Void

    @State private var clickedEvent: CalEvent?
    @State private var clickPoint: CGPoint?

    private let coordSpace = "agenda"

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVStack(alignment: .leading, spacing: DT.s20, pinnedViews: .sectionHeaders) {
                    ForEach(groups, id: \.day) { group in
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(group.items) { item in
                                    AgendaRow(item: item, mode: modeFor(item),
                                              coordinateSpaceName: coordSpace, onTap: handleTap)
                                }
                            }
                            .padding(.horizontal, DT.s24)
                        } header: {
                            dayHeader(group.day)
                        }
                    }
                }
                .padding(.top, DT.s20)
                .padding(.bottom, DT.s32)
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
            .coordinateSpace(name: coordSpace)
        }
    }

    private func handleTap(_ item: CalEvent, _ point: CGPoint) {
        clickedEvent = item
        clickPoint = point
    }

    private func dayHeader(_ day: Date) -> some View {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = cal.isDateInToday(day) ? "'Today' · EEEE, MMM d" : "EEEE, MMM d"
        return Text(f.string(from: day))
            .font(.system(size: DT.f12, weight: .semibold))
            .foregroundStyle(cal.isDateInToday(day) ? DT.systemAccent : DT.textSecondary)
            .padding(.horizontal, DT.s24)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DT.backdrop.opacity(0.92))
    }
}

private struct AgendaRow: View {
    let item: CalEvent
    let mode: CalMode
    let coordinateSpaceName: String
    let onTap: (CalEvent, CGPoint) -> Void

    private var tint: Color { EventVisual.tint(for: mode) }

    var body: some View {
        HStack(alignment: .top, spacing: DT.s12) {
            VStack(alignment: .trailing, spacing: 1) {
                if item.allDay {
                    Text("all-day").font(.system(size: DT.f9, weight: .medium))
                        .foregroundStyle(DT.textTertiary)
                } else {
                    Text(timeLabel(item.startsAt)).font(.system(size: DT.f11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(timeLabel(item.endsAt)).font(.system(size: DT.f9))
                        .foregroundStyle(DT.textTertiary)
                }
            }
            .frame(width: 58, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "(Untitled)" : item.title)
                    .font(.system(size: DT.f13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let cal = item.calendarTitle, !cal.isEmpty {
                    Text(cal).font(.system(size: DT.f10))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named(coordinateSpaceName)) { loc in onTap(item, loc) }
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
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

// MARK: - Calendar settings popover (per-calendar assist-mode picker)

struct CalendarSettingsPopover: View {
    let choices: [CalChoice]
    let setMode: (String, CalMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar AI assistance")
                    .font(.system(size: DT.f15, weight: .semibold))
                Text("Choose which calendars the AI should engage with. AI Assisted calendars get sessions and prep; view-only ones stay visible but the agent stays hands-off.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if choices.isEmpty {
                Text("No calendars yet — wait for the first sync to populate this list.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(DT.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DT.s12)
            } else {
                VStack(spacing: 6) {
                    ForEach(choices) { choice in
                        CalendarPreferenceRow(choice: choice, setMode: setMode)
                    }
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: DT.s16) {
                legendChip(label: "AI Assisted", mode: .assisted)
                legendChip(label: "View only", mode: .viewOnly)
                legendChip(label: "AI scheduled", mode: .aiScheduled)
                Spacer(minLength: 0)
            }
        }
        .padding(DT.s16)
        .frame(width: 360)
    }

    private func legendChip(label: String, mode: CalMode) -> some View {
        HStack(spacing: 6) {
            Circle().fill(EventVisual.tint(for: mode)).frame(width: 10, height: 10)
            Text(label).font(.system(size: DT.f10, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

private struct CalendarPreferenceRow: View {
    let choice: CalChoice
    let setMode: (String, CalMode) -> Void

    private var assisted: Binding<Bool> {
        Binding(
            get: { choice.mode == .assisted },
            set: { newValue in setMode(choice.calendarId, newValue ? .assisted : .viewOnly) }
        )
    }

    var body: some View {
        HStack(spacing: DT.s12) {
            Circle().fill(EventVisual.tint(for: choice.mode)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(choice.source.rawValue) · \(choice.eventCount) event\(choice.eventCount == 1 ? "" : "s")")
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
            }
            Spacer(minLength: DT.s8)
            Toggle("", isOn: assisted)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(DT.magentaMid)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - CalendarWidget

@Observable
@MainActor
final class CalendarWidget: Work42Widget, Work42WidgetPill {
    let id = "calendar"
    let title = "Calendar"
    let icon = "calendar"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 420, height: 360) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(CalendarRootView(services: services))
    }

    // MARK: Work42WidgetPill — compact "next N events" agenda.

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(CalendarPillView(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 260),
            title: title,
            icon: icon
        )
    }
}

// MARK: - CalendarRootView

private struct CalendarRootView: View {
    let services: SessionServices

    @State private var store: CLICalendarStore?
    @State private var settingsOpen = false

    var body: some View {
        Group {
            if let store {
                VStack(alignment: .leading, spacing: 0) {
                    header(store)
                    DT.systemAccent.opacity(0.25).frame(height: 1)
                    content(store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if store == nil {
                let s = CLICalendarStore(services: services)
                store = s
                s.start()
            }
        }
        .onDisappear { store?.stop() }
    }

    // MARK: Header

    private func header(_ store: CLICalendarStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: DT.s12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(periodLabel(store))
                        .font(.system(size: DT.f17, weight: .bold))
                        .foregroundStyle(.primary)
                    if !periodSubLabel(store).isEmpty {
                        Text(periodSubLabel(store))
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                viewModePicker(store)
            }
            HStack(spacing: DT.s8) {
                Text(subtitle(store))
                    .font(.system(size: DT.f10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if store.viewMode != .agenda {
                    navButton("chevron.left") { store.goToPrevious() }
                    Button { store.goToToday() } label: {
                        Text("Today").font(.system(size: DT.f12, weight: .medium))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    navButton("chevron.right") { store.goToNext() }
                }
                settingsButton(store)
            }
        }
        .padding(.horizontal, DT.s16)
        .padding(.top, DT.s12)
        .padding(.bottom, DT.s8)
    }

    private func viewModePicker(_ store: CLICalendarStore) -> some View {
        Picker("", selection: Binding(
            get: { store.viewMode },
            set: { store.setViewMode($0) }
        )) {
            ForEach(CLICalendarStore.ViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func settingsButton(_ store: CLICalendarStore) -> some View {
        Button { settingsOpen = true } label: {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help("Calendar settings")
        .popover(isPresented: $settingsOpen, arrowEdge: .top) {
            CalendarSettingsPopover(
                choices: store.calendarChoices,
                setMode: { id, mode in store.setCalendarMode(id, mode) }
            )
        }
    }

    // MARK: Content router

    @ViewBuilder
    private func content(_ store: CLICalendarStore) -> some View {
        switch store.viewMode {
        case .day:
            DayTimelineView(
                referenceDate: store.referenceDate,
                events: store.events,
                modeFor: { store.mode(for: $0) },
                onEnableAssistance: { store.setEventMode($0.id, .assisted) }
            )
        case .week:
            WeekTimeline(
                referenceDate: store.referenceDate,
                events: store.events,
                modeFor: { store.mode(for: $0) },
                onEnableAssistance: { store.setEventMode($0.id, .assisted) }
            )
        case .agenda:
            if store.events.isEmpty {
                emptyState
            } else {
                AgendaList(
                    groups: store.eventsByDay(),
                    modeFor: { store.mode(for: $0) },
                    onEnableAssistance: { store.setEventMode($0.id, .assisted) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DT.systemAccent)
            Text("Nothing scheduled in this range")
                .font(.system(size: DT.f15, weight: .semibold))
            Text("Events appear here once meet42 has synced your calendar.")
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(DT.s40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Labels

    private func periodLabel(_ store: CLICalendarStore) -> String {
        let f = DateFormatter()
        switch store.viewMode {
        case .day:    f.dateFormat = "MMMM d, yyyy"; return f.string(from: store.referenceDate)
        case .week:   f.dateFormat = "MMMM yyyy";    return f.string(from: store.referenceDate)
        case .agenda: return "Agenda"
        }
    }

    private func periodSubLabel(_ store: CLICalendarStore) -> String {
        switch store.viewMode {
        case .day:
            let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: store.referenceDate)
        case .week:
            let cal = Calendar.current
            let start = CLICalendarStore.startOfWeek(store.referenceDate)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return "\(f.string(from: start)) — \(f.string(from: end))"
        case .agenda:
            return ""
        }
    }

    private func subtitle(_ store: CLICalendarStore) -> String {
        let count = store.events.count
        return count == 1 ? "1 event" : "\(count) events"
    }
}

// MARK: - CalendarPillView (compact "next N events" agenda)

private struct CalendarPillView: View {
    let services: SessionServices

    @State private var store: CLICalendarStore?

    var body: some View {
        Group {
            if let store {
                let upcoming = Array(
                    store.events
                        .filter { $0.endsAt >= Date() }
                        .sorted { $0.startsAt < $1.startsAt }
                        .prefix(5)
                )
                VStack(alignment: .leading, spacing: DT.s8) {
                    Text("UP NEXT")
                        .font(.system(size: DT.f9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(DT.textTertiary)
                    if upcoming.isEmpty {
                        Text("Nothing upcoming")
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(upcoming) { e in
                            HStack(spacing: DT.s8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(EventVisual.tint(for: store.mode(for: e)))
                                    .frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title.isEmpty ? "(Untitled)" : e.title)
                                        .font(.system(size: DT.f12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(e.allDay ? "all-day" : whenLabel(e.startsAt))
                                        .font(.system(size: DT.f10))
                                        .foregroundStyle(DT.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(DT.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().padding(DT.s12)
            }
        }
        .onAppear {
            if store == nil {
                let s = CLICalendarStore(services: services)
                s.viewMode = .agenda
                store = s
                s.start()
            }
        }
        .onDisappear { store?.stop() }
    }

    private func whenLabel(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = cal.isDateInToday(d) ? "'Today' h:mm a" : "EEE MMM d · h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(CalendarWidget())
    }
    return result
}
