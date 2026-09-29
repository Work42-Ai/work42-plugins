---
name: widget-subtasks
description: |
  How the Subtasks widget (session tab kindId widget:subtasks) works on a
  task session. It renders the task's implementation breakdown
  (plan/subtasks) as toggleable rows. The planner writes the array; the
  widget only lets a human check off / expand / delete a row. Use
  `work42 storage get plan/subtasks` / `work42 storage set plan/subtasks`
  to read or author the array directly.
---

# Subtasks widget

Renders a task session's implementation breakdown as a checklist. Each row
shows its id, title, and a done checkmark; tapping a row expands its
description; the trash icon deletes a row behind a confirmation dialog.

## Storage convention

`plan/subtasks` is a JSON array of:

```json
{"id": "s1", "title": "...", "description": "...", "done": false}
```

`description`/`done` tolerate absence on older rows (default to `""`/`false`).

## Agent usage

```bash
# Read the current subtask array
work42 storage get plan/subtasks

# Write the full array (the planner authors this — the widget never adds rows)
work42 storage set plan/subtasks '[{"id":"s1","title":"...","description":"...","done":false}]'
```

## What the widget does NOT do

It does not add subtasks — only the planner (or direct `work42 storage set`)
authors the array. The widget's affordances are limited to toggling `done`,
expanding a description, and deleting a row.
