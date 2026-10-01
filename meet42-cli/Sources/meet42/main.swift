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
        case "snapshot": DataCommands.snapshot(args: args)
        case "people":   DataCommands.people(args: args)
        case "mics":     MicsCommand.mics(args: args)
        case "watch":    WatchCommand.watch(args: args)   // never returns
        case "modes":    DataCommands.modes(args: args)
        case "sync":     await SyncCommand.sync(args: args)
        case "record":   await RecordCommand.record(args: args)
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
          people (--session-dir <dir> | --meeting-json <path>) [--json]
                Attendee profiles (shared-meeting counts) from the snapshot.

        Audio / modes:
          mics [--json]
                List microphone input devices for the mic picker.
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
          record start --session-dir <dir> [--device <uid>]
                Daemonize and capture (transcription + diarization).
          record stop --session-dir <dir>
                Signal the capture daemon to finalize and exit.

          version | --version
          help | --help

        Data lives under:
          ~/.work42/meet42/calendar.db   (calendar mirror)
          ~/.work42/meet42/modes.json    (assistance flags)
          ~/.work42/peers42/people.db    (people graph)
        """)
    }
}
