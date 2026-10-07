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

The Plan view has three tabs: **Issue Details** (the issue page, with sub-issues and comments),
**Spec Document** (with **Approve Plan**) and **Testing Plan Document**. Review adds the
GitHub widget. Approval works from either side: click **Approve Plan**, or move an attached issue to
a started state in Linear while the session is still in Planning (only a move *into* started
counts, so attaching an issue that's already in progress never approves anything).

## Several issues in one session

A session can have more than one Linear issue. Issue Details shows **one tab per attached issue**, the
header shows **one pill per issue** (key on Linear purple, then its status in its own colour), and
storage is scoped per issue: `linear/issue_keys` lists the attached keys and each issue keeps
`linear/issues/<KEY>/{issue,spec_doc,testing_doc,last_state_type,pushed_stage}`. A single-issue session
from an earlier version is migrated on its first poll (flat `linear/issue`, `linear/spec_doc`… move under
the issue's key, then the old keys are removed). The agent decides how to plan across the issues: one shared
plan or one plan per issue.

- **Attach.** A link to an issue that isn't attached (a sub-issue, say) opens in a temporary tab with an
  "Attach WOR-9 to this session?" bar: **Attach** adds it, **Not now** leaves it as a temporary tab.
- **Detach.** Closing an attached issue's tab asks first; **Detach** removes it and its sub-issues leave the
  subtask list. Nothing changes in Linear. The last attached issue can't be detached.
- **Spec Document / Testing Plan Document** show one tab per document (`📐 WOR-6 Spec`, `🧪 WOR-6 Testing
  Plan`). **Approve Plan** approves the whole session plan.
- The sync (below) covers every attached issue: sub-issues of all of them are mirrored into `plan/subtasks`,
  any of them moving to a started state approves the plan, a stage change moves all of them.

## Links between widgets

Every link clicked in a browser widget goes to **Open Link**, which picks the best *available* widget for
the URL (open or not): a regex or scheme match beats the Browser, which opens anything. Each Linear widget owns
the URLs of its kind: `/issue/<KEY>` is **Issue Details**, a document titled `… Spec` is **Spec Document**,
`… Testing Plan` is **Testing Plan Document** (patterns in `Linear42Links.swift`; a document of an issue that
isn't attached opens in a temporary tab). The owning widget is brought forward with the focus ring and shows
the page, so the page you clicked in doesn't navigate. This also works for Linear's own in-page navigation,
because the click is caught inside the page. Option-click navigates in place.

| You click in | Nobody owns it | One owner | Two or more |
| -- | -- | -- | -- |
| the built-in Browser | stays in the Browser | picker: the owner or *Keep in Browser* | picker: the owners or *Keep in Browser* |
| a specific widget | the Browser opens it | the owner opens it (no picker) | picker: the owners |

## Specs, artifacts and `publish-doc.py`

The Planner writes the spec and testing plan as Linear Documents. Linear renders neither raw HTML
nor iframes, so an artifact (`[[artifact:<id>]]` in the markdown) can't appear in a document as
such. `skills/linear42-general/publish-doc.py` publishes the markdown and replaces each token with a
screenshot of the artifact (`work42 artifact snapshot`, uploaded through Linear's file upload) plus
an **Open in Work42** link, `work42://session/<session id>/artifact/<artifact id>`, which reopens
the live artifact in the app (also from outside it: Safari, the Linear desktop app). Unchanged
artifacts aren't uploaded again, and a failed snapshot or upload leaves the document untouched.
The Work42 app must be running (it hosts the artifact server). The uploaded images need a Linear login to view (an
anonymous request for one returns 401).

## How the sync works (the `linear-issue` widget's background agent)

The agent drives the session only in `linear-task` sessions. The host starts a widget's background agent in
every session where the widget is *available*, not only where it is placed, so on its first cycle the agent
reads its session's type (`work42 session show`). In a `linear-task` session it does everything below. In any
other known type (a task42 or chat session where you added the widget and bound an issue) it only **shows**
the labels (issue key, status, sub-issue count) and keeps `linear/issues/<KEY>/issue` current: it never mirrors
sub-issues into `plan/subtasks`, never approves or moves anything, and never posts comments. With no attached issue, or when
the type can't be read (Home has no session), it stays idle.

Every poll, one `linear api` GraphQL call **per attached issue** feeds: issue resolution; the `plan/subtasks` mirror (the
sub-issues of all attached issues, each once, in attach order; left untouched when any issue failed to load)
(a sub-issue is `done` only in a `completed` state — canceled doesn't count); approval
read-back (any attached issue); the stage → Linear state push; and a retry of the approval stamp (a comment
linking the spec, plus the In-Progress state). It also **relays Linear comments to the agent**:
a new comment or reply on the issue, on any of its sub-issues, or inline on the spec / testing
documents arrives in the session's chat as a system event ("<name> left you a comment on Linear
<url>", the quoted passage for inline comments, then the comment), through
`work42 event post --fingerprint …` so a retry never double-posts. The first poll after binding
only records existing comments, and every comment Work42 itself posts ends with
`_Posted from Work42_` so it is never relayed back. Config problems, a missing mapped state, a
missing or signed-out `linear` CLI, and an approval made in Linear are delivered the same way. It is the **only writer to Linear**, which keeps
the Approve button and the agent from racing. The first poll of a bound session in Planning
records the stage without pushing, so an in-progress issue is never demoted.

## Bundle layout

```
linear42/
  plugin.yaml
  workflows/linear42.json          task42's stages/transitions/gates + per-stage rules for the linear CLI
  session-types/linear-task.json   same five tabs as task42; Plan = linear-issue/spec/testing, Review = github + linear-issue
  intents/new-linear-task.json     "New Linear Task" (optional `issue` arg -> linear/issue_ref, which seeds the first issue)
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
