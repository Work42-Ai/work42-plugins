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
//     and the "Open in Calendar" action.
//     TODO(meet42): work-blocks/AI-schedules re-added via a separate collection.
//
// DATA: a CLICalendarStore shells `meet42` (list + modes) and decodes local
// CalEvent / CalMode mirrors, refreshing on a ~2s timer while mounted (the CLI
// poll replaces the app store's db-mtime poller).

import AppKit
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

// MARK: - Meet42Trace (duplicated per widget — no shared target; same convention as shell-quote helpers)

/// Append one JSON-line trace event to ~/.work42/meet42/trace.jsonl.
/// Best-effort (never throws, never blocks). Disabled when MEET42_TRACE=0.
private enum Meet42Trace {
    static func log(_ src: String, _ evt: String, _ fields: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["MEET42_TRACE"] != "0" else { return }
        var row = fields
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        row["ts"]  = f.string(from: Date())
        row["pid"] = Int(getpid())
        row["src"] = src
        row["evt"] = evt
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".work42/meet42")
        let path = (root as NSString).appendingPathComponent("trace.jsonl")
        // Rotate past 5 MB.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
            rename(path, path + ".1")
        }
        // Ensure the directory exists before opening.
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: nil)
        // O_APPEND|O_CREAT|O_WRONLY: atomic across processes for small writes.
        let fd = open(path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return }
        line.withCString { _ = write(fd, $0, strlen($0)) }
        close(fd)
    }
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

// MARK: - Mic-wake detection (background agent + pill bridge)
//
// The calendar widget's background agent is the always-on, session-less mic-wake
// detector (meet42-detection-rework design): on Home a widget's agent runs
// independent of any mounted view, so it IS the global pre-session detector —
// no app bridge needed. It:
//
//   (a) Detection — EVENT-DRIVEN, zero polling. Consumes the long-lived
//       `meet42 watch` child process's line-delimited JSON stdout stream
//       (CoreAudio property listeners over PER-PROCESS mic INPUT only — never
//       triggers on audio output). Each `call-open` is handled exactly once
//       (in-memory `Set<CallId>`, never re-prompts within one call session);
//       it shells `meet42 now --json` to optionally NAME the call from a
//       matching calendar event (purely cosmetic — detection itself is
//       platform-based, not calendar-based), decides YES (a session already
//       exists for the event) vs NO (none yet), sets
//       `CalendarDetectionState.shared.phase = .detected(meeting)`, and
//       presents the calendar widget's DETECTED pill with the app's native
//       icon.
//   (b) Start sequence — RECORD-FIRST (meet42-recording-lifecycle-rework):
//       Record now / the 10s auto-start fires `meet42 record start`
//       IMMEDIATELY — session-agnostic, allocates its own recordings dir,
//       returns within well under 1s. The session comes AFTER, off the
//       critical path: YES (a calendar event already has one linked, e.g. a
//       "Prepare for Meeting" session with prep work already in it) attaches
//       the recording's pointer directly to that existing session, no mint;
//       NO mints a fresh session seeded with the pointer (`meeting/
//       recording_dir`) + stable meeting identity at creation. The phase flips
//       to `.settingUp` while this runs, then `.none` + dismiss this pill + float the transcript
//       RECORDING pill for that session — a widget pill owned by the MEETING
//       session, never Home's. A failed attempt reverts the phase to
//       `.detected` with a retry message, and explicitly stops the just-started
//       recording so a failed mint can never leave an unowned capture.
//       `call-close` just cancels an undecided Detected prompt; this agent no
//       longer has active-meeting stop ownership; Transcript takes over after
//       the one-way handoff.
//   (c) Reconciler — every ~30s reads assisted events (`meet42 modes get --json`
//       + `meet42 list --json`) and syncs them into work42's generic scheduler
//       (`work42 schedule add/cancel --key mtg:<id>`) at T-15min. Unchanged by
//       the detection rework.
//
// Only ONE agent instance (across every alive session) does this work — see
// `DetectorLock` — since `WidgetBackgroundHost` starts one instance per
// (session × widget) and N alive sessions must not mean N independent
// watchers/prompts/mints for the same mic event.
//
// The DETECTED pill (`DetectedPillView`) is a plugin-local port of the app's
// EventSessionAccessory "detected" state (medallion + name/subtitle + 10s
// auto-start countdown + purple bar + Skip / Record now); `SettingUpPillView`
// covers the `.settingUp` phase with a `Loader42` + cycling
// helper text, mirroring `ProcessOverlay.beginSessionSetup()`. The agent↔pill
// bridge is `CalendarDetectionState.shared`: the agent WRITES `.phase`;
// `makePillView` READS it and renders the matching accessory — the host panel
// live-resizes the pill as the reported content size changes between phases.
// The record decision + 10s auto-start timer live on the agent (so side
// effects stay agent-owned); the pill just calls back.

/// Meeting-detection accent — the brand violet (#7C3AED), redefined locally so the
/// widget links no Flow42Core/Work42App. Purple = "a meeting was detected".
let meetingDetectionPurple = Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)
/// Lighter violet for the on-dark countdown copy (#C4B5FD).
let meetingDetectionPurpleLight = Color(red: 0xC4 / 255, green: 0xB5 / 255, blue: 0xFD / 255)

