---
name: widget-people
description: The meet42 People widget — attendee profiles for the current event.
---

# People widget

Read-only. Shows the event's attendees with their accumulated profile from
meet42's people store: display name, email, shared-meeting count, and last-seen
(relative). Organizer / you chips come from the event's attendee list.

- **Data source:** shells `meet42 people --session-dir <dir> --json` (the
  standalone meet42 CLI reads its own `people.db`); attendee organizer/you flags
  come from `<dir>/meeting.json`. The widget imports no calendar/people type.
- **Empty state:** "No attendee data" when there is no `meeting.json` or it
  lists no attendees; "No accumulated data yet" when attendees exist but have no
  recorded shared meetings yet.
- **Pill:** `makePillView` renders a compact attendee list so People can float.
