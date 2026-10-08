---
name: widget-qa
description: How the QA widget (kindId widget:qa) works on a task session. A read-only render of the session's `qa/report` storage as themed markdown, with the recording frames QA cites. Read the report with `work42 storage get qa/report`.
---

# QA widget

Renders the task session's QA report as read-only themed markdown: status chips, video frames that open the Work42 recording at the cited event, console panels and a clickable AC index. The grammar the renderer implements is in the `task42-qa` skill. Before any report exists it shows "No QA report yet".

| Key | Type | Description |
|-----|------|-------------|
| `qa/report` | string (markdown) | The report. Written by the QA agent, never by this widget. |
| `qa/verdict` | `"PASS"` or `"FAIL"` | Written last; satisfies (or fails) the Human Review gate. |

```bash
work42 storage get qa/report     # read the current report
```
