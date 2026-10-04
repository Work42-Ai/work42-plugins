---
name: widget-recording
description: |
  How the meet42 Recording widget renders live conversation, owns the active
  meeting pill, and decides when an auto-detected recording stops.
---

# Recording widget

Recording has three responsibilities after Calendar hands off a detected
meeting session:

1. Render `<meeting/recording_dir>/conversation.jsonl` as live chat bubbles.
2. Present the active-meeting pill with the detected app identity and session.
3. Watch that app's mic state and own the 10-second Stay/Stop decision.

Calendar owns global mic-open detection and session creation. The `meet42
record` daemon only captures and responds to an explicit stop marker (plus its
optional Work42 owner PID); it has no mic-close or UI policy.

## Tile

The tile reads the session's `meeting/recording_dir` pointer, then tails
`conversation.jsonl`. `You` renders as a trailing accent bubble. `Them`
renders leading and uses `speakers.json` when a resolved speaker is available.
System-event rows render as centered cards. A missing pointer or empty file
shows the waiting state.

## Stable meeting metadata

The Calendar handoff writes these `meeting/*` keys before presenting
Recording:

| Key | Meaning |
|---|---|
| `recording_dir` | Recording directory returned by `meet42 record start`. |
| `started_at` | ISO 8601 capture start. |
| `title` | Matched calendar title, or detected app name for ad-hoc calls. |
| `source_app` | Detected meeting app display name. |
| `source_bundle_id` | Bundle id used for the native icon and scoped mic watch. |
| `scheduled_start` / `scheduled_end` | Optional matched-event bounds. |
| `ended_at` | Written only when Recording/manual controls explicitly stop. |

`meet42 record status --json` remains recording truth. Recording compares its
stored `recording_dir` with the active status directory before presenting or
controlling the pill.

## Background agent

`RecordingMeetingAgent` is one agent per session. It reconciles storage with
recording status once on activation/relaunch and once when the pill mounts,
then presents the pill for an active recording and starts:

```text
meet42 watch --bundle-id <meeting/source_bundle_id> --json
```

The scoped watcher emits the initial state and later open/close edges for only
that detected app. While recording or awaiting the mic-close decision, one
cancellable 15-second activity heartbeat keeps the already-active background
session alive; it has no authority to wake an inactive session. There is no
perpetual per-session storage polling. All watcher, reconciliation, countdown,
and heartbeat tasks are cancelled when the agent stops or hot-reloads.

Mic-open keeps or restores the active state. Mic-close shows a 10-second
`Auto-stopping` prompt. `Stay` suppresses further close handling until the app
opens its mic again. `Stop` and countdown expiry share one idempotent completion
attempt: send final activity, stop capture, verify the single
`meeting/ended_at` write succeeded, then enter stopped state and dismiss. The
storage write's existing workflow nudge advances the active session normally;
there are no transition retries or forced workflow transitions.

## Pill

Calendar detection/setup and Recording recording/auto-stop all use
`WidgetPillAccessoryShell`, so the 412x108 frame, native-app icon, typography,
32-point actions, and progress rail remain fixed across handoff. The active
pill's state content is:

- Row 1: native macOS icon resolved from `source_bundle_id` (generic video only
  when resolution fails), the authoritative session name, and source/timing
  context. Recording resolves the name from the session database and uses
  stored meeting metadata only as a backward-compatible fallback.
- Row 2: schedule status, Liquid Glass **Open Session**, and a live Stop timer.

Matched meetings show a remaining-time rail that drains from right to left.
It is violet normally, amber during the final five minutes, and empty after the
scheduled end while the label becomes red `Over by X min`. Ad-hoc meetings
show `In Progress` and no rail.

**Open Session** invokes `global.openLink` with
`work42://session/<session-id>`. The prompt preserves the same app icon and
title, replacing row 2 with `Auto-stopping in Ns`, **Stay**, and **Stop**.

## Manual controls

The action-area microphone picker and manual Record/Stop remain available.
Manual Record uses `meet42 record start --manual --json`, stores
`recording_dir` and `started_at`, and presents Recording. Because manual
recordings have no `source_bundle_id`, they show `In Progress` and do not run a
mic watcher. Manual Stop uses the same explicit stop and `ended_at` path.
