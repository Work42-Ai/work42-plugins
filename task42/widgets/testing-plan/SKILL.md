---
name: widget-testing-plan
description: How the Testing Plan widget (kindId widget:testing-plan) works on a task session. It renders the session's `plan/testing` storage as themed markdown with the shared comment layer. Read or author the plan with `work42 storage get|set plan/testing`.
---

# Testing Plan widget

Renders the session's Testing Plan, the script QA executes (see `task42-planner` and `task42-qa`), as read-only themed markdown with the shared pinned-comment layer. Unlike the Spec widget it doesn't resolve `[[artifact:id]]` embeds.

| Key | Type | Description |
|-----|------|-------------|
| `plan/testing` | string (markdown) | The testing plan. |

```bash
work42 storage get plan/testing
```

To write it, pipe the markdown through `jq -Rs .` to make it a JSON string (see `task42-planner`).

Selecting text offers "Add comment", pinned under `<sessionId>/plan/testing` and shared with every other widget reading the same `pendingComments`.
