---
name: widget-spec
description: |
  How the Spec widget (session tab kindId widget:spec) works on a task
  session. It renders the task's spec markdown (plan/spec) with the
  standard `.work42` theme, inline [[artifact:id]] embeds, and shared
  pinned comments, and exposes the "Approve Plan" action. Use
  `work42 storage set plan/spec` / `work42 storage get plan/spec` to
  author or read the spec directly.
---

# Spec widget

Renders a task session's spec — the plan's Context / Acceptance Criteria /
Out of Scope document — as read-only themed markdown, with inline artifact
embeds and the shared comment layer, plus the Approve Plan action.

## Storage convention

| Key | Type | Description |
|-----|------|--------------|
| `plan/spec` | string (markdown) | The spec document. Written by the agent, never by this widget. |
| `plan/approved_at` | string (ISO-8601) | Set by Approve Plan. Presence = approved. |
| `plan/approved_by` | string | The approver's username, set alongside `approved_at`. |

## Agent usage

```bash
# Read the current spec
work42 storage get plan/spec

# Write/replace the spec
work42 storage set plan/spec '"# Context\n...\n## Acceptance Criteria\n..."'

# Check approval state
work42 storage get plan/approved_at
```

## Approve Plan

The widget's action-area button ("Approve Plan") stamps `plan/approved_at`
(now, ISO-8601) and `plan/approved_by` (the approver's macOS username)
through the widget's own storage. It is enabled only once `plan/spec` is
non-empty and not yet approved; once approved it renders as "Plan
approved" and is no longer tappable. There is no separate approval
table — a task's In-Progress gate reads `plan/approved_at`'s presence
directly.

## Comments and artifacts

Selecting text in the rendered spec offers "Add comment", pinned under
`<sessionId>/plan/spec` and shared with every other widget reading the
same `pendingComments` environment key. A `[[artifact:<id>]]` token on its
own line renders as a live embed, resolved via the session's artifact
server.
