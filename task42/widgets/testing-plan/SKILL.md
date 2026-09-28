---
name: widget-testing-plan
description: |
  How the Testing Plan widget (session tab kindId widget:testing-plan)
  works on a task session. It renders the session's `plan/testing`
  storage as themed markdown with the shared comment layer. Use
  `work42 storage get plan/testing` / `work42 storage set plan/testing`
  to read or author the plan directly.
---

# Testing Plan widget

Renders a task session's Testing Plan — the per-AC verification prose
authored in the Planner↔QA dialogue (see the `task42-planner`/`task42-qa`
skills) — as read-only themed markdown with the shared pinned-comment
layer. Unlike the Spec widget, it does not resolve `[[artifact:id]]`
embeds (matching the built-in's behavior).

## Storage convention

| Key | Type | Description |
|-----|------|--------------|
| `plan/testing` | string (markdown) | The testing-plan document. |

## Agent usage

```bash
# Read the current testing plan
work42 storage get plan/testing

# Write/replace it
work42 storage set plan/testing '"## Overview\n...\n## Per-AC Test Plan\n..."'
```

## Comments

Selecting text in the rendered plan offers "Add comment", pinned under
`<sessionId>/plan/testing` and shared with every other widget reading the
same `pendingComments` environment key.
