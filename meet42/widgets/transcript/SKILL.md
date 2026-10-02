---
name: widget-transcript
description: |
  How the Transcript widget (session tab kindId widget:transcript) works on a
  meet42 meeting session. It renders the live meeting transcript as chat
  bubbles and owns the RECORDING / ENDED / idle recording pill. It has no
  background agent — the calendar widget's detection agent owns the whole
  recording lifecycle for detected calls; this widget drives the manual
  Record/Stop controls and renders recording truth.
---

# Transcript widget

A tile + a stateful pill. No background agent (meet42-detection-rework) — the
calendar widget's detection agent owns the entire recording lifecycle for
detected calls (start on Yes/auto-start, stop on its own 5s stop-grace over the
event-driven `meet42 watch` stream). This widget only drives the MANUAL
Record/Stop action-area intents and renders truth.

## Tile

Renders `<dir>/conversation.jsonl` live as chat bubbles, reloaded via a ~0.5s
file watcher as the capture daemon appends lines. Each utterance becomes a
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
| `<dir>/conversation.jsonl` | read-only | Append-only transcript. Speaker line: `{ "ts", "speaker": "You"\|"Them", "text", "lineId", "speakerLabel"? }`; system-event line: `{ "ts", "type":"system_event", "event", "app"?, "ocr_text"?, "rect" }` (a missing `type` ⇒ speaker line). Written by meet42's `MeetingTranscriptionEngine`. |
| `<dir>/speakers.json` | read-only | Optional `{ "<speakerKey>": "<Name>" }` or `{ "<speakerKey>": { "person_id", "name" } }` sidecar mapping speaker keys to display names. |
| `<dir>/meeting.json` | read-only | Read only for the meeting title shown on the pill. |

## Recording truth

`meet42 record status` (the machine-wide singleton — see the meet42-cli
`record` command) is the single source of truth for "is MY session the one
currently recording", NOT session storage: `SessionServices.storage` is
FILE-backed for a non-task session (a different store than `work42 storage
set/get`, which always hits `work42.db`), so it never sees the workflow-gate
writes below. The widget shells `work42 storage get --session <id>
meeting/started_at|ended_at` directly to distinguish "never recorded" from
"recorded, then ended" for the pill's transitional ENDED state.

| Key | Written by | Meaning |
|-----|-----------|---------|
| `meeting/started_at` | whoever starts the recording (the calendar widget's detection agent, or this widget's manual Record intent) via `work42 storage set --session <id> ...` | ISO 8601 start time → the "In Meeting" workflow gate. |
| `meeting/ended_at` | whoever stops the recording (the detection agent's 5s stop-grace, or this widget's Stop intent/pill Stop) | ISO 8601 end time → advances to Summary. |

## Pill

`makePillView` renders the recording accessory, ported from the app's Event
accessory with the **RECORDING** + **ENDED** states (+ a plain **idle**). The
DETECTED state is NOT here — the calendar widget owns it. Visuals: purple
`#7C3AED`, a Stop capsule with a live monospaced `M:SS` timer. State is derived
every ~1s from `meet42 record status` (recording) + the `meeting/started_at`/
`ended_at` storage reads above (ended vs idle). The Stop button runs `meet42
record stop`, writes `ended_at`, and dismisses the pill.

## Manual Record/Stop (action-area intents)

The Record intent shares the detection agent's start-sequence tail: it launches
`meet42 record start --session-dir <dir>` as a DETACHED process (not via
`WidgetShellService`, which is bounded to a 10s timeout — `record start`
daemonizes via `setsid`+`execve` with no `fork`, so it never exits on its own
while recording and the bounded shell service would kill it), confirms the
claim landed via a bounded `meet42 record status` poll, then writes
`meeting/started_at`. The Stop intent runs `meet42 record stop --session-dir
<dir>` (safe via the bounded shell service — it just touches a marker file and
returns immediately) and writes `meeting/ended_at`.
