// Plugin.swift — meet42's compiled onCreate session hook
// (meet42-plugin-conversion, M2/s11).
//
// Reproduces the POST-worktree side effect of the built-in event seeder this
// plugin replaces (work42/Sources/Work42App/Sessions/SessionSeeders.swift's
// "event" seeder: MeetingMeta.write + PeopleStore.upsertAttendees). A plugin
// hooks dylib links only Work42PluginKit, so it cannot reach the calendar
// model directly — and by design it must not: all privileged calendar work
// lives in the standalone `meet42` CLI. The hook shells `meet42 snapshot`,
// which reads meet42's OWN calendar store and writes meeting.json + upserts
// attendees into meet42's OWN people store (see the meet42-seed-flow artifact).
//
// `meeting/event_id` is NOT written here — it's seeded declaratively from
// session-types/event.json's `args` (SessionMint's generic arg->storage path)
// before onCreate ever runs. This hook only consumes that same `event_id` from
// `context.params` to decide whether to snapshot.
//
// onCreate fires only on a genuinely new session insert (SessionMint
// .finishMint's `guard inserted else { return }`), never on a re-mint — so the
// snapshot runs exactly once per event session.

import Foundation
import Work42PluginKit

final class Meet42Hooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        // Ad-hoc event (no calendar event_id): nothing to snapshot — the
        // session just opens empty on the Brief tab.
        guard case .string(let eventId)? = context.params["event_id"],
              !eventId.isEmpty else { return }

        let command = "meet42 snapshot \(shellQuote(eventId)) "
            + "--session-dir \(shellQuote(context.worktreePath)) --json"
        let result = try await context.shell.run(command: command)
        guard result.exitCode == 0 else {
            throw WidgetServiceError(
                message: "meet42 snapshot failed (exit \(result.exitCode)): \(result.stderr)",
                suggestion: "grant meet42 Calendar access (meet42 sync), or check the event id exists"
            )
        }

        // Link the new session back to its calendar event so `meet42 now --json`
        // surfaces a non-nil `sessionId`/`sessionDir` for this event. This is
        // the dedup hook: both the detection pill's YES path and the T-15
        // reconciler go through onCreate, so both link via this single write.
        // `--session-dir` lets a LATER detection resolve this session's
        // worktree directory (there is no other way to look up an arbitrary
        // session's directory by id), so the detection agent's YES path can
        // `meet42 record start --session-dir <dir>` into it. Fire-and-forget:
        // a failed link means the NEXT detection creates a second session
        // (accepted risk, not a fatal error for the session itself).
        let linkCommand = "meet42 link-session \(shellQuote(eventId)) \(shellQuote(context.sessionId))"
            + " --session-dir \(shellQuote(context.worktreePath))"
        _ = try? await context.shell.run(command: linkCommand)
    }
}

/// POSIX single-quote shell escaping for a value interpolated into a
/// `/bin/sh -c` command line (`WidgetCommandRunner`, the host's shell backend)
/// — wraps in single quotes, escaping an embedded `'` as `'\''`.
private nonisolated func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Plugin entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects (mirrors every
// widget's work42_widget_main/work42_widget_sdk_version pair).

@_cdecl("work42_plugin_sdk_version")
public func work42_plugin_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_plugin_main")
public func work42_plugin_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = PluginEntryPoint.register(Meet42Hooks())
    }
    return result
}
