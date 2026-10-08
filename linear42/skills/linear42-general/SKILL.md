---
name: linear42-general
description: The linear42 task lifecycle — a Linear-native replacement for task42. A task is a work42 SESSION of type `linear-task` bound to one or more Linear issues. The spec, testing plan and QA report are Linear documents, subtasks are sub-issues; session storage holds only the gate signals, which a background sync agent mirrors. Covers the storage model, config, what each stage may run, the `linear` CLI, publish-doc.py, and the rules every linear42 agent follows.
---

# linear42 — task lifecycle (Linear-native)

A **task is a work42 session** of type `linear-task`, bound to one or more Linear issues. The plan lives in Linear; the workflow's **gates** live in session storage, and a background **sync agent** keeps them aligned. You use two CLIs: `work42` (storage, transitions, artifacts, devices) and `linear`. Never edit `~/.work42/work42.db` by hand.

## Where things live

| What | Where | Written by |
|------|-------|-----------|
| Spec | Linear document `<KEY> Spec` 📐; `linear/issues/<KEY>/spec_doc` = `{slug,url}` | Planner |
| Testing plan | document `<KEY> Testing Plan` 🧪; `.../testing_doc` | Planner |
| Subtasks | Linear sub-issues, mirrored into `plan/subtasks` | Planner creates; Worker completes in Linear |
| Approval | `plan/approved_at`, `plan/approved_by` | Approve Plan button, or moving the issue to a started state in Linear |
| QA report | document `<KEY> QA Report` 🧾; `qa/docs` = `{<KEY>:{slug,url}}`, `qa/report` = first document's URL | QA |
| QA verdict | `qa/verdict` = `"PASS"` or `"FAIL"` | QA |
| PRs | `github/prs`; the PR body says `Fixes <KEY>` | Lead |
| Attached issues | `linear/issue_keys` (array), `linear/issue_ref` (seeds the first), `linear/issues/<KEY>/issue` `{key,id,url,team,title}` | Planner / sync agent |

**`plan/subtasks` belongs to the sync agent.** It rewrites the array from the sub-issues on every poll (`done` only for a `completed` state), so create or complete sub-issues with `linear` and never write it. Latency is up to `poll_seconds` (60 s). Each stage entry also moves each attached issue in Linear (Planning → unstarted, In-Progress and Testing → started, Human Review → the started "review" state, Done → completed); don't move the issue yourself. Other storage keys: `linear/issues/<KEY>/last_state_type`, `pushed_stage`, `linear/approval_stamped` (sync agent). Build JSON for storage with `jq -n --arg`, never shell string substitution.

## Config — `~/.config/linear42/config.json`

```json
{ "workspace": "work42", "default_team": "WOR", "poll_seconds": 60,
  "stage_states": { "WOR": { "Human Review": "In Review" } } }
```

Re-read on every poll and action. Nothing about the team, workspace or state names is hardcoded: read values with `jq -r .default_team ~/.config/linear42/config.json`. `stage_states` pins a stage to an exact Linear state name per team. When Yan asks for a change ("use team OPS"), edit the file; if a value is missing, ask, never guess.

## Stages, gates, transitions

`Planning → In-Progress → Testing → Human Review → Done`. Gates read storage: In-Progress needs `plan/approved_at` and a non-empty `plan/subtasks`; Testing needs every subtask done; Human Review needs `qa/verdict == "PASS"`; Done needs every `github/prs` entry merged. **A holding gate does not move the task.** The session receives `<Stage> is now available — run work42 transition "<Stage>"`: run that command. Only Yan approves a plan.

## What each stage may run

The workflow blocks the rest (a blocked command is refused, an unlisted one may ask Yan).

| Stage | May write |
|-------|-----------|
| Planning | Plan content only: documents (`publish-doc.py` spec/testing, `linear document create/update`), artifacts, `plan/spec`, `plan/testing`, `linear/` keys, issues and sub-issues, clearing the approval. File edits blocked: pipe content on stdin. |
| In-Progress | Code (edits, git), issues, sub-issues, comments. No documents, no artifacts. |
| Testing | `qa/` keys, `publish-doc.py --kind qa`, device recordings, `ffmpeg`, `screencapture`. No file edits, no Linear issue writes, no other documents. |
| Human Review | `gh pr …` and `github/prs`. No Linear writes, no artifacts. |
| Done | Nothing. |

Reads (`linear … view/list/query`, `work42 storage get/list`, `work42 artifact list/status/url`) are allowed everywhere.

## The `linear` CLI (schpet/linear-cli)

Sign in once with `linear auth login`. Exit codes: 0 ok · 3 not found · 4 auth failed · 5 rate-limited. Use `--json` where offered.

- `linear issue view <KEY>`, `linear issue query --team <T> --search "…" --json`
- `linear issue create --team <T> --title "…" --description-file - [--parent <KEY>]`
- `linear issue update <KEY> --state completed` (how the Worker completes a sub-issue)
- `linear issue comment add <KEY> --body-file -`
- `linear api 'query{document(id:"<slug>"){content}}'` reads a document exactly as stored.
- `linear document view <slug> --raw` is for reading only. Never feed its output into an update: it rewrites image links and breaks every image.

## publish-doc.py — the only way to write a document

`.claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind spec|testing|qa --file - [--slug <slug>]`, run directly (not through `python3`), markdown on stdin. It prints `{"slug","url"}` and exits 1 leaving the document untouched if anything fails.

- Creates `<KEY> Spec` / `<KEY> Testing Plan` / `<KEY> QA Report`; with `--slug` it rewrites that document with the **whole** new markdown. Spec and testing are refused outside Planning.
- Each standalone `[[artifact:<id>]]` line becomes the artifact's title as a link back to Work42 plus its screenshot (Linear can't render the HTML).
- A local `![alt](/abs/path)` image or video is uploaded and replaced by its Linear URL (a video as a ▶ link plus a poster frame). Needs `ffmpeg` for videos.
- The Work42 app must be running (it hosts the artifact server). If `linear document update` refuses because of open comments, tell Yan and wait; never add `--force`.

## Comments

End every comment you post to Linear with `_Posted from Work42_`; the sync agent relays every other new comment on the issues, sub-issues and documents into chat as a system event (`<name> left you a comment on Linear <url>`). Answer in chat first; reply on Linear only when asked.

## When something goes wrong

Problems show as **header chips** and widget notices: `linear42: not configured` (fix the config), `linear CLI not installed` (`brew install schpet/tap/linear`), `linear: sign in` (`linear auth login`), `not found` (bad key), `no state "<name>"` (a `stage_states` entry the team lacks). If a command fails or you need something you can't resolve, **stop, tell Yan exactly what you need in chat, and wait**. Never work around it.

## Roles (skills the Lead loads: one agent, one conversation, no subagents)

Yan approves the plan, reviews the build and merges. **Lead** (`linear42-lead`) orchestrates. **Planner** (`linear42-planner`) understands the task and authors the spec, testing plan and sub-issues. **Worker** (`linear42-worker`) implements one sub-issue. **QA** (`linear42-qa`) executes the testing plan and reports.

## Rules for all agents

1. Work in the session worktree, never the main checkout. Commit and push before completing a sub-issue.
2. Every fix is its own sub-issue (`--parent`), implemented by the Worker.
3. Never hand-set a stage: satisfy the gate, wait for the "now available" message, run `work42 transition`.
4. Never write `plan/subtasks`; never approve on Yan's behalf.
5. Before calling a task done, verify every `github/prs` entry is merged.
6. The chat is the log: narrate decisions, blockers and results.
