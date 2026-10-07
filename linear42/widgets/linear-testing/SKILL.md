---
name: widget-linear-testing
description: |
  How the Testing Plan Document widget (session tab kindId widget:linear-testing)
  works on a linear-task session. It renders the testing plan as the Linear
  Document the Planner attached to the issue. Read-only.
---

# Testing Plan Document widget

Shows the testing-plan documents of the attached issues (`linear/issues/<KEY>/testing_doc`, a `{slug,url}` object),
one tab per document (`🧪 WOR-6 Testing Plan`), in an embedded browser on the user's linear.app login. Before any
document exists it shows "No testing plan yet".

The Planner creates it once the spec is settled:

```bash
.claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind testing --file - <<'MD'
…testing plan markdown…
MD
work42 storage set linear/issues/<KEY>/testing_doc '{"slug":"<slug>","url":"<document url>"}'
```

The widget never writes. There is no separate approval for the testing plan: the single
Approve Plan click on the Spec Document tab covers the spec, the sub-issues and this document.