/// A resolved detection the agent hands to the pill. Carries the display data +
/// two callbacks the pill invokes (Record now / Skip) so the side effects stay
/// owned by the agent, not the view.
@MainActor
struct DetectedMeeting {
    /// Meeting name — the matching calendar event's title if one resolved,
    /// else the detected app name (e.g. "Zoom").
    let title: String
    /// Subtitle context — "<app> · 2:00 – 2:30 PM" when a calendar event
    /// matched, else just the app name.
    let subtitle: String
    /// The resolved calendar event id, or nil for an ad-hoc call.
    let eventId: String?
    /// The id of a session already minted for this event (YES path), else nil (NO).
    let existingSessionId: String?
    /// Scheduled bounds when a calendar event matched; nil for ad-hoc calls.
    let scheduledStart: Date?
    let scheduledEnd: Date?
    /// Canonical bundle id of the detected call app (e.g. "us.zoom.xos") —
    /// resolves the medallion's native app icon via NSWorkspace.
    let bundleId: String
    /// Retryable setup error. Nil for the initial detected prompt.
    let errorMessage: String?
    /// Moment the 10s auto-start grace began — drives the bar + "Auto-… in Ns".
    let countdownStart: Date
    /// Record now / auto-start → run the start sequence (agent-owned).
    let onRecord: () -> Void
    /// Skip → clear + dismiss, permanently for this call session (agent-owned).
    let onSkip: () -> Void
}

/// The Calendar pill's current phase — mutually exclusive single-pill states
/// (meet42-detect-pill-rework). The background agent WRITES `phase`; the
/// calendar widget's `makePillView` READS it to choose the pill's content.
enum CalendarPillPhase {
    /// A meeting was detected and the Skip/Record now prompt is showing.
    case detected(DetectedMeeting)
    /// Recording started; Calendar is seeding or minting the event session.
    case settingUp
    /// No detection in progress — the pill falls back to the compact
    /// "next N events" agenda (`CalendarPillView`).
    case none
}

/// The agent↔pill bridge. The background agent WRITES `phase`; the calendar
/// widget's `makePillView` READS it to switch the pill's content.
@Observable
@MainActor
final class CalendarDetectionState {
    static let shared = CalendarDetectionState()
    private init() {}

    var phase: CalendarPillPhase = .none
}

/// Routes the ALREADY-FLOATED calendar pill's content by `phase` — and,
/// critically, does so from an actual SwiftUI `View.body` rather than a plain
/// function. `PillHost.present` calls `makePillView` exactly ONCE per
/// `present()` call and freezes the resulting `AnyView`; `startRecording`
/// below never calls `present` again, it only mutates
/// `CalendarDetectionState.shared.phase` and relies on reactive re-render.
/// Reading an `@Observable` property from a plain function (the old
/// `makePillView` body) does NOT establish that dependency — only reading it
/// from a real View's `body` does — so the loader states silently never
/// appeared; this wrapper is what makes the phase transitions actually live.
private struct CalendarPillRouter: View {
    let services: SessionServices

    var body: some View {
        switch CalendarDetectionState.shared.phase {
        case .detected(let meeting):
            DetectedPillView(meeting: meeting, services: services)
        case .settingUp:
            SettingUpPillView()
        case .none:
            CalendarPillView(services: services)
        }
    }
}

// MARK: - DetectedPillView (ported "detected" accessory state)

/// Plugin-local port of EventSessionAccessory's `detected` state: medallion +
/// meeting name/subtitle + "Auto-starting in Ns" countdown + purple bar + Skip /
/// Record now. Content-only — the host (`PillBirthView`) owns the card surface;
/// this view must not draw its own background (no AppKit, no Flow42Core).
struct DetectedPillView: View {
    let meeting: DetectedMeeting
    let services: SessionServices

    private let cardWidth: CGFloat = 412
    private let countdownTotal: TimeInterval = 10

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                header
                actionRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            countdownBar
        }
        .frame(width: cardWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.controlActiveState, .active)
    }

    // MARK: Header — medallion + name/subtitle

    private var header: some View {
        HStack(spacing: 11) {
            medallion
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meeting.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
        }
        .frame(height: 36)
    }

    /// The detected app's native icon (resolved via NSWorkspace from the
    /// canonical bundle id meet42 watch reported), falling back to a plain
    /// video glyph if resolution fails (app not discoverable, empty bundle id).
    private var medallion: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(meetingDetectionPurple.opacity(0.9))
            .overlay(
                Group {
                    if let icon = Self.resolveAppIcon(bundleId: meeting.bundleId) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            )
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }

    private static func resolveAppIcon(bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: Action row — countdown message + Skip + Record now

    private var actionRow: some View {
        HStack(spacing: 10) {
            countdownMessage
            Spacer(minLength: 8)
            skipButton
            recordButton
        }
        .frame(height: 32)
    }

    private var countdownMessage: some View {
        Group {
            if let errorMessage = meeting.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.red.opacity(0.9))
            } else {
                TimelineView(.animation) { ctx in
                    Text("Auto-starting in \(countdownSeconds(at: ctx.date))s")
                        .foregroundStyle(meetingDetectionPurpleLight)
                }
            }
        }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
    }

    private var skipButton: some View {
        Button(action: meeting.onSkip) {
            Text("Skip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 15)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.10))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .help("Skip auto-start")
    }

    private var recordButton: some View {
        Button(action: meeting.onRecord) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text(meeting.errorMessage == nil ? "Record now" : "Retry")
                    .font(.system(size: DT.f11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(meetingDetectionPurple))
        }
        .buttonStyle(.plain)
        .help("Start recording now")
    }

    // MARK: Purple countdown bar (flush bottom)

    private var countdownBar: some View {
        Group {
            if meeting.errorMessage == nil {
                TimelineView(.animation) { ctx in
                    let frac = countdownFraction(at: ctx.date)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.08))
                        Rectangle()
                            .fill(meetingDetectionPurple)
                            .frame(width: max(0, cardWidth * frac))
                            .shadow(color: meetingDetectionPurple.opacity(0.7), radius: 4)
                    }
                    .frame(width: cardWidth, height: 3)
                }
            } else {
                Rectangle().fill(Color.clear).frame(width: cardWidth, height: 3)
            }
        }
    }

    private func countdownFraction(at date: Date) -> CGFloat {
        guard countdownTotal > 0 else { return 0 }
        let remaining = max(0, countdownTotal - date.timeIntervalSince(meeting.countdownStart))
        return CGFloat(remaining / countdownTotal)
    }

    private func countdownSeconds(at date: Date) -> Int {
        let remaining = max(0, countdownTotal - date.timeIntervalSince(meeting.countdownStart))
        return max(1, Int(ceil(remaining)))
    }
}

