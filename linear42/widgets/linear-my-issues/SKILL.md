---
name: widget-linear-my-issues
description: |
  How the My Linear Issues widget (kindId widget:linear-my-issues) works. It shows the
  user's assigned Linear issues in an embedded browser and starts a linear-task
  session bound to the issue on screen. Use this to understand how a session gets
  its issue from the list, and what to check when "Start Linear Session" is disabled.
---

# My Linear Issues widget

An embedded browser on `https://linear.app/<workspace>/my-issues/assigned`. The
workspace comes from `~/.config/linear42/config.json` (re-read every few seconds, so
a changed workspace applies live). If the config is missing or incomplete the widget
shows a notice instead of the page. Authentication is the shared browser login: sign
in to Linear once and it persists.

## Start Linear Session

An action (action area + command palette) that is enabled whenever the page shows a
Linear issue (`…/issue/WOR-123/…`). It opens a new `linear-task` session named
`WOR-123: <issue title>` (the bare key if the `linear` CLI can't be reached) and
seeds that session's `linear/issue_ref` with the key, so its Issue tab loads the
issue straight away and the background sync agent resolves it.

If the action is greyed out, open an issue from the list first: the widget reads the
current page URL.

The widget stores nothing and has no background agent.
