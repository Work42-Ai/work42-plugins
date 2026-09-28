---
name: widget-qa
description: |
  How the QA widget (session tab kindId widget:qa) works on a task
  session. It's a read-only render of the session's `qa/report` storage
  as themed markdown. Use `work42 storage get qa/report` to read the
  report directly, or `work42 qa <id> --report <md> ...` to write one.
---

# QA widget

Renders the task session's QA report — read-only themed markdown, no
editing affordance in the widget itself.

## Storage convention

| Key | Type | Description |
|-----|------|--------------|
| `qa/report` | string (markdown) | The QA report. Written by the QA agent, never by this widget. |

## Agent usage

```bash
# Read the current report
work42 storage get qa/report

# Attach a QA verdict + report (see the task42-qa skill for the full flow)
work42 qa <id> --report qa-report.md --verdict PASS
```

## Empty state

Before any report exists, the widget shows "No QA report yet" with a hint
pointing at `qa/report` storage.