// MARK: - SettingUpPillView (Calendar pill's second/third state)

/// Shown while Calendar seeds or mints the event session. Mirrors
/// the app's `ProcessOverlay.beginSessionSetup()` (same `Loader42` + title +
/// cycling helper lines), but content-only: the host panel owns the card
/// surface (confirmed — `WidgetPillMetadata` has no per-widget color/style
/// override, so every pill renders on the same dark glass), so this draws
/// white text over that glass rather than the app dialog's light card.
struct SettingUpPillView: View {
    private let cardWidth: CGFloat = 320
    private let helperInterval: TimeInterval = 2.2
    private static let mintHelpers = [
        "Minting an isolated worktree",
        "Carrying over your local files",
        "Preparing agent skills",
        "Wiring up the session",
    ]

    @State private var helperIndex = 0
    @State private var dotsOn = false

    var body: some View {
        VStack(spacing: 14) {
            Loader42()
                .frame(width: 56, height: 56)
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    animatedDots
                }
                Text(Self.mintHelpers[helperIndex % Self.mintHelpers.count])
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .contentTransition(.opacity)
                        .id(helperIndex)
                        .transition(.opacity)
            }
        }
        .padding(.vertical, 22)
        .frame(width: cardWidth)
        .onAppear { dotsOn = true }
        .onReceive(Timer.publish(every: helperInterval, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                helperIndex = (helperIndex + 1) % Self.mintHelpers.count
            }
        }
    }

    private var title: String { "Setting up your Session" }

    private var animatedDots: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.5))
                    .frame(width: 3, height: 3)
                    .opacity(dotsOn ? 1 : 0.2)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                        value: dotsOn
                    )
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - meet42 now --json payload

/// Decode target for `meet42 now --json` — a single `CalendarEvent.Item` (or the
/// literal `null`). Only the fields the detection flow needs; `sessionId` is the
/// id of a session already minted for this event (nil → NO/record-to-create path).
private struct DetectedEventPayload: Decodable {
    let id: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let source: String?
    let sessionId: String?
}

// MARK: - DetectorLock

/// Machine-wide lock so only ONE `CalendarDetectionAgent` instance — across
/// every alive session this widget is active on, and across every app
/// process — spawns `meet42 watch` and runs the prompt/mint pipeline.
/// `WidgetBackgroundHost` starts one agent instance per (session × widget);
/// with N alive sessions that's N independent watchers each prompting/minting
/// for the same mic event (observed live: two simultaneous `meet42 watch`
/// processes, two `call-open`s and two `prompt-shown`s ~1ms apart for the
/// SAME Chrome session).
///
/// Uses an OS-level `flock()` rather than a hand-rolled "read the claim file,
/// check if the pid is alive, then overwrite it" scheme — that read-then-write
/// shape is NOT atomic: two agents starting within the same instant both read
/// "free/stale" and both unconditionally win the overwrite (confirmed live —
/// that race is exactly what produced the duplicate watchers above).
/// `flock(LOCK_EX | LOCK_NB)` is atomic at the kernel level (no TOCTOU window)
/// and self-releasing — the lock drops the instant the owning process exits
/// for ANY reason (clean quit, crash, force-kill), so there is no pid-liveness
/// bookkeeping to get wrong.
private enum DetectorLock {
    private static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".work42/meet42/detector.lock")
    }

    /// The fd we hold the lock on, once claimed. -1 means not held.
    nonisolated(unsafe) private static var heldFD: Int32 = -1

    /// Returns true only for the ONE caller that actually wins the lock.
    /// `heldFD` is process-wide, not per-caller — `WidgetBackgroundHost` runs
    /// one `CalendarDetectionAgent` instance per (session × widget), all in
    /// the SAME process (e.g. the Home-level detector + this task session's
    /// own detector), so a "heldFD >= 0 → return true" fast path (as if that
    /// meant "I already hold it") actually told EVERY instance in the
    /// process "you have it" the instant the first one claimed it —
    /// confirmed live: two `meet42 watch` children spawned from one PID.
    /// Once held, every other claim() in this process must get false; only
    /// release() (called by the true owner's stop()) reopens it.
    static func claim() -> Bool {
        guard heldFD < 0 else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        heldFD = fd
        return true
    }

    /// Release the lock, if we hold it.
    static func release() {
        guard heldFD >= 0 else { return }
        flock(heldFD, LOCK_UN)
        close(heldFD)
        heldFD = -1
    }
}

// MARK: - CalendarDetectionAgent

