---
name: task42-general
description: work42 task lifecycle — exploration-first specs, roles as skills the Lead follows in one conversation (no subagents), worktree-per-session, explicit stage transitions, and QA that executes the testing plan with recordings. A task is a work42 SESSION of type `task`; its state lives in the session's namespaced storage. Covers the storage model, what each stage may run, the `work42` CLI and the rules every agent follows.
---

# work42 — task lifecycle

A **task is a work42 session** of type `task`. There is no separate `task42` CLI and no `tracker.db`: create it with `work42 session start`, and all of its state (spec, subtasks, QA, PRs, Jira) lives in the session's **namespaced key/value storage**. Everything goes through the `work42` CLI; never edit `~/.work42/work42.db` by hand. **The chat is the log**: there is no log command, so state progress, blockers, triage and QA results in chat.

## Stages, gates, transitions

`Planning → In-Progress → Testing → Human Review → Done`. Each stage has an entry gate over storage: In-Progress needs `plan/approved_at` and a non-empty `plan/subtasks`; Testing needs every subtask `done`; Human Review needs `qa/verdict == "PASS"`; Done needs every `github/prs` entry merged. **A holding gate does not move the task.** The session receives `<Stage> is now available — run work42 transition "<Stage>"`: run that command (`work42 transitions list` shows the options, `work42 workflow show` the gates and rules). Only Yan approves a plan. A Linear issue attached to the session follows each stage automatically (the linear42 sync agent moves it); don't move it yourself.

## Core rules

1. A task starts in Planning with a name and a workspace, and enters exploration at once.
2. **In-Progress requires Yan's approval of the Plan:** three facets authored together by the Planner and approved as one unit, the Spec (`plan/spec`), the Subtasks (`plan/subtasks`) and the Testing Plan (`plan/testing`). One click of the green **Approve Plan** button (the Plan tab: Spec · Subtasks · Testing Plan) writes `plan/approved_at` and `plan/approved_by`. There is no approve command.
3. **One worktree per session**, created at session start; all subtasks share it.
4. **Roles are skills the Lead loads, in one conversation: no subagents.** Yan approves the plan, shakes the build and merges. **Lead** (`task42-lead`) orchestrates. **Planner** (`task42-planner`) understands the task and authors the Plan. **Worker** (`task42-worker`) implements one subtask. **QA** (`task42-qa`) executes the testing plan.
5. **QA proves it.** It launches the project with `work42 debug start`, records the run with `work42 device` (or a screen recording where no device fits), and writes `qa/report` and `qa/verdict`. A PASS opens Human Review.
6. **The Lead opens the draft PR in Human Review** with QA's screenshots and recordings attached, and records it in `github/prs`.
7. **Never run into a wall quietly.** Anything you can't resolve (a missing tool or config, a failing environment): stop, say exactly what you need in chat, and wait for Yan.

## The Plan

- **Spec** (`plan/spec`): Context, Goals, Acceptance Criteria, Design, Out of Scope, Risks & Edge Cases, Open Questions. `SpecValidator` rejects a spec missing a required H2 section.
- **Subtasks** (`plan/subtasks`): `[{"id","title","description","done":false}]`. Each has a required `description`, so a Worker's task is its title and description, with the spec for context.
- **Testing Plan** (`plan/testing`): authored with QA's perspective; the script QA executes step by step, with the expected visual output per acceptance criterion.

## What each stage may run

The workflow blocks the rest (a blocked command is refused, an unlisted one may ask Yan).

| Stage | May write |
|-------|-----------|
| Planning | Plan content only: `plan/spec`, `plan/subtasks`, `plan/testing`, artifacts. File edits blocked. |
| In-Progress | Code (edits, git), `plan/subtasks` (marking `done`). No artifacts, no plan edits. |
| Testing | `qa/` keys, device recordings, `ffmpeg`, `screencapture`. No file edits. |
| Human Review | `gh pr …` and `github/prs`. |
| Done | Nothing. |

Reads (`work42 storage get/list`, `work42 artifact list/status/url`) are allowed everywhere.

## Project QA guide

`~/.work42/<project>/qa-guide.md` (Yan writes it) says how to test this product: the surfaces, credentials, fragile areas. *How to run* the product for each test is named in the Testing Plan: the `launch.json` config to start with `work42 debug start "<config>"` (confirm with `work42 debug configs`). Optional Flow42 coverage is authored with `flow42-qa-author` and always names separate `flow` and `variant` values.

## CLI reference

The session id comes from `WORK42_SESSION_ID` or `--session`; inside a task session omit it. Storage values must be canonical JSON.

| Command | Purpose |
|---------|---------|
| `work42 session start --type task --workspace <slug\|path> --name "..."` | Create a task session. `--storage ns/key=json` pre-seeds storage; `--branch repo=branch` starts a repo from a branch. |
| `work42 session types` · `work42 sessions list [--json] [--since <ts>]` | List session types / sessions. |
| `work42 storage set\|get\|list\|delete <ns>/<key> [<json>]` | Read and write task state (`set` upserts). |
| `work42 transitions list` · `work42 transition "<Stage>"` | Move along an edge whose gate holds. |

| Key | Meaning |
|-----|---------|
| `plan/spec`, `plan/subtasks`, `plan/testing` | The Plan facets. |
| `plan/approved_at`, `plan/approved_by` | Written by the Approve Plan button. |
| `qa/report`, `qa/verdict` | QA's report and `"PASS"` / `"FAIL"` (the Human Review gate). |
| `jira/url` | A Jira issue URL; the jira widget renders it. `work42 storage set jira/url '"<url>"'`. |
| `github/prs` | `[{url,status,merged_at}]`; the GitHub widget shows one tab per PR and delivers PR activity as system events. |

```bash
# Check merge discipline before considering the task done
work42 storage get github/prs | jq '[.[] | select(.status != "merged")] | length'   # must be 0
```

## Rules for all agents

1. Use `work42` commands only; work in the session worktree, never the main checkout.
2. Commit and push before marking a subtask `done` in `plan/subtasks`.
3. Never hand-set a stage: satisfy the gate, wait for the "now available" message, run `work42 transition`.
4. Every fix is its own subtask, implemented through the Worker.
5. Before calling a task done, verify every `github/prs` entry is merged.
6. Don't pause for Yan to greenlight a transition the session already offers; the human checkpoints are Plan approval and the merge.
