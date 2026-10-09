---
name: widget-linear-my-issues
description: How the My Linear Issues widget (kindId widget:linear-my-issues) works. It shows your assigned Linear issues in an embedded browser and starts a linear-task session bound to the issue on screen. Use it to understand how a session gets its issue from the list, and what to check when "Start Linear Session" is disabled.
---

# My Linear Issues widget

An embedded browser on `https://linear.app/<workspace>/my-issues/assigned`. The workspace comes from `~/.config/linear42/config.json` (re-read every few seconds, so a change applies live); if the config is missing or incomplete the widget shows a notice instead. Authentication is the shared browser login.

**Start Linear Session** (action area and command palette) is enabled whenever the page shows an issue (`…/issue/WOR-123/…`). It opens a `linear-task` session named `WOR-123: <issue title>` on Linear's suggested branch for the issue (the same name its GitHub integration links on; the bare key and a random branch if the `linear` CLI can't be reached) and seeds its `linear/issue_ref` with the key, so Issue Details loads the issue at once and the sync agent resolves it. Greyed out? Open an issue from the list first: the widget reads the current page URL.

The widget stores nothing and has no background agent.

## Prerequisites

This widget reads Linear through the `linear` CLI. If `command -v linear` prints nothing, install it with
`brew install schpet/tap/linear`; if `linear auth whoami` does not show a user, ask the user to run
`linear auth login`; and it needs `~/.config/linear42/config.json` (`workspace`, `default_team`, `poll_seconds`).
The full steps are in the `linear42-general` skill.
