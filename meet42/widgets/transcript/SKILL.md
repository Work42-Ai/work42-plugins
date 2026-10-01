---
name: widget-transcript
description: |
  How the Transcript widget (session tab kindId widget:transcript) works on a
  meet42 meeting session. It renders the live meeting transcript as chat
  bubbles, owns the RECORDING / ENDED / idle recording pill, and runs a
  background agent that starts capture on the calendar widget's autostart
  handoff and stops it when the meeting ends.
---

# Transcript widget

The most complex meet42 widget: a tile, a stateful pill, and a background agent.

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

## Storage (namespace `meeting`)

The widget's `storageNamespace` is **`meeting`** (not `transcript`), so its
writes land in the `meeting/*` namespace the workflow gates read:

| Key | Written by | Meaning |
|-----|-----------|---------|
| `meeting/autostart` | the **calendar widget** (read here) | Truthy ⇒ the agent should start capture at session start. |
| `meeting/started_at` | this widget | ISO 8601 start time → the "In Meeting" gate. |
| `meeting/ended_at` | this widget | ISO 8601 end time → advances to Summary. |

## Pill

`makePillView` renders the recording accessory, ported from the app's Event
accessory with the **RECORDING** + **ENDED** states (+ a plain **idle**). The
DETECTED state is NOT here — the calendar widget owns it. Visuals: purple
`#7C3AED`, a Stop capsule with a live monospaced `M:SS` timer, and an
"Auto-stopping in Ns" ended row + grace bar. State is derived by polling
`meeting/started_at` + `meeting/ended_at` every ~1s: ended if `ended_at` is set,
recording if `started_at` is set and not ended, else idle. The Stop button runs
`meet42 record stop`, writes `ended_at`, and dismisses the pill.

## Background agent

On start the agent checks `meeting/autostart`; if truthy (and not already
started) it runs `meet42 record start --session-dir "$(pwd)"`, writes
`meeting/started_at`, and presents the RECORDING pill. It then polls the mic and,
on an open→close transition after a start, runs `meet42 record stop`, writes
`meeting/ended_at`, and dismisses the pill.

**Mic-watch limitation.** `meet42 watch` is a long-lived blocking stream, but
`WidgetShellService.run` is a buffered request/response call — a bare `watch`
would never return and would hang the agent. The agent instead runs a *bounded*
`watch` (killed after ~2s) each cycle as a single-shot mic-level probe: a fresh
`watch` emits `mic-open` within its first poll iff the default input is running,
and nothing when it is closed. This is cancellable and never blocks.
`meet42 mics --json` lists DEVICES (not running-state), so it cannot serve as
the probe. Note: because meet42's own capture daemon holds the default input
open while recording, the CoreAudio-level mic-close edge may not fire until
capture already stops — the reliable stop path in that case is the pill's Stop
button.
