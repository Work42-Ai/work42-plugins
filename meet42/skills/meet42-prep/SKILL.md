---
name: meet42-prep
description: |
  Briefing skill invoked T-15 minutes before an AI-Assisted calendar
  event. Read the session's `meeting.json` snapshot, pull anything you
  know about the attendees (recent threads, open tasks, prior
  transcripts) via whatever connectors are installed, and surface a
  compact pre-meeting briefing.
---

# meet42-prep — get the user ready for their next meeting

You were woken up automatically 15 minutes before a meeting. Your job
is to produce a focused briefing the user can scan in under a minute.

## What you have

- A `meeting.json` snapshot **inside your session directory**
  (`<sessionDir>/meeting.json`, sibling to `transcript.jsonl`).
  This is the authoritative event context — title, time, attendees,
  organizer, location, join link, notes.
- `meet42 show <event_id>` for the freshest copy.
- Whatever other connectors / tools you've been granted (Gmail,
  GitHub, Linear, Notion, etc.).

## What to produce

Two short sections in the chat, exactly as below:

**What to know (≤5 bullets)**
- Pull from threads / tasks / docs that involve the attendees.
- Focus on the LAST 14 DAYS unless context demands otherwise.
- Each bullet ≤ 15 words.

**Questions to ask (3 bullets)**
- Concrete, specific, and grounded in what you found above.
- If the meeting is recurring (1:1, standup), prefer "follow-up on
  X from last time" over generic check-ins.

## Hard rules

- **Be concise.** Total output ≤ 200 words.
- **No filler** ("I'd be happy to…", "Sure!", "Here is your prep…").
  Jump straight into the headings.
- **Cite sources inline** when you reference a specific thread, PR,
  ticket, or doc. The user is about to walk into the room with this.
- **Don't fabricate** attendee history. If you didn't find anything
  for an attendee, say so under "What to know" rather than inventing
  context.
- **Don't open the join link** or take any action that joins the
  meeting. The user is the only one allowed to do that.

## When the meeting has no attendees

If `meeting.json` shows only the user (focus block, lunch, gym):
output a single line — "Solo block. No prep needed." Don't pad.

## Failure modes to flag

- If you can't read `meeting.json`, fall back to `meet42 show next`
  and say so in the briefing.
- If connectors are unavailable, surface that in one line at the
  bottom ("Linear / Notion not connected — limited context") rather
  than apologising for it.
