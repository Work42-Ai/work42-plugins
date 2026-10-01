# meet42 plugin

The meeting vertical, extracted from work42 into a first-party plugin
(meet42-plugin-conversion, M2). The plugin is **UI + orchestration only** — all
privileged calendar/audio work lives in the standalone [`meet42` CLI](../meet42-cli/)
(its own repo/package, own TCC + Developer ID). The only contract between them
is that CLI: verbs in, JSON/exit-codes out, and files written into a session's
`--session-dir`.

## Contributions

| Kind | What |
|------|------|
| **Workflow** (`workflows/meeting.json`) | `Prepare for Meeting -> In Meeting -> Summary -> Done`, driven entirely by recording-lifecycle storage signals (`meeting/started_at`, `meeting/ended_at`, `meeting/summary`) — no wall-clock timer. Read-only capability rules (local diagnostics + this workflow's own storage-read / transition / artifact verbs + `meet42`); artifact-write allowed while active, blocked at Done. |
| **Session type** (`session-types/event.json`) | `event` type on the `meeting` workflow; 3-tab layout (Brief / Live / Recap) over the plugin's custom widgets; `list_shape: schedule`, `archive_source: meeting`, `self_archives`; the `meet42-prep` session skill; a `new-event` create-intent; an `event_id` string arg seeded to `meeting/event_id`. |
| **Intent** (`intents/new-event.json`) | "New Event" — mints an `event` session (optionally carrying `event_id`). |
| **onCreate hook** (`Sources/Plugin.swift`, s11) | When `event_id` is present, shells `meet42 snapshot <id> --session-dir <dir>` to write `meeting.json` + upsert attendees; no-op for an ad-hoc event. |
| **Widgets** (`widgets/*`, s12-s16) | event-details / transcript / people / annotations / summary / calendar / timeline — render over session files + `meet42` verbs. The transcript widget carries the RECORDING/ENDED pill + auto-record agent; the calendar widget carries the mic-wake detection agent + scheduler reconciler. |
| **Skill** (`skills/meet42-prep`, s13) | Type-scoped briefing skill run in the Prepare-for-Meeting stage. |

## Building

The widgets compile at app-build time against the shipped Widget SDK
(`sdk_version: 10`); the `onCreate` hook compiles into the plugin dylib. See the
work42 app's `scripts/build-work42-app.sh` (wired in s21).
