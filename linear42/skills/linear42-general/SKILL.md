---
name: linear42-general
description: The linear42 task lifecycle — a Linear-native replacement for task42. A task is a work42 SESSION of type `linear-task` bound to a Linear issue. The spec and testing plan are Linear Documents, subtasks are Linear sub-issues, QA reports are Linear comments; session storage holds only the gate signals, which a background sync agent mirrors from Linear. Roles are skills the Lead follows in one conversation. Covers the storage model, the config file, the `linear` CLI verbs, explicit stage transitions, and the rules every linear42 agent follows.
---

# linear42 — Task Lifecycle (Linear-native)

A **task is a work42 session** of type `linear-task`, bound to **one Linear issue**.
The content of the plan lives in Linear; the workflow's **gates** live in session
storage, and a background **sync agent** keeps the two aligned. Everything you do goes
through two CLIs: `work42` (session storage, transitions, artifacts) and `linear`
(everything in Linear). Never edit `~/.work42/work42.db` by hand.

## Where things live

| What | Where | Who writes it |
|------|-------|---------------|
| The spec | a Linear **Document** attached to the issue (`linear/spec_doc` = `{slug,url}`) | the Planner |
| The testing plan | a second Linear Document, titled "Testing plan" (`linear/testing_doc`) | the Planner |
| Subtasks | Linear **sub-issues** of the issue (mirrored into `plan/subtasks`) | the Planner creates; the Worker completes in Linear |
| Approval | `plan/approved_at` / `plan/approved_by` | the **Approve Plan** button, or the sync agent when you move the issue into a started state in Linear |
| QA report | a Linear **comment** with evidence attached; `qa/report` holds its URL | QA |
| QA verdict | `qa/verdict` = `"PASS"` or `"FAIL"` | QA |
| PRs | `github/prs` (the reused github widget); the PR body says `Fixes <KEY>` | the Lead |

**`plan/subtasks` is owned by the sync agent.** It rewrites the array from the
sub-issues on every poll (`done` is true only for a `completed` state; canceled does not
count). Never write it yourself; create or complete sub-issues with `linear` and the next
poll updates the gate. Latency is up to `poll_seconds` (default 60s).

## Config — `~/.config/linear42/config.json`

```json
{ "workspace": "work42", "default_team": "WOR", "poll_seconds": 60,
  "stage_states": { "WOR": { "Human Review": "In Review" } } }
```

Re-read on every poll and action; edits apply without a restart. **Nothing about the
team, workspace or state names is hardcoded anywhere — read it from here.**
`default_team` is the team for issues you create; `stage_states` pins a workflow stage to
an exact Linear state name for a team (otherwise stages map by state *type*). When the
user asks to change it ("use team OPS"), edit this file; never guess a missing value —
ask. Read a value: `jq -r .default_team ~/.config/linear42/config.json`.

## Stages, gates, and explicit transitions

```
Planning → In-Progress → Testing → Human Review → Done
```

Gates are the same as task42's and read session storage: In-Progress needs
`plan/approved_at` and a non-empty `plan/subtasks`; Testing needs every `plan/subtasks`
entry done; Human Review needs `qa/verdict == "PASS"`; Done needs every `github/prs` entry
merged. **A gate holding does not move the task.** When one becomes satisfied the session
receives `<Stage> is now available — run work42 transition "<Stage>"`: **run that command.**
Only the human clicks Approve Plan (or moves the issue in Linear); agents never write
`plan/approved_at` for a plan the human hasn't approved.

Each stage entry also moves the Linear issue to its mapped state automatically (the sync
agent does it — don't move the parent issue's state yourself): Planning → unstarted,
In-Progress/Testing → started, Human Review → a started "review" state, Done → completed.

## What each stage allows (the workflow enforces this)

Each stage has **block** rules (always refused) and **allow** rules (auto-approved, no prompt);
any other command either runs or asks Yan to approve, depending on the session's permission
mode. In **Planning** the Write/Edit tools are blocked, so don't write files: pipe content
through stdin (`--content-file -` with a quoted heredoc) instead of using temp files. You can
still create and update issues and documents there. `linear document create/update` (and
the `publish-doc.py` helper that wraps them) is **blocked in every other stage** — the spec and
testing plan are authored in Planning. In
**In-Progress** you edit code and may create/update issues and comments. **Testing** adds
`work42 storage set qa/…` and blocks edits. **Human Review** and **Done** are read-only plus
comments (`gh pr create` and `work42 storage set github/prs` may ask Yan to approve there).

## The `linear` CLI (schpet/linear-cli)

Install: `brew install schpet/tap/linear`; sign in once: `linear auth login`. Exit codes:
0 ok · 3 not found · 4 auth failed · 5 rate-limited/unavailable. Use `--json` where offered.

