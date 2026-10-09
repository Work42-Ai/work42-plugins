---
name: widget-linear-testing
description: How the Testing Plan Document widget (kindId widget:linear-testing) works on a linear-task session. It renders the testing plan as the Linear document the Planner attached to the issue. Read-only.
---

# Testing Plan Document widget

Shows the testing-plan documents of the attached issues (`linear/issues/<KEY>/testing_doc`, a `{slug,url}`), one tab per document (`🧪 WOR-6 Testing Plan`), in an embedded browser on your linear.app login. Before any document exists it shows "No testing plan yet". It is the script QA executes at Testing.

The Planner publishes it with `publish-doc.py --issue <KEY> --kind testing --file -` (markdown on stdin, see `linear42-general`) and records the `{slug,url}` in `linear/issues/<KEY>/testing_doc`.

The widget never writes. There is no separate approval: the one Approve Plan click on the Spec Document tab covers the spec, the sub-issues and this document.

## Prerequisites

This widget reads Linear through the `linear` CLI. If `command -v linear` prints nothing, install it with
`brew install schpet/tap/linear`; if `linear auth whoami` does not show a user, ask the user to run
`linear auth login`; and it needs `~/.config/linear42/config.json` (`workspace`, `default_team`, `poll_seconds`).
The full steps are in the `linear42-general` skill.
