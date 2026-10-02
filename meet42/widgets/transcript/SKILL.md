---
name: widget-transcript
description: |
  How the Transcript widget (session tab kindId widget:transcript) works on a
  meet42 meeting session. It renders the live meeting transcript as chat
  bubbles and owns the RECORDING / ENDED / idle recording pill. It has no
  background agent — `meet42 record` (the session-agnostic recording daemon)
  owns its own stop; this widget reads the recording via a storage pointer,
  drives the manual Record/Stop controls, and reconciles its pill across
  relaunch.
---

# Transcript widget

A tile + a stateful pill. No background agent — `meet42 record`
(meet42-recording-lifecycle-rework) is a session-agnostic primitive that owns
its OWN recordings directory and its OWN stop (it self-watches its trigger
call and self-stops independent of this widget, the calendar widget, or the
app being alive at all). This session's storage just holds a POINTER
(`meeting/recording_dir`) at that directory, seeded either by the calendar
widget's detection agent (auto-detected calls) or by this widget's own manual
Record intent. This widget reads the transcript from that pointer, renders
recording truth from it, and drives the manual Record/Stop action-area
intents.

## Tile

Renders `<meeting/recording_dir>/conversation.jsonl` live as chat bubbles,
reloaded via a ~0.5s file watcher as the capture daemon appends lines. The
pointer itself is resolved once per tile mount (a ~1s poll loop that stops the
moment it finds a non-nil value — handles both the common case, where the
pointer is already seeded before the tile ever mounts, and opening the tile
on a plain session BEFORE Record has been clicked). Each utterance becomes a
Work42UI `ChatBubble`:

- `"You"` (mic) → trailing / accent bubble.
- `"Them"` (system audio) → leading bubble; neutral grey until the speaker is
  MATCHED to a person in the optional `speakers.json` sidecar, then painted with
  that person's stable palette color (avatar + name + bubble tint).
- unknown speaker → leading / neutral.

System-event lines (`{"type":"system_event", …}`) render as centered cards
(app name + OCR text + timestamp). The image thumbnail the app showed is
omitted (loading a file image needs AppKit/ImageIO, outside a plugin widget's
allowed imports). An empty transcript shows a "Waiting to listen…" state.

The app's "who is this?" speaker-resolver popover is dropped (it required
Flow42Core's `PeopleStore`); the avatar is inert here.

## Session files

