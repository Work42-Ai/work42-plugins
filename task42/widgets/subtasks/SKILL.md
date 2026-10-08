---
name: widget-subtasks
description: How the Subtasks widget (kindId widget:subtasks) works on a task session. It renders the implementation breakdown (plan/subtasks) as toggleable rows; the planner writes the array and the widget only lets a human check off, expand or delete a row. Read or author the array with `work42 storage get|set plan/subtasks`.
---

# Subtasks widget

A checklist of the session's breakdown. Each row shows its id, title and a done checkmark; tapping a row expands its description; the trash icon deletes a row behind a confirmation.

`plan/subtasks` is a JSON array of `{"id": "s1", "title": "...", "description": "...", "done": false}` (`description` and `done` default to `""` and `false` on older rows).

```bash
work42 storage get plan/subtasks
work42 storage set plan/subtasks '[{"id":"s1","title":"...","description":"...","done":false}]'   # the whole array
```

The widget never adds subtasks: only the planner (or a direct `work42 storage set`) authors the array. It only toggles `done`, expands a description and deletes a row.