| Command | Use |
|---------|-----|
| `linear issue view <KEY>` / `--json` | Read an issue (description, comments) |
| `linear issue query --team <T> --search "…" --json` | Find issues |
| `linear issue create --team <T> --title "…" --description-file - [--parent <KEY>] [--state <name\|type>]` | Create an issue or, with `--parent`, a sub-issue |
| `linear issue update <KEY> --state completed` | Change state (by name or type); how the Worker completes a sub-issue |
| `linear issue comment add <KEY> --body "…"` / `--body-file -` / `-a <file>` | Comment; `-a` uploads evidence (images render inline) |
| `.claude/skills/linear42-general/publish-doc.py --issue <KEY> --title "…" --file - [--slug <slug>]` | Create a document on an issue, or with `--slug` update it. **The only way to write a spec or testing plan** (Planning only); see below |
| `linear api 'query{document(id:"<slug>"){content}}'` | Read a document back exactly as stored (image URLs intact) |
| `linear document view <slug> --raw` / `--json` | Read a document to understand it (slug = last path segment of its URL). **Never feed `--raw` output back into an update**: it rewrites image links to local cache paths and would break every image |
| `linear team list --json` | Teams and their keys |

### Publishing specs and testing plans

Linear renders neither raw HTML nor iframes, so an artifact can't live in a document as such.
Write the markdown with `[[artifact:<id>]]` tokens (one per line, as the Design section does)
and publish it through `publish-doc.py`: it renders each artifact to a PNG
(`work42 artifact snapshot`), uploads it to Linear, and replaces the token with the image plus an
`[Open in Work42](work42://session/<id>/artifact/<id>)` link back to the live artifact. Run it
**directly** (it is executable; the stage rules match it by name, not through `python3`), and pipe
the markdown on stdin because Planning blocks file writes:

```bash
.claude/skills/linear42-general/publish-doc.py --issue <KEY> --title "Spec" --file - <<'MD'
# <task>: <title>
…
[[artifact:layout]]
MD
```

It prints `{"slug","url"}`; record those in `linear/spec_doc` / `linear/testing_doc`. To revise,
run it again with `--slug <slug>` and the **whole** new markdown (unchanged artifacts are not
uploaded again). If a snapshot or upload fails it exits 1 and the document is untouched. The
artifact server is hosted by the Work42 app, so the app must be running. If `linear document
update` refuses because the document has open comments (it would detach them), tell Yan and wait
for them to be resolved — **never add `--force` yourself**.

### Comments: the footer, and what reaches you

Every comment you post to Linear (an issue comment, a QA report, a reply) **ends with the line
`_Posted from Work42_`**. The sync agent relays every other new comment on the issue, its
sub-issues and the spec / testing documents into this chat as a system event
(`<name> left you a comment on Linear <url>`, the quoted passage for an inline comment, then the
comment); the footer is how your own comments are recognized and not echoed back to you. Answer a
relayed comment in chat first; reply on Linear only when asked, with the footer.

## Storage keys (`work42 storage get|set|delete|list <ns>/<key>`; values are JSON)

`linear/issue_ref` (string) · `linear/issue` `{key,id,url,team,title}` · `linear/spec_doc`
and `linear/testing_doc` `{slug,url}` · `linear/last_state_type`, `linear/pushed_stage`,
`linear/approval_stamped` (sync agent) · `plan/subtasks` (sync agent) · `plan/approved_at`,
`plan/approved_by` · `qa/verdict`, `qa/report` · `github/prs`. The widget skills
(`widget-linear-issue`, `widget-linear-spec`) document each one.

When building JSON for a storage write, do it with `jq -n --arg` (or Python) rather than
shell string substitution — an apostrophe or `$` in the content silently corrupts it.

## When something goes wrong

There is no widget-to-chat event channel. Problems show as **header chips** and widget
notices: `linear42: not configured` (fix the config), `linear CLI not installed`
(`brew install schpet/tap/linear`), `linear: sign in` (`linear auth login`), `not found`
(bad issue key), `no state "<name>"` (a `stage_states` entry the team lacks). If a
`linear` command fails in your own shell, say so in chat and tell Yan what to run.

## Roles (skills the Lead loads — one agent, one conversation, no subagents)

| Role | Skill | Does |
|------|-------|------|
| Human (Yan) | — | Approves the plan, reviews the build, merges the PR |
| Lead | `linear42-lead` | Orchestrates the lifecycle |
| Planner | `linear42-planner` | Understands the task, asks questions, authors the Linear spec, testing plan and sub-issues |
| Worker | `linear42-worker` | Implements one sub-issue, then completes it in Linear |
| QA | `linear42-qa` | Verifies the acceptance criteria, posts the report, writes the verdict |

## Rules for all agents

1. **Work in the session worktree**, never the main checkout.
2. **Commit and push before completing a sub-issue.**
3. **Every fix is its own sub-issue.** Create it with `--parent`; implement it via the Worker.
4. **Never hand-set a stage.** Satisfy the gate, wait for the "now available" message, run `work42 transition`.
5. **Never write `plan/subtasks`; never approve on Yan's behalf.**
6. **Before calling a task done, verify every `github/prs` entry is merged.**
7. **The chat is the log.** Narrate decisions, blockers and results; silence is the worst outcome.
