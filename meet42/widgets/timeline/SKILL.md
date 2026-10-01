---
name: widget-timeline
description: The meet42 Timeline widget — a single-day calendar-event timeline with a per-event AI assist-mode picker.
---

# Timeline widget

A calendar-only port of the app's day timeline. Renders one day's real calendar
events on a macOS Calendar.app-style hour grid: an all-day strip, an hour rail,
hour gridlines, collision-laid-out event blocks, and a red current-time line
(when viewing today). Prev / Today / Next navigate the day.

- **Data source:** shells the read-only meet42 CLI — `meet42 list --from <iso>
  --to <iso> --json` (the day window) and `meet42 modes get --json`. Setting an
  event's mode writes via `meet42 modes set event <id> <mode>`. Refreshes on a
  ~2s timer while mounted. Decodes local `CalEvent` / `CalMode` mirrors; imports
  no calendar type.
- **Assist mode:** clicking an event opens a popover with its details; a
  view-only event offers "Enable AI assistance" (a per-event override). Block
  colors: AI Assisted = violet, View only = blue, AI scheduled = orange.
- **Pill:** none. A compact day timeline doesn't render usefully in a pill, so
  the widget does not provide one.
- **Out of scope (dropped from the app original):** PlannedDay work-block lanes
  (draw-to-schedule / move / resize) and AI-schedule fire pills. Re-surfaced
  later via a separate collection.
