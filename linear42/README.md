# linear42 — the Linear-native task lifecycle

A first-party replacement for [`task42`](../task42) where **Linear holds the plan**:

| Plan piece | Lives in Linear as |
|------------|--------------------|
| Spec | a **Document** attached to the issue |
| Testing plan | a second **Document**, "Testing plan" |
| Subtasks | **sub-issues** of the issue |
| QA report | a **comment** with evidence attached |
| PR | `Fixes <KEY>` in its body, so Linear's GitHub integration links it |

The workflow is task42's: **Planning → In-Progress → Testing → Human Review → Done**, with
the same gates. Gates read *session storage*, so a background sync agent mirrors the
Linear state they need (`plan/subtasks`, `plan/approved_at`) from Linear. Everything is
configured from one file; nothing about your team, workspace or state names is hardcoded.

Code review reuses the [`github`](../github) plugin's `widget:github` unchanged (the same way
`patrol42` does), so that plugin must be installed — it is by default.

## Setup

```bash
brew install schpet/tap/linear     # the Linear CLI the agent and sync use
linear auth login                  # paste a Linear personal API key (once)
mkdir -p ~/.config/linear42
cat > ~/.config/linear42/config.json <<'JSON'
{ "workspace": "<your linear.app workspace>", "default_team": "<TEAM KEY>" }
JSON
work42 plugin install /path/to/work42-plugins/linear42     # not needed if it ships with the app
```

Widgets use your normal linear.app browser login (sign in once in any Linear tab); the CLI
uses the API key. Missing pieces show as warning chips in the session header and notices in the
widgets: `linear42: not configured`, `linear CLI not installed`, `linear: sign in`,
`not found`, `no state "<name>"`.

### `~/.config/linear42/config.json`

Re-read on every poll and action — edits apply without a restart.

| Field | Required | Meaning |
|-------|----------|---------|
| `workspace` | yes | The linear.app URL key (`https://linear.app/<workspace>/…`) |
| `default_team` | yes | Team key for issues the Planner creates |
| `poll_seconds` | no | Sync interval; default 60, minimum 15 |
| `stage_states` | no | `{ "<TEAM>": { "<Stage>": "<exact state name>" } }` — pins a stage to a state; stages without an entry map by state *type*, so new columns never break anything |

Default stage → state mapping: Planning → first `unstarted` · In-Progress, Testing → first
`started` · Human Review → a `started` state named like "*review*" (else no move) · Done →
first `completed` ("first" = lowest position).

## Using it

Start a session three ways (like the Jira plugin): the **My Linear Issues** widget's *Start
Linear Session*, **New Linear Task** with an issue key or URL, or **New Linear Task** blank —
the Planner then creates the issue in `default_team`.

The Plan view has three tabs: **Issue** (the issue page, with sub-issues and comments),
**Spec** (the spec document, with **Approve Plan**) and **Testing Plan**. Review adds the
GitHub widget. Approval works from either side: click **Approve Plan**, or move the issue to
a started state in Linear while the session is still in Planning (only a move *into* started
counts, so binding an issue that's already in progress never approves anything).

## How the sync works (the `linear-issue` widget's background agent)

Every poll, one `linear api` GraphQL call feeds: issue resolution; the `plan/subtasks` mirror
(a sub-issue is `done` only in a `completed` state — canceled doesn't count); approval
read-back; the stage → Linear state push; and a retry of the approval stamp (a comment
linking the spec, plus the In-Progress state). It is the **only writer to Linear**, which keeps
the Approve button and the agent from racing. The first poll of a bound session in Planning
records the stage without pushing, so an in-progress issue is never demoted.

## Bundle layout

```
linear42/
  plugin.yaml
  workflows/linear42.json          task42's stages/transitions/gates + per-stage rules for the linear CLI
  session-types/linear-task.json   same five tabs as task42; Plan = linear-issue/spec/testing, Review = github + linear-issue
  intents/new-linear-task.json     "New Linear Task" (optional `issue` arg -> linear/issue_ref)
  Sources/Plugin.swift             onCreate hook: linked To-Do
  widgets/
    linear-issue/                  issue page, Attach form, notices; the background sync agent + header chips
    linear-spec/                   spec document + Approve Plan
    linear-testing/                testing-plan document
    linear-my-issues/              assigned issues + Start Linear Session
  skills/
    linear42-{general,lead,planner,worker,qa,qa-author}/
  Tests/LogicTests/                standalone tests for the pure logic (run.sh)
```

## Stage rules

Block rules always refuse; allow rules auto-approve; anything else runs or asks you depending on
the session's permission mode. linear42 keeps all of task42's rules and adds allows for the
`linear` verbs each stage needs, plus a block on `linear document create/update` outside
Planning (the spec and testing plan are authored in Planning, like task42's `plan/spec` guard).

## Tests

```bash
linear42/Tests/LogicTests/run.sh   # stage mapping, approval rule, payload parsing, config, key parsing
work42 plugin test linear42        # manifest/bundle validation + build against the SDK
```

## Replacing task42

linear42 uses its own slugs (`linear-task`, `linear42`, `linear-*` widgets), so it installs
alongside task42. To switch a machine over, install linear42, then `work42 plugin remove
task42` once no task42 session is in flight (removal preserves storage).
