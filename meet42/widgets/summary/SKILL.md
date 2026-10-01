---
name: widget-summary
description: |
  How the Summary widget (session tab kindId widget:summary) works on a meet42
  meeting session. It is empty until the end-of-meeting pass writes summary.md,
  then renders that file as themed markdown.
---

# Summary widget

Renders a meeting session's `summary.md` as themed markdown (via
`Work42MarkdownDocument` — inline `[[artifact:id]]` embeds + the shared comment
layer). The tile shows a waiting/empty state until the end-of-meeting agent
pass writes the file, then renders the structured summary — decisions, action
items, open questions, best-effort speaker attribution.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/summary.md` | read-only | The meeting summary markdown. Written by the end-of-meeting agent pass; rendered here and re-read via a 1s file watcher when it changes. |

The widget reads the session worktree dir from `services.worktreePath` and
registers the session with the artifact runtime on `activate` so inline embeds
resolve.

## Agent usage

```bash
# Write the structured summary at the end of a meeting
cat > "$WORK42_SESSION_DIR/summary.md" <<'MD'
## Decisions
...
## Action items
...
MD
```

## Pill

`makePillView` renders the same scrollable markdown (or the empty state)
without the header.