/// The calendar widget's background agent: mic-wake detection + the scheduler
/// reconciler. One instance per (session × widget) — on Home, that's the single
/// session-less detector. All side effects go through `services.shell`
/// (meet42/work42 CLIs), `services.pill`, and `CalendarDetectionState.shared`.
@Observable
@MainActor
final class CalendarDetectionAgent: WidgetBackgroundAgent {
    var headerLabels: [WidgetHeaderLabel] = []

    @ObservationIgnored private var services: WidgetBackgroundServices?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watchProcess: Process?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var detectorClaimTask: Task<Void, Never>?
    /// True once THIS instance owns the machine-wide detector lock (see
    /// `DetectorLock`) and is therefore the one spawning `meet42 watch` +
    /// running the reconciler. WidgetBackgroundHost starts one agent instance
    /// per (session × widget) — with N alive sessions that's N instances; only
    /// the lock owner does real work, the rest stay idle and periodically
    /// check whether the owner has died so one of them can take over.
    @ObservationIgnored private var ownsDetectorLock = false

    /// Calls already handled (prompted, or decided) — a call-open is handled
    /// exactly once. In-memory only, call-session scoped: a restart treats a
    /// still-open call as fresh (confirmed acceptable — no cross-restart
    /// persistence needed).
    @ObservationIgnored private var handledCalls: Set<String> = []
    /// Scheduler keys this agent has added, so it can cancel ones that drop out.
    @ObservationIgnored private var scheduledKeys: Set<String> = []

    // MARK: Lifecycle

