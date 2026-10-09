---
name: widget-linear-qa
description: How the QA Report Document widget (kindId widget:linear-qa) works on a linear-task session. It renders the QA report as the Linear document QA published for each attached issue. Read-only.
---

# QA Report Document widget

Shows the QA report documents (`qa/docs`, `{"<KEY>": {slug,url}}`), one tab per document (`🧾 WOR-6 QA Report`), in an embedded browser on your linear.app login. Before QA has published one it shows "No QA report yet". It sits next to the GitHub PR in the Review tab.

QA publishes it with `publish-doc.py --issue <KEY> --kind qa --file -` (markdown on stdin, media uploaded; see `linear42-qa`) and records `qa/docs` and `qa/report`.

Links to a `… QA Report` document open here (the tab is focused and selected); one for an issue that isn't attached opens in a temporary tab. The widget never writes.

## Prerequisites

This widget reads Linear through the `linear` CLI. If `command -v linear` prints nothing, install it with
`brew install schpet/tap/linear`; if `linear auth whoami` does not show a user, ask the user to run
`linear auth login`; and it needs `~/.config/linear42/config.json` (`workspace`, `default_team`, `poll_seconds`).
The full steps are in the `linear42-general` skill.
