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

## The sync agent (what keeps Linear and the gates aligned)

A per-session background agent runs every `poll_seconds` with one `linear api` call:

- **Resolves** `linear/issue_ref` into `linear/issue`.
- **Mirrors sub-issues** into `plan/subtasks`. A sub-issue is `done` only in a
  `completed` state (canceled does not count). Completing one in Linear, by you or
  by the Worker, is what opens the Testing gate. A failed poll leaves the mirror
  untouched.
- **Reads approval back.** If the issue moves INTO a `started` state while the
  session is in Planning, a spec doc and at least one sub-issue exist, and it was
  not already started when first seen, the agent writes `plan/approved_at`
  (`plan/approved_by` = `linear`). That write re-checks the gates and posts the
  usual "In-Progress is now available" message. You then run
  `work42 transition "In-Progress"`.
- **Pushes the stage** to Linear when the session stage changes: Planning ->
  `unstarted`, In-Progress and Testing -> `started`, Human Review -> a started state
  named like "review", Done -> `completed` (lowest position of that type, or the exact
  name in `stage_states`). The first poll of a freshly bound session never demotes
  the issue: it records the stage without pushing.
- **Stamps approvals** made in Work42 onto the issue (a comment linking the spec, and
  the In-Progress state), retrying until `linear/approval_stamped` is `true`.

Problems show up as header chips and notices rather than chat events: `linear42: not
configured`, `linear CLI not installed`, `linear: sign in`, `not found`, and
`no state "<name>"` (a `stage_states` entry that doesn't exist for the team).
Fix the cause (config, install, `linear auth login`) and the chip clears on the next poll.

## What the widget does NOT do

It does not publish the header chips or talk to Linear itself: both come from
the background sync agent. It never writes outside the `linear` namespace.
