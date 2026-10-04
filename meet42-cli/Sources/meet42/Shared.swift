// Shared.swift — small helpers shared across the meet42 CLI verbs.
//
// Manual arg dispatch, no ArgumentParser. stdout carries verb output
// (JSON / human text); every diagnostic goes to stderr. JSON is encoded
// with sorted keys + ISO-8601 dates, matching the old CLI.

import Foundation
import Meet42Kit

enum CLI {

    // MARK: - stderr diagnostics

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        warn(message)
        exit(code)
    }

    // MARK: - Arg parsing

    static func argValue(_ args: [String], _ name: String) -> String? {
        guard let idx = args.firstIndex(of: name),
              idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func wantsJSON(_ args: [String]) -> Bool { args.contains("--json") }

    /// First non-flag argument (positional), so `--json` may appear before
    /// or after it.
    static func firstPositional(_ args: [String]) -> String? {
        args.first { !$0.hasPrefix("-") }
    }

    /// All non-flag arguments, in order.
    static func positionals(_ args: [String]) -> [String] {
        args.filter { !$0.hasPrefix("-") }
    }

    // MARK: - JSON

    static func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func emitJSON<T: Encodable>(_ value: T) {
        do {
            let data = try jsonEncoder().encode(value)
            print(String(data: data, encoding: .utf8) ?? "null")
        } catch {
            fail("meet42: JSON encoding failed: \(error)", code: 2)
        }
    }

    // MARK: - Dates

    // Computed (fresh instance per access) so the helpers stay nonisolated and
    // concurrency-safe — ISO8601DateFormatter is not Sendable.
    static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static var isoNoFractions: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// ISO-8601 (with fractional seconds) for "now", used for snapshot
    /// timestamps.
    static func nowISO() -> String { iso.string(from: Date()) }

    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        if let d = isoNoFractions.date(from: s) { return d }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        return dayFormatter.date(from: s)
    }

    static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    static func startOfTomorrow() -> Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfToday())
            ?? Date().addingTimeInterval(86_400)
    }

    static func friendlyTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func padded(_ s: String, _ width: Int) -> String {
        if s.count >= width {
            return String(s.prefix(width - 1)) + "…"
        }
        return s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Store access

    /// Open calendar.db read-only, or print a friendly error and exit.
    @MainActor
    static func openReadOnlyStore() -> CalendarStore {
        do {
            return try CalendarStore.openReadOnly()
        } catch {
            warn("meet42: couldn't open calendar.db: \(error)")
            warn("Has the meet42 sync run at least once and granted Calendar access?")
            exit(2)
        }
    }

    // MARK: - Pretty-printing an event (human output)

    static func printEventTable(_ items: [CalendarEvent.Item]) {
        for item in items {
            let line = padded(friendlyTime(item.startsAt), 22)
                + padded(item.title, 40)
                + padded(item.source.rawValue, 10)
                + item.id
            print(line)
        }
    }

    static func printEventDetail(_ item: CalendarEvent.Item) {
        print(item.title)
        print("  When        : \(friendlyTime(item.startsAt)) — \(friendlyTime(item.endsAt))")
        print("  Source      : \(item.source.rawValue)\(item.calendarTitle.map { " (\($0))" } ?? "")")
        print("  Status      : \(item.status.rawValue)")
        if let loc = item.location, !loc.isEmpty {
            print("  Location    : \(loc)")
        }
        if let url = item.meetingURL ?? item.url, !url.isEmpty {
            print("  Join link   : \(url)")
        }
        if let org = item.organizer, !org.isEmpty {
            print("  Organizer   : \(org)")
        }
        if !item.attendees.isEmpty {
            print("  Attendees   :")
            for a in item.attendees {
                let label = a.name ?? a.email ?? "(unknown)"
                let email = (a.email ?? "").isEmpty ? "" : " <\(a.email!)>"
                let star = a.isCurrentUser ? " ★" : ""
                print("    - \(label)\(email) [\(a.status.rawValue)]\(star)")
            }
        }
        print("  Calendar ID : \(item.calendarId)")
        print("  Event ID    : \(item.id)")
        if let notes = item.notes,
           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("  Notes       :")
            for line in notes.split(separator: "\n") {
                print("    \(line)")
            }
        }
    }
}
