---
name: linear42-worker
description: Worker skill — followed by the Lead (same agent, same conversation, no subagent) to implement exactly ONE Linear sub-issue in the shared task-session worktree. Read the sub-issue and the spec, implement, run checks, commit, push, then complete the sub-issue in Linear. Stay in lane.
---

# Worker Workflow (Linear-native)

**You are the Lead, now following the Worker skill** for **exactly one sub-issue** — not a
separate agent. When it is done you return to the `linear42-lead` process. This skill's
scope is one sub-issue at a time; load it again for the next one.

A task is a work42 session bound to a Linear issue whose **sub-issues are the subtasks**;
see **`linear42-general`** for the storage model and `linear` CLI.

## What you need before starting

- The **sub-issue key** (e.g. `WOR-124`) — one entry of the `plan/subtasks` mirror
  (`work42 storage get plan/subtasks`; `id` is the key).
- The worktree (`cd` there first) and the branch (already checked out).

**Your task is the sub-issue's title + description** — the Planner wrote the description to
stand on its own. The spec is your **wider context**.

## Your workflow

1. **`cd` to the worktree** and confirm you are not in the main checkout.
2. **Read your sub-issue, then the spec.**
   `linear issue view <SUBKEY>` for the title and description. Then the spec:
   `SLUG="$(work42 storage get linear/spec_doc | jq -r .slug)"; linear document view "$SLUG" --raw`.
3. **View every `[[artifact:<id>]]` in the spec before writing code** — they are confirmed
   visual decisions. `work42 artifact url <id>` / `status <id>`; your implementation must
   match. A missing artifact: say so in chat and pause for Yan — never guess a visual decision.
4. **Implement.** Stay in your lane: touch only what the sub-issue requires. If it overlaps
   another sub-issue's territory, say so in chat and stop rather than guess.
5. **Run local checks** (tests/lints; the QA guide at `~/.work42/<slug>/qa-guide.md` says how
   to exercise the build).
6. **`git add` + `git commit`**, referencing the sub-issue key in the message.
7. **`git push`** to the task branch.
8. **Complete the sub-issue in Linear** — only after commit AND push:
   `linear issue update <SUBKEY> --state completed`. That is the signal: within one poll the
   sync agent mirrors it into `plan/subtasks` (`done: true`). Do **not** write
   `plan/subtasks` yourself, and don't cancel a sub-issue to "finish" it (canceled does not
   count as done).
9. **Say it in chat:** "`<SUBKEY>` done. <one line>. Pushed <N> commits."
10. **Return to the `linear42-lead` process.**

When the last sub-issue is completed and the next poll lands, the session receives
`Testing is now available — run work42 transition "Testing"` (the Lead runs it).

## What to say in chat

Starting ("Starting WOR-124: …"), real progress, blockers (`@yan` + what you need), errors
with the failing output, and finishing. Silence is the worst outcome.

## PR and CI context

Push promptly. The Lead opens the draft PR in Human Review (body includes `Fixes <KEY>`) and
records it in `github/prs`; the github widget then reports PR activity. If a failing CI check
is reported while a PR is live, fix it and re-push without waiting to be asked.

## Key rules

- **One sub-issue per pass.**
- **Always work in the worktree.** Never edit the main checkout.
- **Check every `[[artifact:<id>]]` reference before implementing.**
- **Commit AND push before completing the sub-issue** — the Testing gate trusts the state.
- **All sub-issues share one branch.** Check the chat before touching a file another pass changed.
- **Complete only your own sub-issue.** Don't touch another.
- **Every fix you discover is its own sub-issue**, never an ad-hoc inline edit: surface it so
  the Lead creates `linear issue create --parent <KEY> …` and runs a later Worker pass.
- **Blocked? Say so in chat and stop.** Don't work around an ambiguity.

## Common mistakes

1. Completing the sub-issue before pushing. 2. Working in the main checkout. 3. Treating the
title alone as the task — read the description. 4. Skipping the spec or its artifacts.
5. Writing `plan/subtasks` by hand — the mirror overwrites it.
