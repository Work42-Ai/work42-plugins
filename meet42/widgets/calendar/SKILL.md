---
name: widget-calendar
description: The meet42 Calendar widget — Day/Week/Agenda calendar-event views with per-calendar and per-event AI assist-mode pickers.
---

# Calendar widget

A calendar-only port of the app's Meetings view. Renders your real calendar
events in a Day / Week / Agenda layout (macOS Calendar.app-style hour grid with
collision-laid-out event blocks, an all-day strip, and a live current-time
line), and lets you set the AI assist mode per calendar and per event.

- **Data source:** shells the read-only meet42 CLI — `meet42 list --from <iso>
  --to <iso> --json` for the active window's events, and `meet42 modes get
  --json` for the per-calendar/-event assist modes. Toggling a mode writes via
  `meet42 modes set calendar|event <id> <view_only|assisted|ai_scheduled>`. It
  refreshes on a ~2s timer while mounted. The widget imports no calendar type —
  it decodes local `CalEvent` / `CalMode` mirrors.
- **Assist modes:** clicking an event opens a popover with its details; a
  view-only event offers "Enable AI assistance" (a per-event override). The gear
  button opens a settings popover with a per-calendar AI-assistance toggle.
  Colors: AI Assisted = violet, View only = blue, AI scheduled = orange.
- **Pill:** `makePillView` renders a compact "Up Next" agenda (the next few
  upcoming events).
- **Out of scope (dropped from the app original):** AI-schedule authoring/UI,
  PlannedDay work-blocks, the sync-status/access header chip, and session
  minting / "Open in Calendar". Re-surfaced later via a separate collection.
