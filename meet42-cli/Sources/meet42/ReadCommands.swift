// ReadCommands.swift — read-only calendar verbs: list / today / next /
// show / now. All go through the ported Meet42Kit `CalendarStore`
// (read-only open), adapted from the old Flow42Core-based CLI.

import Foundation
import Meet42Kit

@MainActor
enum ReadCommands {

    // MARK: - list

    static func list(args: [String]) {
        let store = CLI.openReadOnlyStore()
        let from = CLI.argValue(args, "--from").flatMap(CLI.parseDate) ?? CLI.startOfToday()
        let to = CLI.argValue(args, "--to").flatMap(CLI.parseDate) ?? CLI.startOfTomorrow()
        let sourceArg = CLI.argValue(args, "--source")
        let source = sourceArg.flatMap { CalendarEvent.Source(rawValue: $0) }
        if let raw = sourceArg, source == nil {
            let known = CalendarEvent.Source.allCases.map(\.rawValue).joined(separator: ", ")
            CLI.fail("meet42: unknown --source '\(raw)'. Use one of \(known).")
        }
        emitEvents(from: from, to: to, source: source, store: store, json: CLI.wantsJSON(args))
    }

    // MARK: - today

    static func today(args: [String]) {
        let store = CLI.openReadOnlyStore()
        emitEvents(
            from: CLI.startOfToday(), to: CLI.startOfTomorrow(),
            source: nil, store: store, json: CLI.wantsJSON(args)
        )
    }

    // MARK: - next

    static func next(args: [String]) {
        let store = CLI.openReadOnlyStore()
        let item: CalendarEvent.Item?
        do {
            item = try store.nextUpcoming()
        } catch {
            CLI.fail("meet42 next: query failed: \(error)", code: 2)
        }
        if CLI.wantsJSON(args) {
            if let item { CLI.emitJSON(item) } else { print("null") }
            return
        }
        guard let item else {
            print("No upcoming events.")
            return
        }
        CLI.printEventDetail(item)
    }

    // MARK: - show

    static func show(args: [String]) {
        guard let target = CLI.firstPositional(args) else {
            CLI.fail("meet42 show: missing <event_id|next>")
        }
        let store = CLI.openReadOnlyStore()
        guard let item = resolve(target, store: store) else {
            CLI.fail("meet42 show: no event matches '\(target)'.")
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(item)
            return
        }
        CLI.printEventDetail(item)
    }

    // MARK: - now
    //
    // The "what meeting is this" resolver for the detection agent: the event
    // whose [startsAt − 5min, endsAt] window contains now, else the next event
    // starting within ~5 minutes. Null/empty when neither exists.

    static func now(args: [String]) {
        let store = CLI.openReadOnlyStore()
        let reference = Date()
        // Pull a generous window around now so a long meeting that started
        // hours ago is still a candidate.
        let windowStart = reference.addingTimeInterval(-12 * 3600)
        let windowEnd = reference.addingTimeInterval(3600)
        let items: [CalendarEvent.Item]
        do {
            items = try store.events(from: windowStart, to: windowEnd)
                .filter { $0.status != .canceled }
        } catch {
            CLI.fail("meet42 now: query failed: \(error)", code: 2)
        }

        let imminentWindow: TimeInterval = 5 * 60
        // Current: window [startsAt − 5min, endsAt] contains now.
        let current = items.first {
            $0.startsAt.addingTimeInterval(-imminentWindow) <= reference
                && reference <= $0.endsAt
        }
        // Imminent: next event starting within the next ~5 minutes.
        let imminent = items.first {
            $0.startsAt > reference
                && $0.startsAt <= reference.addingTimeInterval(imminentWindow)
        }
        let chosen = current ?? imminent

        if CLI.wantsJSON(args) {
            if let chosen { CLI.emitJSON(chosen) } else { print("null") }
            return
        }
        guard let chosen else {
            print("No current or imminent meeting.")
            return
        }
        CLI.printEventDetail(chosen)
    }

    // MARK: - Helpers

    static func resolve(_ raw: String, store: CalendarStore) -> CalendarEvent.Item? {
        if raw == "next" {
            return (try? store.nextUpcoming()) ?? nil
        }
        return (try? store.event(id: raw)) ?? nil
    }

    private static func emitEvents(
        from: Date, to: Date,
        source: CalendarEvent.Source?,
        store: CalendarStore,
        json: Bool
    ) {
        let items: [CalendarEvent.Item]
        do {
            items = try store.events(from: from, to: to, source: source)
        } catch {
            CLI.fail("meet42: query failed: \(error)", code: 2)
        }
        if json {
            CLI.emitJSON(items)
            return
        }
        if items.isEmpty {
            print("No events in \(CLI.friendlyTime(from)) — \(CLI.friendlyTime(to)).")
            return
        }
        CLI.printEventTable(items)
    }
}
