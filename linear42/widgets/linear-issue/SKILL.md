---
name: widget-linear-issue
description: |
  How the Linear Issue widget (session tab kindId widget:linear-issue) works on
  a linear-task session, and the full `linear/*` session-storage contract the
  linear42 plugin uses. The widget renders the bound Linear issue (sub-issues
  and comments included) from linear.app; a per-session background agent
  mirrors Linear state into the keys the workflow gates read. Use this when
  you need to bind a session to an issue, read what the sync agent resolved,
  or understand why a Linear change did or did not reach the gates.
---

# Linear Issue widget

Shows the Linear issue bound to this session in an embedded browser (your normal
linear.app login — no token handling here). Three states:

- **Unbound** — an Attach field. Enter a key (`WOR-123`) or an issue URL.
- **Bound** — the issue page. Notice bars appear above it for `linear` CLI
  problems.
- **Not configured** — a notice naming what is wrong with
  `~/.config/linear42/config.json`.

## Config — `~/.config/linear42/config.json`

Re-read on every poll and action; edits take effect without a restart.

```json
{
  "workspace": "work42",
  "default_team": "WOR",
  "poll_seconds": 60,
  "stage_states": { "WOR": { "Human Review": "In Review" } }
}
```

`workspace` and `default_team` are required. `poll_seconds` defaults to 60
(minimum 15). `stage_states` pins a workflow stage to an exact Linear state name
for a team; stages without an entry resolve by state *type*.

## Storage keys (all in the `linear` namespace unless noted)

| Key | Shape | Written by |
|-----|-------|------------|
| `linear/issue_ref` | string — issue key or URL | create arg, Attach field, My Linear issues, the Planner |
| `linear/issue` | `{"key","id","url","team","title"}` | sync agent, once the ref resolves |
| `linear/resolve_error` | `"not_found"` | sync agent |
| `linear/cli_error` | `"missing"` or `"auth"` | sync agent |
| `linear/spec_doc` | `{"slug","url"}` | Planner, after `linear document create` |
| `linear/testing_doc` | `{"slug","url"}` | Planner |
| `linear/last_state_type` | Linear state type of the issue at the last poll | sync agent |
| `linear/pushed_stage` | last workflow stage pushed to Linear | sync agent |
| `linear/approval_stamped` | `true` once Linear shows the approval | Approve action / sync agent |
| `plan/subtasks` | `[{"id","title","description","done","state"}]` — mirror of the sub-issues | sync agent **only** |
| `plan/approved_at`, `plan/approved_by` | approval signal the In-Progress gate reads | Approve action, sync agent |

## Agent usage

```bash
# Bind this session to an existing issue (or let the widget's Attach field do it)
work42 storage set linear/issue_ref '"WOR-123"'

# See what the sync agent resolved
work42 storage get linear/issue
```

Never write `plan/subtasks` yourself: the sync agent rewrites it from the
sub-issues on every poll. Create or complete sub-issues with the `linear` CLI
instead; the next poll updates the gates.

## What the widget does NOT do

It does not publish the header chips or talk to Linear itself: both come from
the background sync agent. It never writes outside the `linear` namespace.