    func start(services s: WidgetBackgroundServices) {
        services = s
        ownsDetectorLock = DetectorLock.claim()
        if ownsDetectorLock {
            beginWatching(s)
        }
        // Idle instances (lock not held) re-check every ~15s in case the
        // owner died without a clean stop() (e.g. the app was killed, not
        // quit) — flock releases automatically the instant that process
        // exits, so the very next claim() attempt after that succeeds; the
        // 15s interval is just how soon an idle instance notices and takes
        // over, not a staleness timeout.
        detectorClaimTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.ownsDetectorLock else { continue }
                if DetectorLock.claim() {
                    self.ownsDetectorLock = true
                    self.beginWatching(s)
                }
            }
        }
    }

    func stop() {
        watchTask?.cancel(); watchTask = nil
        watchProcess?.terminate(); watchProcess = nil
        reconcileTask?.cancel(); reconcileTask = nil
        countdownTask?.cancel(); countdownTask = nil
        detectorClaimTask?.cancel(); detectorClaimTask = nil
        if ownsDetectorLock {
            DetectorLock.release()
            ownsDetectorLock = false
        }
        services = nil
        handledCalls.removeAll()
    }

    /// Spawn the watch loop and start the reconciler — only ever called while
    /// `ownsDetectorLock` is true (initial start, or a later takeover).
    private func beginWatching(_ s: WidgetBackgroundServices) {
        spawnWatchLoop(s)
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcileCycle(s)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: (a) meet42 watch stream — event-driven, zero polling

    /// Keep a long-lived `meet42 watch` child alive for the agent's lifetime,
    /// respawning (after a brief backoff) if it ever exits unexpectedly.
    /// Dedup by callId backstops any duplicate re-detection across a respawn.
    private func spawnWatchLoop(_ s: WidgetBackgroundServices) {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runWatchOnce(s)
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Spawn `meet42 watch` as a DETACHED process (not via `WidgetShellService`
    /// — it's bounded to a 10s timeout and `watch` never exits on its own) and
    /// consume its line-delimited JSON stdout until it dies, then return so the
    /// caller's loop respawns it.
    private func runWatchOnce(_ s: WidgetBackgroundServices) async {
        let (exe, args) = Self.meet42Invocation(verb: "watch")
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // discard — meet42 watch logs via Meet42Trace

        do {
            try process.run()
        } catch {
            return
        }
        watchProcess = process

        // AsyncLineSequence throws on an I/O error (e.g. the pipe closing
        // when the child dies) — that's just our cue to fall through and let
        // the caller's loop respawn it, not a real failure to surface.
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                await handleWatchLine(line, s)
            }
        } catch {
            // Pipe closed / read error — fall through to respawn.
        }
        watchProcess = nil
    }

    private func handleWatchLine(_ line: String, _ s: WidgetBackgroundServices) async {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String,
              let callId = obj["callId"] as? String
        else { return }
        switch event {
        case "call-open":
            let app = obj["app"] as? String ?? "Call"
            let bundleId = obj["bundleId"] as? String ?? ""
            await onCallOpen(callId: callId, app: app, bundleId: bundleId, s)
        case "call-close":
            await onCallClose(callId: callId, s)
        default:
            break
        }
    }

    /// Resolve a meet42 subcommand invocation: the app's own bundled binary
    /// first (`Contents/MacOS/meet42` — guaranteed same-flavor, matching
    /// `WidgetCommandRunner`'s own PATH-prepend rule), falling back to a PATH
    /// lookup via `/usr/bin/env` for non-bundle dev contexts.
    private static func meet42Invocation(
        verb: String, extraArgs: [String] = []
    ) -> (executable: URL, arguments: [String]) {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/meet42")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return (bundled, [verb] + extraArgs)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["meet42", verb] + extraArgs)
    }

    // MARK: (b) Prompt — once per call session, event-driven

    /// A call-open fires the prompt exactly once (dedup by callId). The
    /// Calendar owns only the pre-session prompt. After a successful handoff,
    /// Transcript owns mic-close behavior and meeting completion.
    private func onCallOpen(callId: String, app: String, bundleId: String, _ s: WidgetBackgroundServices) async {
        guard !handledCalls.contains(callId) else { return }
        handledCalls.insert(callId)

        // Cosmetic only: a matching calendar event NAMES the call and carries
        // dedup (YES/NO) — detection itself is already platform-based and does
        // not depend on this resolving.
        let resolved = await resolveNow(s)
        let title = resolved?.title ?? app
        let subtitle = Self.subtitle(for: resolved, app: app)

        let meeting = DetectedMeeting(
            title: title,
            subtitle: subtitle,
            eventId: resolved?.id,
            existingSessionId: resolved?.sessionId,
            scheduledStart: resolved?.startsAt,
            scheduledEnd: resolved?.endsAt,
            bundleId: bundleId,
            errorMessage: nil,
            countdownStart: Date(),
            onRecord: { [weak self] in self?.startRecording(callId: callId, app: app, bundleId: bundleId, s) },
            onSkip: { [weak self] in self?.skip(callId: callId, s) }
        )
        CalendarDetectionState.shared.phase = .detected(meeting)
        try? await s.pill.present(widgetId: "calendar", sessionId: s.sessionId)
        Meet42Trace.log("detect", "prompt-shown", ["callId": callId, "app": app])

        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            Meet42Trace.log("detect", "auto-start-fired", ["callId": callId])
            self?.startRecording(callId: callId, app: app, bundleId: bundleId, s)
        }
    }

    /// A call-close cancels an undecided Detected prompt, if one is showing.
    /// Once Transcript owns the active meeting pill, close events here are
    /// intentionally ignored.
    private func onCallClose(callId: String, _ s: WidgetBackgroundServices) async {
        guard case .detected = CalendarDetectionState.shared.phase else { return }
        countdownTask?.cancel(); countdownTask = nil
        CalendarDetectionState.shared.phase = .none
        try? await s.pill.dismiss(widgetId: "calendar")
    }

    /// Shell `meet42 now --json`; nil when there is no current/imminent meeting.
    private func resolveNow(_ s: WidgetBackgroundServices) async -> DetectedEventPayload? {
        guard let r = try? await s.shell.run(command: "meet42 now --json"),
              r.exitCode == 0 else { return nil }
        let trimmed = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null", let data = trimmed.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DetectedEventPayload.self, from: data)
    }

    // MARK: (c) Start sequence — RECORD FIRST, session comes after

    /// Start an app-owned recording, show Calendar's setup loader, seed or mint
    /// the event session in the background, then hand the pill to Transcript.
    private func startRecording(callId: String, app: String, bundleId: String, _ s: WidgetBackgroundServices) {
        countdownTask?.cancel(); countdownTask = nil
        guard case .detected(let meeting) = CalendarDetectionState.shared.phase else { return }
        Task { [weak self] in
            guard let self else { return }

            // Start first so capture is live before the slower session work.
            // The Work42 app PID owns this automatic recording; app exit is
            // the recorder's only implicit finalization condition.
            let recording: RecordStartResult
            switch await Self.fireRecordStart(
                app: app, bundleId: bundleId, ownerPid: getpid()
            ) {
            case .started(let r):
                recording = r
            case .refused(let refusal):
                Meet42Trace.log("detect", "start-aborted",
                    ["callId": callId, "reason": "record-refused", "owner": refusal.owner])
                self.showFailure(meeting, message: "Recording is already in use")
                return
            case nil:
                Meet42Trace.log("detect", "start-aborted", ["callId": callId, "reason": "record-start-timeout"])
                self.showFailure(meeting, message: "Couldn't start recording")
                return
            }
            Meet42Trace.log("detect", "record-started", ["callId": callId, "recordingId": recording.recordingId])
            CalendarDetectionState.shared.phase = .settingUp

            let startedAt = ISO8601DateFormatter().string(from: Date())
            let metadata = Self.meetingMetadata(
                meeting: meeting, app: app, bundleId: bundleId,
                recordingDir: recording.dir, startedAt: startedAt
            )

            let sessionId: String
            if let existing = meeting.existingSessionId {
                guard await Self.seedExistingSession(
                    existing, metadata: metadata, shell: s.shell
                ) else {
                    await Self.stopRecording(recording.dir, shell: s.shell)
                    self.showFailure(meeting, message: "Couldn't prepare the session")
                    return
                }
                sessionId = existing
            } else {
                let name = "\(meeting.title) — \(Self.friendlyStamp(Date()))"
                guard let started = await Self.mintEventSession(
                    name: name, eventId: meeting.eventId, storage: metadata
                ) else {
                    Meet42Trace.log("detect", "start-aborted", ["callId": callId, "reason": "mint-failed"])
                    await Self.stopRecording(recording.dir, shell: s.shell)
                    self.showFailure(meeting, message: "Couldn't create the session")
                    return
                }
                sessionId = started.sessionId
            }
            Meet42Trace.log("detect", "session-resolved", ["callId": callId, "sessionId": sessionId])

            do {
                // Present swaps the currently mounted Calendar pill for the
                // session-owned Transcript pill without selecting that session.
                try await s.pill.present(widgetId: "transcript", sessionId: sessionId)
            } catch {
                await Self.stopRecording(recording.dir, shell: s.shell)
                self.showFailure(meeting, message: "Couldn't open the meeting pill")
                return
            }
            CalendarDetectionState.shared.phase = .none
            try? await s.pill.dismiss(widgetId: "calendar")
            Meet42Trace.log("detect", "pill-presented", ["callId": callId, "sessionId": sessionId])
        }
    }

    /// `meet42 record start`'s pre-daemonize stdout line (printed BEFORE
    /// RecordCommand's execve, so it appears well under 1s regardless of the
    /// slow capture init that follows).
    private struct RecordStartResult: Decodable {
        let recordingId: String
        let dir: String
    }

    /// `meet42 record start`'s refusal payload when the machine-wide
    /// singleton is already held — printed to the SAME stdout destination,
    /// just as fast, when a recording can't start.
    private struct RecordStartRefusal: Decodable {
        let started: Bool
        let reason: String
        let owner: String
    }

    private enum RecordStartOutcome {
        case started(RecordStartResult)
        case refused(RecordStartRefusal)
    }

    /// Launch the daemonizing recorder and await only its first JSON line.
    private static func fireRecordStart(
        app: String, bundleId: String, ownerPid: Int32
    ) async -> RecordStartOutcome? {
        let (exe, args) = Self.meet42Invocation(verb: "record", extraArgs: [
            "start", "--app", app, "--bundle-id", bundleId,
            "--owner-pid", String(ownerPid), "--json",
        ])
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let waiter = FirstLineProcessOutput()
        guard let data = await waiter.read(from: outPipe, timeout: 5) else {
            process.terminate()
            return nil
        }
        if let result = try? JSONDecoder().decode(RecordStartResult.self, from: data) {
            return .started(result)
        }
        if let refusal = try? JSONDecoder().decode(RecordStartRefusal.self, from: data) {
            return .refused(refusal)
        }
        process.terminate()
        return nil
    }

    /// "Chrome — Oct 2, 2:14 PM" — the name fed to `work42 session start
    /// --name` for an ad-hoc mint. Must be unique per call (not just per app)
    /// since SessionMint derives the session id deterministically from the
    /// name; a constant name would keep resolving to the same old session.
    private static func friendlyStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    /// Resolve the bundled `work42` binary the same way `meet42Invocation`
    /// resolves `meet42` — same-flavor bundle lookup first, PATH fallback for
    /// non-bundle dev contexts.
    private static func work42Invocation(
        extraArgs: [String]
    ) -> (executable: URL, arguments: [String]) {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/work42")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return (bundled, extraArgs)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["work42"] + extraArgs)
    }

    /// Mint a fresh event session without selecting it in the app. The CLI has
    /// its own timeout, so this detached process always exits and can be
    /// awaited directly without temp-file polling.
    private static func mintEventSession(
        name: String, eventId: String?, storage: [(key: String, json: String)]
    ) async -> SessionStartResult? {
        var args = [
            "session", "start", "--background", "--type", "event",
            "--name", name, "--json", "--timeout", "40",
        ]
        for item in storage {
            args += ["--storage", "\(item.key)=\(item.json)"]
        }
        if let eventId {
            args += ["--arg", "event_id=\(eventId)"]
        }
        let (exe, arguments) = Self.work42Invocation(extraArgs: args)
        guard let (status, data) = await runToCompletion(
            executable: exe, arguments: arguments
        ), status == 0 else { return nil }
        return try? JSONDecoder().decode(SessionStartResult.self, from: data)
    }

    private static func runToCompletion(
        executable: URL, arguments: [String]
    ) async -> (Int32, Data)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, data))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }

    private static func meetingMetadata(
        meeting: DetectedMeeting, app: String, bundleId: String,
        recordingDir: String, startedAt: String
    ) -> [(key: String, json: String)] {
        var values = [
            ("meeting/recording_dir", jsonString(recordingDir)),
            ("meeting/started_at", jsonString(startedAt)),
            ("meeting/title", jsonString(meeting.title)),
            ("meeting/source_app", jsonString(app)),
            ("meeting/source_bundle_id", jsonString(bundleId)),
        ]
        if let start = meeting.scheduledStart, let end = meeting.scheduledEnd {
            let formatter = ISO8601DateFormatter()
            values += [
                ("meeting/scheduled_start", jsonString(formatter.string(from: start))),
                ("meeting/scheduled_end", jsonString(formatter.string(from: end))),
            ]
        }
        return values
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func seedExistingSession(
        _ sessionId: String,
        metadata: [(key: String, json: String)],
        shell: any WidgetShellService
    ) async -> Bool {
        for item in metadata {
            let result = try? await shell.run(
                command: "work42 storage set --session \(calShellQuote(sessionId)) "
                    + "\(calShellQuote(item.key)) \(calShellQuote(item.json))"
            )
            guard result?.exitCode == 0 else { return false }
        }
        return true
    }

    private static func stopRecording(_ dir: String, shell: any WidgetShellService) async {
        let command = "meet42 record stop --dir \(calShellQuote(dir))"
        let result = try? await shell.run(command: command)
        guard result?.exitCode != 0 else { return }
        // The CLI only creates this marker. Fall back to the same signal if
        // shell dispatch itself failed so setup failure cannot orphan capture.
        let marker = (dir as NSString).appendingPathComponent(".meet42-record-stop")
        _ = FileManager.default.createFile(atPath: marker, contents: Data())
    }

    private func showFailure(_ meeting: DetectedMeeting, message: String) {
        countdownTask?.cancel(); countdownTask = nil
        CalendarDetectionState.shared.phase = .detected(DetectedMeeting(
            title: meeting.title,
            subtitle: meeting.subtitle,
            eventId: meeting.eventId,
            existingSessionId: meeting.existingSessionId,
            scheduledStart: meeting.scheduledStart,
            scheduledEnd: meeting.scheduledEnd,
            bundleId: meeting.bundleId,
            errorMessage: message,
            countdownStart: Date(),
            onRecord: meeting.onRecord,
            onSkip: meeting.onSkip
        ))
    }

    /// No — permanently dismiss for this call session; a genuinely new call
    /// (new callId) prompts again.
    private func skip(callId: String, _ s: WidgetBackgroundServices) {
        Meet42Trace.log("detect", "no", ["callId": callId])
        countdownTask?.cancel(); countdownTask = nil
        Task { [weak self] in await self?.clearAndDismiss(s) }
    }

    private func clearAndDismiss(_ s: WidgetBackgroundServices) async {
        CalendarDetectionState.shared.phase = .none
        try? await s.pill.dismiss(widgetId: "calendar")
    }

    // MARK: (b) Reconciler — assisted events → work42 scheduler

    /// Sync assisted calendar events into work42's generic scheduler: schedule a
    /// session start at T-15min under a stable `mtg:<id>` key (idempotent add),
    /// and cancel keys for events that are no longer assisted / gone.
    private func reconcileCycle(_ s: WidgetBackgroundServices) async {
        // Effective mode per event: event override → calendar default → view_only.
        guard let modes = await fetchModes(s) else { return }
        let events = await fetchEvents(s)

        var desired: Set<String> = []
        for e in events {
            let mode = modes.events[e.id] ?? modes.calendars[e.calendarId] ?? .viewOnly
            guard mode == .assisted else { continue }
            let key = "mtg:\(e.id)"
            desired.insert(key)
            let at = e.startsAt.addingTimeInterval(-15 * 60)
            let iso = ISO8601DateFormatter().string(from: at)
            // add is idempotent on --key — re-adding replaces the entry.
            _ = try? await s.shell.run(
                command: "work42 schedule add --type event"
                    + " --at \(calShellQuote(iso))"
                    + " --arg event_id=\(calShellQuote(e.id))"
                    + " --key \(calShellQuote(key))"
            )
        }

        // Cancel keys we previously added that are no longer desired.
        for key in scheduledKeys.subtracting(desired) {
            _ = try? await s.shell.run(command: "work42 schedule cancel --key \(calShellQuote(key))")
        }
        scheduledKeys = desired
    }

    private func fetchModes(_ s: WidgetBackgroundServices) async -> ModesPayload? {
        guard let r = try? await s.shell.run(command: "meet42 modes get --json"),
              r.exitCode == 0, let data = r.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ModesPayload.self, from: data)
    }

    private func fetchEvents(_ s: WidgetBackgroundServices) async -> [CalEvent] {
        let iso = ISO8601DateFormatter()
        let from = Date()
        let to = Calendar.current.date(byAdding: .day, value: 30, to: from) ?? from
        let cmd = "meet42 list --from \(calShellQuote(iso.string(from: from)))"
            + " --to \(calShellQuote(iso.string(from: to))) --json"
        guard let r = try? await s.shell.run(command: cmd), r.exitCode == 0,
              let data = r.stdout.data(using: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([CalEvent].self, from: data)) ?? []
    }

    // MARK: Subtitle

    /// "<app> · <time range>" when a calendar event matched (purely cosmetic
    /// naming — detection is platform-based, not calendar-based), else just
    /// the app name.
    private static func subtitle(for event: DetectedEventPayload?, app: String) -> String {
        guard let event else { return app }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let range = "\(f.string(from: event.startsAt)) – \(f.string(from: event.endsAt))"
        return "\(app) · \(range)"
    }
}

