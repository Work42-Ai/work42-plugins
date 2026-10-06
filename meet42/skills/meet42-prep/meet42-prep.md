# meet42-prep — companion guide

This file expands the SKILL.md frontmatter with the longer-form
context you might need when running the briefing flow for the first
time.

## How you ended up here

`MeetingScheduler` fired this session at `starts_at − 900s` for a
calendar event the user (or their calendar admin) marked
**AI-Assisted**. The fire writes a `.systemPrompt` into the session
inviting you to "use the meet42-prep skill." That's this skill.

## The snapshot

`<session.ownerDir>/meeting.json` is created at session-mint time
and looks like:

```json
{
  "event": {
    "id": "...",
    "title": "1:1 with Alex",
    "starts_at": "2026-05-20T18:00:00.000Z",
    "ends_at":   "2026-05-20T18:30:00.000Z",
    "attendees": [{"email": "alex@example.com", "name": "Alex Chen", "status": "accepted"}],
    "organizer": "Alex Chen",
    "location": "Teams",
    "meeting_url": "https://teams.microsoft.com/...",
    "notes": "Agenda: roadmap; quarterly review."
  },
  "snapshot_at": "2026-05-20T17:45:00.000Z"
}
```

Read it with the `Read` tool against the path
`<session.ownerDir>/meeting.json`. The Work42 runner sets the
session's working dir to the owner dir, so a relative `meeting.json`
also works.

## What "AI-Assisted" means

A calendar (or single event) flipped to `assisted` in the Calendar
preferences. The user opted into this — you're not interrupting
them. Be useful, be brief.

## Hand-off to the next phase

In a future slice the same session will receive live transcript
chunks once the meeting starts. Don't shut down or end the session
when your briefing is done — leave it idle so the audio loop can
attach.
