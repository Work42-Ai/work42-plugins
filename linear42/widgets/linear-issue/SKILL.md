---
name: widget-linear-issue
description: How the Issue Details widget (kindId widget:linear-issue) works, and the `linear/*` session-storage contract the linear42 plugin uses. It shows the attached Linear issues; a per-session background sync agent mirrors Linear into the keys the workflow gates read. Use it to bind a session to an issue, read what the sync agent resolved, or understand why a Linear change did or didn't reach the gates.
---

# Issue Details widget

Shows the Linear issues attached to this session in an embedded browser, one tab per issue (your normal linear.app login; no token handling here). A link to an issue that isn't attached opens a temporary tab with an "Attach <KEY> to this session?" bar; closing an attached tab asks before detaching it (the last can't be detached). States: **Unbound** (an Attach field: a key like `WOR-123` or an issue URL), **Bound** (a tab per issue, with notice bars for `linear` CLI problems), **Not configured** (a notice naming what is wrong with `~/.config/linear42/config.json`; see `linear42-general`).

## Prerequisites

This widget reads Linear through the `linear` CLI. If `command -v linear` prints nothing, install it with
`brew install schpet/tap/linear`; if `linear auth whoami` does not show a user, ask the user to run
`linear auth login`; and it needs `~/.config/linear42/config.json` (`workspace`, `default_team`, `poll_seconds`).
The full steps are in the `linear42-general` skill.

## Header pills

Each attached issue is one capsule: the key on Linear purple, the status in that state's own Linear colour, and, when the issue has sub-issues, its own `done/total` count. A failed issue keeps its last pill. Warnings (`linear42: not configured`, `linear CLI not installed`, `linear: sign in`, `not found`, `no state "<name>"`) show as chips; fix the cause and the chip clears on the next poll.

## Storage keys (`linear` namespace unless noted)

| Key | Shape | Written by |
|-----|-------|------------|
| `linear/issue_keys` | array of attached issue keys | sync agent, Attach/Detach, the Planner (to attach another) |
| `linear/issue_ref` | issue key or URL; **seeds the first issue only** | create arg, Attach field, My Linear Issues |
| `linear/issues/<KEY>/issue` | `{key,id,url,team,title}` | sync agent, once resolved |
| `linear/issues/<KEY>/spec_doc`, `testing_doc` | `{slug,url}` | Planner, after `publish-doc.py` |
| `linear/issues/<KEY>/last_state_type`, `pushed_stage` | state type at the last poll; last stage pushed | sync agent |
| `linear/resolve_error`, `linear/cli_error` | `"not_found"`; `"missing"` or `"auth"` | sync agent |
| `linear/approval_stamped` | `true` once Linear shows the approval | Approve action / sync agent |
| `plan/subtasks` | `[{id,title,description,done,state}]`, the sub-issue mirror | sync agent **only** |
| `plan/approved_at`, `plan/approved_by` | the In-Progress gate's signal | Approve action, sync agent |

```bash
work42 storage set linear/issue_ref '"WOR-123"'                    # bind (or use the Attach field)
work42 storage set linear/issue_keys '["WOR-123","WOR-124"]'       # attach another: write the whole array
work42 storage get linear/issues/WOR-123/issue                     # what the sync agent resolved
```

Never write `plan/subtasks` yourself: create or complete sub-issues with `linear` and the next poll updates the gates.

## The sync agent

Runs per session every `poll_seconds` with one `linear api` call.

- **Resolves** each attached issue and **shows its pill** in every session type that has a bound issue.
- **Pushes the stage** to each issue's Linear state when the session stage changes: Planning → `unstarted`, In-Progress and Testing → `started`, Human Review → a started state named like "review", Done → `completed` (lowest position of that type, or the exact name in `stage_states`). This happens in any known session type, so a task42 session with an issue attached follows its stage too. A freshly bound session in Planning never demotes the issue.
- **`linear-task` sessions only**, it also drives the session: mirrors sub-issues into `plan/subtasks` (`done` only in a `completed` state; a failed poll leaves the mirror untouched), reads approval back (the issue moving INTO a started state in Planning, with a spec document and a sub-issue, writes `plan/approved_at` with `plan/approved_by = linear`), stamps Work42 approvals onto the issue (retrying until `linear/approval_stamped`), posts "Plan approval revoked in Work42" when an approval is cleared, and relays other people's Linear comments into chat.

The widget never talks to Linear itself and never writes outside the `linear` namespace.
