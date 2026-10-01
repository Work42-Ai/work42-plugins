---
name: widget-annotations
description: |
  How the My Notes widget (session tab kindId widget:annotations) works on a
  meet42 meeting session. It is an editable notes tile whose contents persist
  to annotations.md in the session dir, readable by the agent.
---

# My Notes (annotations) widget

An editable personal-notes tile. Type into it during a meeting and the content
is saved — debounced (~500 ms), atomic (temp file + rename) — to
`annotations.md` inside the session dir, so it is part of the session and the
agent can read it. Reloads on external change (the agent or meet42 writing a
note) only when the editor is unfocused and has no unsaved local edits, so it
never clobbers in-flight typing. Shows a placeholder when empty.

## Session file

| File | Access | Description |
|------|--------|-------------|
| `<dir>/annotations.md` | read + write | The user's notes. Written by this widget on edit; readable by the agent and re-read via a 1s file watcher when changed out-of-band. |

The widget reads the session worktree dir from `services.worktreePath`.

## Agent usage

```bash
# Read the user's notes for a meeting session
cat "$WORK42_SESSION_DIR/annotations.md"
```

## Pill

`makePillView` renders a compact editor (the text area without the header),
backed by the same load + atomic-save path.
