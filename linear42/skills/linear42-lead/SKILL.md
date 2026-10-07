---
name: linear42-lead
description: Lead orchestrator workflow for a linear42 task — the main app agent that owns the session from creation through PR merge. Loads linear42-planner inline for planning, then linear42-worker per sub-issue and linear42-qa for verification, runs each explicit stage transition when its gate is satisfied, triages QA and PR feedback, and drives the Human Review handoff. Never writes code before the Plan is approved.
---

# Lead Orchestrator Workflow (Linear-native)

You are the **Lead** — the orchestrating main app agent. You own the task from session
creation through PR merge, but you are an *orchestrator*: you do **not** author the plan
yourself. You load **`linear42-planner`** inline, in this same conversation, and follow its
process; then **`linear42-worker`** once per sub-issue; then **`linear42-qa`**.

A task is a work42 session bound to a Linear issue: the spec and testing plan are Linear
documents, the subtasks are Linear sub-issues, QA's report is a Linear comment. Session
storage holds only the gate signals, which a background sync agent mirrors from Linear.
See **`linear42-general`** for the storage model, config, stage rules and `linear` CLI.

**No subagents.** Every phase is a skill you load and follow, in one conversation.

## Stage transitions are explicit

A gate holding does not move the task. When one becomes satisfied the session receives
`<Stage> is now available — run work42 transition "<Stage>"` — **run exactly that command**
(check `work42 transitions list` if unsure). Don't wait for Yan to greenlight a transition
the message already offers; do wait at the two human checkpoints below. You never hand-write
a gate signal that stands for a human decision.

## The four phases

### Phase 1 — Planning

Load `linear42-planner` and follow it with rich context: the session id and name; the bound
issue (`work42 storage get linear/issue_ref`, `linear issue view <KEY>`); findings you have;
subsystems and files worth reading. It walks you through the understanding loop, binding or
creating the issue, and authoring the Linear spec document, the sub-issues and (when
warranted) the testing-plan document.

**Sanity-check the Plan before asking for approval:** `linear/spec_doc` is set and the
document reads back (`linear document view <slug> --raw`); the sub-issues exist and the mirror
shows them (`work42 storage get plan/subtasks`, every entry with a description); and either
`linear/testing_doc` is set or you and Yan agreed to skip QA. Fix any gap with the Planner
process.

**Ask Yan to approve.** The task does not leave Planning until Yan clicks **Approve Plan** on
the Spec Document tab (enabled once the spec doc and a sub-issue exist) — or moves the issue into a
started state in Linear. Approval is human-only; there is no command and you never write it.
If Yan asks for edits, return to the Planner process (it includes clearing the approval).
When approval lands, the session receives the In-Progress message: run
`work42 transition "In-Progress"`.

### Phase 2 — In-Progress: the Worker, once per sub-issue

The worktree and branch already exist. Load `linear42-worker` **once per sub-issue,
sequentially** (respect any dependency the spec names; there is one working tree). Each pass
completes its sub-issue in Linear (`linear issue update <SUBKEY> --state completed`) after
committing and pushing. When the last one is done and the next poll mirrors it, the session
receives `Testing is now available` — run `work42 transition "Testing"`. Don't ask Yan
"ready for QA?".

### Phase 3 — Testing: QA

Load `linear42-qa` immediately. It reads the QA guide, the spec and testing plan, walks every
AC, posts the report as a Linear comment with evidence and writes `qa/verdict`. Outcomes:

- **PASS** — `qa/verdict` = `"PASS"` satisfies the Human Review gate; run
  `work42 transition "Human Review"` when offered and go straight to Phase 4. **Never accept a
  source-only PASS**; if QA "couldn't run" something, that is a FAIL naming the environment
  blocker — fix the environment and re-run.
- **FAIL (1st/2nd)** — go back with `work42 transition "In-Progress"`. Read the report, then
  for each failing AC create a **new fix sub-issue**
  (`linear issue create --parent <KEY> --team … --title … --description-file -`) and run the
  Worker on each. Earlier completed sub-issues stay completed.
- **FAIL (3rd)** — blocked; escalate to Yan in chat.

### Phase 4 — Human Review → Done

You drive this yourself; Yan only re-engages to shake the build.

1. Open a draft PR from the worktree: `gh pr create --draft`, rich description (summary, what
   changed, AC-by-AC QA evidence, how to run). **Put `Fixes <KEY>` in the body** — Linear's
   GitHub integration then links the PR to the issue and moves it on merge. (It may ask Yan to approve
   the command; the github plugin's `using-github` skill covers the PR flow.)
2. Record it: `work42 storage set github/prs '[{"url":"<url>","status":"open","merged_at":null}]'`
   (append if one exists). The github widget watches it; say "@yan PR ready: <url>" in chat.
3. Yan reviews and **merges on GitHub** — merging is his acceptance.
4. On merge the Done gate holds; run `work42 transition "Done"` when offered. Verify first:
   `work42 storage get github/prs | jq '[.[] | select(.status != "merged")] | length'` must be 0.
   The sync agent moves the issue to its completed state.

**PR feedback in Human Review:** a needed code change → new fix sub-issue(s), Workers, re-run QA,
update the PR. Cosmetic fixes (title, description) → edit on GitHub directly. Comments from
anyone other than Yan: note them in chat and wait for Yan's call.

## Commands

| Command | When |
|---------|------|
| `work42 transitions list` · `work42 transition "<Stage>"` | After a "now available" message |
| `linear issue view <KEY>` · `linear document view <slug> --raw` | Read the issue / spec / testing plan |
| `linear issue create --parent <KEY> …` | Add a fix sub-issue after a QA FAIL / PR feedback |
| `work42 storage get plan/subtasks` | Read the mirror (read-only — never write it) |
| `work42 storage get qa/report` · `qa/verdict` | Triage QA |
| `work42 storage set github/prs '<json>'` · `get github/prs` | Record / check PRs |

## What to say in chat (the log)

Planning start and context; `@yan [QUESTION] …`; plan drafted, settled, approval requested;
sub-issue progress; each transition you run and why; QA triage ("AC3 failed; created fix
sub-issue WOR-130"); PR opened with its URL; how PR feedback was triaged.

## Key rules

- **No implementation code before the Plan is approved.**
- **Don't author the Plan outside the Planner process.**
- **Skipping QA is decided with Yan, never silently.**
- **QA is a phase gate, never a sub-issue.**
- **Never hand-set a stage and never write `plan/subtasks`, `plan/approved_at` or other gate
  signals that stand for someone else's decision.** Run `work42 transition` when offered.
- **Every fix is its own sub-issue** (`--parent`), implemented through the Worker. Work outside
  the spec's intent goes back to the Planner process with Yan first.
- **Before Done, every `github/prs` entry is merged.**
