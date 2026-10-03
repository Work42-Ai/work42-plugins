// meet42 — the standalone, open-source macOS calendar + meeting-capture CLI.
//
// Manual arg dispatch (no ArgumentParser). Read verbs go through the ported
// Meet42Kit `CalendarStore`; `sync` drives Meet42CalendarSync; `record`
// drives Meet42Capture. stdout carries verb output (JSON with `--json`, else
// human text); all diagnostics go to stderr.

import Foundation

let meet42Version = "0.1.0"

let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
let rest = Array(argv.dropFirst(2))

await Dispatcher.run(command: command, args: rest)

@MainActor
enum Dispatcher {

    static func run(command: String, args: [String]) async {
        switch command {
        case "list":     ReadCommands.list(args: args)
        case "today":    ReadCommands.today(args: args)
        case "next":     ReadCommands.next(args: args)
        case "show":     ReadCommands.show(args: args)
        case "now":      ReadCommands.now(args: args)
        case "snapshot":      DataCommands.snapshot(args: args)
        case "link-session":  DataCommands.linkSession(args: args)
        case "people":        DataCommands.people(args: args)
        case "mics":     MicsCommand.mics(args: args)
        case "watch":    WatchCommand.watch(args: args)   // never returns
        case "modes":    DataCommands.modes(args: args)
        case "sync":     await SyncCommand.sync(args: args)
        case "record":   await RecordCommand.record(args: args)
        case "trace":    TraceCommand.trace(args: args)
        case "version", "--version", "-v":
            print("meet42 v\(meet42Version)")
        case "help", "--help", "-h", "":
            printUsage()
        default:
            CLI.warn("meet42: unknown command: \(command)")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        meet42 v\(meet42Version) — calendar + meeting-capture CLI

        Usage: meet42 <command> [options]

        Every read verb accepts --json; each event payload carries the event `id`.

        Calendar reads:
          list [--from <iso>] [--to <iso>] [--source <id>] [--json]
                List events in a window. Defaults to today.
          today [--json]
                Events between local midnight and +24h.
          next [--json]
                The next upcoming (non-canceled) event, or null.
          show <eventId|next> [--json]
                Full details for one event.
          now [--json]
                The current meeting ([startsAt−5m, endsAt] contains now)
                or the next one starting within ~5 min; null if neither.

        Sessions / people:
          snapshot <eventId> --session-dir <dir> [--json]
                Write meeting.json for the event + seed the people graph.
          link-session <eventId> <sessionId> [--json]
                Link a work42 session back to its calendar event so
                `meet42 now` surfaces the existing sessionId for dedup.
                Idempotent — safe to call multiple times for the same eventId.
          people (--session-dir <dir> | --meeting-json <path>) [--json]
                Attendee profiles (shared-meeting counts) from the snapshot.

        Audio / modes:
          mics [--json]
                List microphone input devices for the mic picker.
          mics select <uid>
                Persist a microphone selection (writes
                ~/.work42/meet42/mic-input-device.json).
          watch [--json]
                Long-lived; emits {"event":"mic-open"} / {"event":"mic-close"}
                line-delimited JSON on default-input transitions.
          modes get [--json]
                Per-calendar / per-event assistance flags.
          modes set <calendar|event> <id> <view_only|assisted|ai_scheduled>
                Set an assistance flag.

        Sync / capture:
          sync
                Request Calendar access + run one full EventKit sync.
          record start [--dir <dir>] [--device <uid>] [--app <name>]
                       [--bundle-id <id>] [--owner-pid <pid>] [--manual] [--json]
                Session-agnostic: allocates its OWN recordings dir under
                ~/.work42/meet42/recordings/<recordingId>/ (or uses --dir if
                given), daemonizes, and captures (transcription +
                diarization) there. Prints {"recordingId","dir","started"}
                on stdout BEFORE daemonizing, so a caller gets the path
                immediately. Machine-wide singleton: refuses if a recording
                is already active elsewhere. --app/--bundle-id label the
                claim (for `record status`); default --app is "Manual".
                --owner-pid ties an auto-detected capture to its Work42 app
                process so app exit finalizes it. --manual omits ownership and
                continues until an explicit `record stop`.
          record stop [--dir <dir>]
                Signal the capture daemon to finalize and exit. --dir
                defaults to the active recording's dir when omitted.
          record status [--json]
                Print whether a recording is active and, if so, its
                recordingId/dir/app/startedAt/ownerPid — the single source of truth
                every surface reads instead of session storage.

        Diagnostics:
          trace [--tail N] [--call <callId>] [--json]
                Pretty-print the last N pipeline events from
                ~/.work42/meet42/trace.jsonl (default --tail 50).
                --call <id> filters to one call session.
                --json emits raw JSON lines. Reads always work regardless
                of the MEET42_TRACE=0 env var (which only gates writes).

          version | --version
          help | --help

        Data lives under:
          ~/.work42/meet42/calendar.db    (calendar mirror)
          ~/.work42/meet42/modes.json     (assistance flags)
          ~/.work42/meet42/trace.jsonl    (pipeline trace log)
          ~/.work42/peers42/people.db     (people graph)
        """)
    }
}