// MARK: - CLI decode targets (start sequence)

/// Reads exactly the recorder's pre-daemonize JSON line without waiting for
/// the long-lived child process to close stdout.
private nonisolated final class FirstLineProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var continuation: CheckedContinuation<Data?, Never>?
    private weak var handle: FileHandle?

    func read(from pipe: Pipe, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.handle = pipe.fileHandleForReading
            lock.unlock()

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.receive(handle.availableData)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            lock.lock()
            let partial = buffer.isEmpty ? nil : buffer
            lock.unlock()
            finish(partial)
            return
        }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        buffer.append(data)
        let newline = buffer.firstIndex(of: 0x0A)
        let line = newline.map { Data(buffer[..<$0]) }
        lock.unlock()
        if let line { finish(line) }
    }

    private func finish(_ result: Data?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        handle?.readabilityHandler = nil
        continuation?.resume(returning: result)
    }
}

/// Decode target for `work42 session start --type event --json`.
private struct SessionStartResult: Decodable {
    let sessionId: String
    let ownerDir: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case ownerDir = "owner_dir"
    }
}

// MARK: - CalendarWidget

@Observable
@MainActor
final class CalendarWidget: Work42Widget, Work42WidgetPill, Work42WidgetBackground {
    let id = "calendar"
    let title = "Calendar"
    let icon = "calendar"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 420, height: 360) }

    // MARK: - Shared store (drives both the view and the action-area intents)

    /// Created in `activate(services:)`, torn down in `deactivate()`. Nil until
    /// activate fires; `CalendarRootView` shows a ProgressView while nil.
    private(set) var store: CLICalendarStore?

    /// Observed by `CalendarRootView` to present the CalendarSettingsPopover when
    /// the ⚙ action-area intent fires. The view resets this to false on dismiss.
    var settingsOpen: Bool = false

    @ObservationIgnored private var activatedServices: SessionServices?

    // MARK: - Work42Widget lifecycle

    func activate(services: SessionServices) {
        activatedServices = services
        let s = CLICalendarStore(services: services)
        store = s
        s.start()
    }

    func deactivate() {
        store?.stop()
        store = nil
        activatedServices = nil
        settingsOpen = false
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(CalendarRootView(widget: self))
    }

    // MARK: - Action-area intents (AC8 — controls moved out of the widget body)
    //
    // Five intents matching the pre-conversion HomeView.actionAreaIntents calendar
    // controls: a view-mode menu, previous/today/next navigation, and settings.
    // All carry `placement: [.actionArea]` so they appear in the tab-bar row
    // beside "Add Widget" while this widget is active — NOT inside the widget body.

    var intents: [WidgetIntentSpec] {
        [
            // ── 1. View mode — Day / Week / Agenda ────────────────────────────
            WidgetIntentSpec(
                name: "viewMode",
                title: "View",
                icon: "calendar",
                placement: [.actionArea],
                actionAreaStyle: .menu(
                    options: { [weak self] in
                        guard let self, let store = self.store else { return [] }
                        return CLICalendarStore.ViewMode.allCases.map { mode in
                            WidgetIntentMenuOption(
                                id: mode.rawValue,
                                title: mode.label,
                                isSelected: store.viewMode == mode
                            )
                        }
                    },
                    onSelect: { [weak self] rawValue in
                        guard let self, let store = self.store,
                              let mode = CLICalendarStore.ViewMode(rawValue: rawValue)
                        else { return }
                        store.setViewMode(mode)
                    }
                ),
                perform: {}      // action-area menu — palette invocation is a no-op
            ),

            // ── 2. Previous ───────────────────────────────────────────────────
            WidgetIntentSpec(
                name: "previous",
                title: "Previous",
                icon: "chevron.left",
                placement: [.actionArea],
                actionAreaStyle: .icon,
                isEnabled: { [weak self] in self?.store?.viewMode != .agenda },
                perform: { [weak self] in self?.store?.goToPrevious() }
            ),

            // ── 3. Today ──────────────────────────────────────────────────────
            // Uses `.pill` style — the WidgetIntentActionAreaStyle docs explicitly
            // cite "Today" as the example of a text-only pill control.
            WidgetIntentSpec(
                name: "today",
                title: "Today",
                icon: "clock",
                placement: [.actionArea],
                actionAreaStyle: .pill,
                perform: { [weak self] in self?.store?.goToToday() }
            ),

            // ── 4. Next ───────────────────────────────────────────────────────
            WidgetIntentSpec(
                name: "next",
                title: "Next",
                icon: "chevron.right",
                placement: [.actionArea],
                actionAreaStyle: .icon,
                isEnabled: { [weak self] in self?.store?.viewMode != .agenda },
                perform: { [weak self] in self?.store?.goToNext() }
            ),

            // ── 5. Settings ⚙ ────────────────────────────────────────────────
            // Replicates the pre-conversion HomeView settings gear: sets
            // `settingsOpen = true` so CalendarRootView presents the per-calendar
            // AI assistance popover (CalendarSettingsPopover) anchored inside the
            // widget body. The popover itself stays host-rendered (not action-area)
            // because it requires a visual anchor point in the widget surface.
            WidgetIntentSpec(
                name: "settings",
                title: "Calendar Settings",
                icon: "gearshape",
                placement: [.actionArea],
                actionAreaStyle: .icon,
                perform: { [weak self] in self?.settingsOpen = true }
            ),
        ]
    }

    // MARK: Work42WidgetBackground — the mic-wake detector + scheduler reconciler.

    func makeBackgroundAgent() -> any WidgetBackgroundAgent { CalendarDetectionAgent() }

    // MARK: Work42WidgetPill — DETECTED accessory when the agent flags a meeting,
    // else the compact "next N events" agenda.

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(CalendarPillRouter(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            // Matches DetectedPillView's actual rendered size (412 wide,
            // ~108 tall) — a mismatched preferredSize leaves dead space
            // until the live onPreferenceChange resize catches up.
            // SettingUpPillView reports its own (narrower) size, and the
            // host panel live-resizes between the two automatically.
            preferredSize: WidgetMinSize(width: 412, height: 108),
            title: title,
            icon: icon
        )
    }
}

