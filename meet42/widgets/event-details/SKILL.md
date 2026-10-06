---
name: widget-event-details
description: |
  How the Event Details widget (session tab kindId widget:eventDetails) works
  on a meet42 meeting session. It renders the calendar event the session was
  minted around — title, time, RSVP/status, location, organizer, attendees,
  notes — from the session's meeting.json snapshot.
---

# Event Details widget

Renders a meeting session's event detail from the `meeting.json` snapshot that
meet42 writes (and rewrites on each calendar sync) next to the session. Shows
title, time range, the user's RSVP + the meeting's status, location, organizer,
the attendee list (with per-attendee RSVP dots, organizer/you chips), notes,
and a "synced Ns ago" footer. A "Join meeting" link appears when the snapshot
carries a meeting URL. Empty until the snapshot exists.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/meeting.json` | read-only | The event snapshot (`{ event, snapshotAt }`), written by meet42. The widget decodes it through a local mirror of `CalendarEvent.Item` and reloads via a 1s file watcher when meet42 rewrites it. |

The widget never writes. It reads the session worktree dir from
`services.worktreePath`.

## Pill

`makePillView` renders a compact card: event title + time range + attendee
count.