| File | Access | Description |
|------|--------|-------------|
| `<meeting/recording_dir>/conversation.jsonl` | read-only | Append-only transcript. Speaker line: `{ "ts", "speaker": "You"\|"Them", "text", "lineId", "speakerLabel"? }`; system-event line: `{ "ts", "type":"system_event", "event", "app"?, "ocr_text"?, "rect" }` (a missing `type` ⇒ speaker line). Written by meet42's `MeetingTranscriptionEngine` into the RECORDING's own directory — NOT the session's worktree. |
| `<meeting/recording_dir>/speakers.json` | read-only | Optional `{ "<speakerKey>": "<Name>" }` or `{ "<speakerKey>": { "person_id", "name" } }` sidecar mapping speaker keys to display names. |
| `<session worktree>/meeting.json` | read-only | Read only for the meeting title shown on the pill — this one IS session-worktree-scoped (seeded by the plugin's `onCreate` from the matched calendar event), unrelated to the recording. |

## Recording truth

`meet42 record status` is session-agnostic (meet42-recording-lifecycle-rework
s1) — it reports the active recording's own `dir`, not a session id or
worktree slug. The widget reads its OWN session's `meeting/recording_dir`
pointer and `meeting/started_at` via **`services.storage.get`** — the SDK's
native `WidgetStorageService`, NOT the shelled `work42 storage get` CLI. This
matters: for a non-task session (exactly what an "event" meeting session is),
`WidgetCommandRunner` used to inject `WORK42_SESSION_DIR` as the session's
WORKTREE path, but `storage.json` actually lives in the chat-session metadata
directory — a work42-core bug in `SessionDiscovery`/`StorageCommand` that
made the shelled CLI resolve the wrong file for a non-task session (confirmed
live; fixed in the work42 repo, s6 — `WidgetCommandRunner.Context` now carries
a separate `sessionDirectory` field injected as `WORK42_SESSION_DIR`,
distinct from the worktree used for `cwd`). `services.storage` sidesteps the
whole question regardless — it's backed directly by `SessionStorageBackend
(sessionDirectory: resolved.sessionDirectory)`, the CORRECT directory, no
shell/CLI indirection at all — but `meeting/recording_dir`/`started_at`/
`ended_at` all live in the `meeting` namespace, NOT this widget's own
`transcript` namespace, so WRITING them (see Manual Record/Stop below) still
has to go through the shelled CLI (`services.storage.set` is restricted to a
widget's own namespace) — now safe post-s6. The widget compares the
recording_dir pointer against `status.dir` to determine "is MY session's
recording the active one," and reads `started_at`/`ended_at` the same way to
distinguish "never recorded" from "recorded, then ended" for the pill's
transitional ENDED state.

| Key | Written by | Meaning |
|-----|-----------|---------|
| `meeting/recording_dir` | whoever starts the recording (the calendar widget's detection agent at mint/attach time, or this widget's manual Record intent) | Points at `meet42 record`'s own recordings directory — the single source of truth for where the transcript actually lives. |
| `meeting/started_at` | same as above, via `work42 storage set --session <id> ...` | ISO 8601 start time → the "In Meeting" workflow gate. |
| `meeting/ended_at` | whoever observes the recording has stopped (the record daemon self-stops entirely on its own; this widget's Stop intent/pill Stop writes the gate, or — if the daemon self-stopped with nobody watching — the next `fetchRecordingSnapshot` poll notices and writes it) | ISO 8601 end time → advances to Summary. |

## Reconcile on activate (survives relaunch)

Because the record daemon's lifetime is independent of this widget (or the
app) being alive, `TranscriptWidget.activate` reconciles on EVERY activation:
it reads recording truth once, and if this session's recording is still
active (survived an app relaunch/crash) or has ended with nobody having seen
it yet, it re-presents this widget's pill — so a live or just-finished
recording always surfaces its pill again rather than leaving the user with no
visible state.

## Pill

`makePillView` renders the recording accessory, ported from the app's Event
accessory with the **RECORDING** + **ENDED** states (+ a plain **idle**). The
DETECTED state is NOT here — the calendar widget owns it. Visuals: purple
`#7C3AED`, a Stop capsule with a live monospaced `M:SS` timer. State is derived
every ~1s from `meet42 record status` (recording) + the `meeting/started_at`/
`ended_at` storage reads above (ended vs idle). The Stop button runs `meet42
record stop`, writes `ended_at`, and dismisses the pill.

## Manual Record/Stop (action-area intents)

Both intents use the SAME session-agnostic `meet42 record` primitive the
calendar detection agent uses (meet42-recording-lifecycle-rework s5) — this
widget doesn't own a different start/stop mechanism, just a different
trigger (a button click, not a detected call).

**Record**: launches `meet42 record start --manual --json` as a DETACHED
process (not via `WidgetShellService`, which is bounded to a 10s timeout —
`record start` daemonizes via `setsid`+`execve` with no `fork`, so it never
exits on its own while recording and the bounded shell service would kill
it). `--manual` means there's no trigger call for the daemon to self-watch —
only an explicit Stop ends it. Unlike the old fire-and-forget version, this
redirects stdout to a temp file and polls for the daemon's pre-daemonize
`{recordingId, dir}` line (s1) — that line appearing IS the confirmation (it
only prints once the singleton check passes), no separate `record status`
poll needed. On success, seeds THIS session's `meeting/recording_dir`
pointer + `meeting/started_at` gate via the shelled CLI (`work42 storage
set --session <id> meeting/... ...` — `services.storage` can't target the
`meeting` namespace, only this widget's own `transcript` namespace), then
refreshes to show the RECORDING pill.

**Stop** (the action-area intent, and the pill's own Stop button —
`RecModel.stopRecording`, reused by both the RECORDING and ENDED states):
reads this session's `meeting/recording_dir` pointer, runs `meet42 record
stop --dir <dir>` (`--dir`, not the old `--session-dir` — `meet42 record` is
session-agnostic now; safe via the bounded shell service, it just touches a
marker file and returns immediately — the daemon now honors it within ~1s
regardless of capture load, s2's off-main stop-detection fix), and writes
`meeting/ended_at`.

**The ended-gate** (`fetchRecordingSnapshot`, AC10): the record daemon can
also self-stop entirely on its own when its trigger call ends (s2) — nobody
necessarily ever clicks Stop. Every recording-truth poll checks for exactly
that: a session with a recording attached (`recording_dir` + `started_at`
both set) that is NOT currently active and has no `ended_at` yet — if so, it
writes `meeting/ended_at` itself, so the session still advances to Summary.
Guarded by `!hasEnded` so it only fires once per transition.