// MARK: - CalendarRootView

private struct CalendarRootView: View {
    /// The owning CalendarWidget provides the shared CLICalendarStore (populated
    /// in activate(services:)) and the settingsOpen flag the ⚙ intent writes to.
    let widget: CalendarWidget

    var body: some View {
        Group {
            if let store = widget.store {
                VStack(alignment: .leading, spacing: 0) {
                    header(store)
                    DT.systemAccent.opacity(0.25).frame(height: 1)
                    content(store)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Invisible 0×0 anchor for the settings popover opened by the ⚙
                // action-area intent (CalendarWidget.intents last entry). The popover
                // needs a visual anchor inside the widget body even though its trigger
                // lives in the action area.
                .overlay(alignment: .topTrailing) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .popover(
                            isPresented: Binding(
                                get: { widget.settingsOpen },
                                set: { widget.settingsOpen = $0 }
                            ),
                            arrowEdge: .top
                        ) {
                            CalendarSettingsPopover(
                                choices: store.calendarChoices,
                                setMode: { id, mode in store.setCalendarMode(id, mode) }
                            )
                        }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Header (display-only — all controls moved to action-area intents)
    //
    // The Day/Week/Agenda picker, Previous/Today/Next nav buttons, and the ⚙
    // settings button have been removed from this header; they now render as
    // CalendarWidget.intents in the tab-bar action area (AC8). What remains is
    // the date/period context and event count — read-only display.

    private func header(_ store: CLICalendarStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text(subtitle(store))
                .font(.system(size: DT.f10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DT.s16)
        .padding(.top, DT.s12)
        .padding(.bottom, DT.s8)
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
