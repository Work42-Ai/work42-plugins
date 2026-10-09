---
name: widget-linear-spec
description: How the Spec Document widget (kindId widget:linear-spec) works on a linear-task session. It renders the spec as the Linear document the Planner attached to the issue and owns the Approve Plan action, including revoking an approval. Use it to know when Approve Plan is enabled, what approving and revoking write, and how approval reaches Linear.
---

# Spec Document widget

Shows the spec documents of the attached issues (`linear/issues/<KEY>/spec_doc`, a `{slug,url}` the Planner writes after `publish-doc.py --issue <KEY> --kind spec`), one tab per document (`📐 WOR-6 Spec`), in an embedded browser on your linear.app login. Before any document exists it shows "No spec yet". A link to a spec document no attached issue holds opens in a temporary tab.

## Prerequisites

This widget reads Linear through the `linear` CLI. If `command -v linear` prints nothing, install it with
`brew install schpet/tap/linear`; if `linear auth whoami` does not show a user, ask the user to run
`linear auth login`; and it needs `~/.config/linear42/config.json` (`workspace`, `default_team`, `poll_seconds`).
The full steps are in the `linear42-general` skill.

## Approve Plan

The green **Approve Plan** action (action area and command palette) is the human gate between Planning and In-Progress. It is enabled only while a spec document is set on an attached issue, `plan/subtasks` (the sub-issue mirror) is non-empty, and `plan/approved_at` isn't set. Clicking it writes `plan/approved_by` (the macOS username) then `plan/approved_at` (ISO-8601); that second write re-checks the gates and the session receives "In-Progress is now available". Approving from the other side also works: moving the issue into a started state in Linear while in Planning.

The widget doesn't talk to Linear. Within one poll the sync agent (see `widget-linear-issue`) comments "Plan approved in Work42 by <user> — spec: <url>" on the issue, moves it to the In-Progress state and sets `linear/approval_stamped`.

## Revoking

Once approved the button reads **Plan approved**. Tapping it asks to revoke; confirming deletes `plan/approved_at` and `plan/approved_by`. The sync agent then posts "Plan approval revoked in Work42 by <user>" on each issue with a spec and clears `linear/approval_stamped`. Each session has its own button state.

## Editing an approved spec

Nothing clears the approval when the document is edited. After revising the spec in Planning (`publish-doc.py … --slug`), delete `plan/approved_at` and `plan/approved_by` yourself so the plan is re-approved; leave `linear/approval_stamped` to the sync agent. Planning is the only stage that allows the document update and these deletes.
