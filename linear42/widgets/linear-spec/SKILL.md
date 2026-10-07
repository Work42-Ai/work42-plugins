---
name: widget-linear-spec
description: |
  How the Spec Document widget (session tab kindId widget:linear-spec) works on a
  linear-task session. It renders the spec as the Linear Document the Planner
  attached to the issue, and owns the Approve Plan action. Use this to know when
  Approve Plan is enabled, what approving writes, and how the approval reaches
  Linear.
---

# Spec Document widget

Shows the spec documents of the attached issues (`linear/issues/<KEY>/spec_doc`, a `{slug,url}` object the Planner
writes after `publish-doc.py --issue <KEY> --kind spec`), one tab per document (`📐 WOR-6 Spec`), in an embedded
browser on the user's linear.app login. Before any document exists it shows "No spec yet". A link to a spec
document that no attached issue holds opens in a temporary tab.

## Approve Plan

The green **Approve Plan** action (action area + command palette) is the human gate
between Planning and In-Progress. It is enabled only while **all** hold:

- a spec document is set on an attached issue (`linear/issues/<KEY>/spec_doc`),
- `plan/subtasks` (the sub-issue mirror) is non-empty,
- `plan/approved_at` is not set yet, and an approval isn't already running.

Clicking it writes `plan/approved_by` (the macOS username) and then
`plan/approved_at` (ISO-8601). That second write re-checks the workflow gates and the
session receives the "In-Progress is now available" message; you then run
`work42 transition "In-Progress"`.

It does **not** talk to Linear. The background sync agent (see `widget-linear-issue`)
is the single writer to Linear: within one poll it comments "Plan approved in Work42
by <user> — spec: <url>" on the issue, moves it to the In-Progress-mapped state, and
sets `linear/approval_stamped` to `true`.

Approval also works from the other side: moving the issue into a started state in
Linear while Planning approves it (the agent writes `plan/approved_at`).

## Revising an approved spec

Nothing clears `plan/approved_at` when the spec document is edited. After a
`linear document update` of the spec, delete the approval yourself so the plan is
re-approved:

```bash
work42 storage delete plan/approved_at
work42 storage delete plan/approved_by
work42 storage delete linear/approval_stamped
```

(Planning is the only stage that allows `linear document update` and these deletes.)
