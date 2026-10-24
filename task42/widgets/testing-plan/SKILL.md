---
name: widget-testing-plan
description: How the Testing Plan widget (kindId widget:testing-plan) works on a task session. It renders the session's `plan/testing` storage as themed markdown with the shared comment layer. Read or author the plan with `storage_get` / `storage_set` (key `plan/testing`).
---

# Testing Plan widget

Renders the session's Testing Plan, the script QA executes, as read-only themed markdown with the shared pinned-comment layer. Unlike the Spec widget it doesn't resolve `[[artifact:id]]` embeds.

| Key | Type | Description |
|-----|------|-------------|
| `plan/testing` | string (markdown) | The testing plan. |

```bash
storage_get(key: "plan/testing")
```

To write it, call `storage_set` with key `plan/testing` and the markdown as a JSON string value.

Selecting text offers "Add comment", pinned under `<sessionId>/plan/testing` and shared with every other widget reading the same `pendingComments`.
