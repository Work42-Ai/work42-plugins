---
name: widget-spec
description: How the Spec widget (kindId widget:spec) works on a task session. It renders the task's spec markdown (plan/spec) with the .work42 theme, inline [[artifact:id]] embeds and shared pinned comments, and exposes the Approve Plan action, including revoking an approval. Author or read the spec with `storage_get` / `storage_set` (key `plan/spec`).
---

# Spec widget

Renders the session's spec (Context / Acceptance Criteria / Out of Scope…) as read-only themed markdown, with inline artifact embeds and the shared comment layer, plus the Approve Plan action.

| Key | Type | Description |
|-----|------|-------------|
| `plan/spec` | string (markdown) | The spec. Written by the agent, never by this widget. |
| `plan/approved_at` | string (ISO-8601) | Set by Approve Plan; presence means approved. |
| `plan/approved_by` | string | The approver's username. |

```bash
storage_get(key: "plan/spec")
storage_get(key: "plan/approved_at")
```

To write the spec, call `storage_set` with key `plan/spec` and the markdown as a JSON string value.

## Approve Plan and revoke

The action-area button **Approve Plan** stamps `plan/approved_at` (now, ISO-8601) and `plan/approved_by` (the macOS username). It is enabled once `plan/spec` is non-empty and not yet approved; the In-Progress gate reads `plan/approved_at`'s presence. Once approved it reads **Plan approved**; tapping it asks to revoke, and confirming deletes both keys. Each session has its own button state.

## Comments and artifacts

Selecting text offers "Add comment", pinned under `<sessionId>/plan/spec` and shared with every other widget reading the same `pendingComments`. A `[[artifact:<id>]]` token on its own line renders as a live embed from the session's artifact server.
