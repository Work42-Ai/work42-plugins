---
name: linear42-worker
description: Worker skill — followed by the Lead (same agent, same conversation, no subagent) to implement exactly ONE Linear sub-issue in the shared task-session worktree. Read the sub-issue and the spec, implement, run checks, commit, push, then complete the sub-issue in Linear. Stay in lane.
---

# Worker (linear42)

You are the Lead, now following the Worker skill for **exactly one sub-issue**. When it's done you return to `linear42-lead`; load this skill again for the next one. See `linear42-general` for the storage model and the `linear` CLI.

**Your task is the sub-issue's title and description**, which the Planner wrote to stand alone. The spec is wider context. You need the sub-issue key (an `id` in `work42 storage get plan/subtasks`), the worktree (`cd` there; never edit the main checkout) and the branch, already checked out.

## Workflow

1. **Read the sub-issue, then the spec.** `linear issue view <SUBKEY>`, then
   `linear document view "$(work42 storage get linear/issues/<KEY>/spec_doc | jq -r .slug)" --raw` (`<KEY>` is the parent issue; `work42 storage get linear/issue_keys` lists them).
2. **View every `[[artifact:<id>]]` in the spec before writing code.** They are confirmed visual decisions: `work42 artifact url <id>` or `status <id>`; your work must match. A missing artifact: say so in chat and pause for Yan, never guess a visual decision.
3. **Implement, in your lane.** Touch only what the sub-issue needs. If it overlaps another sub-issue, say so and stop. A bug outside your scope is not yours to fix inline: surface it so the Lead creates a new sub-issue.
4. **Run the local checks** (the QA guide at `~/.work42/<slug>/qa-guide.md` says how to exercise the build).
5. **`git add`, `git commit` (name the sub-issue key), `git push`** to the task branch.
6. **Complete the sub-issue in Linear**, only after the push: `linear issue update <SUBKEY> --state completed`. Within one poll the sync agent mirrors it into `plan/subtasks`; never write that yourself, and never cancel a sub-issue to finish it (canceled doesn't count).
7. **Say it in chat:** "`<SUBKEY>` done. <one line>. Pushed <N> commits." Then return to the Lead.

When the last sub-issue is mirrored the session offers Testing and the Lead runs it.

## Rules

- One sub-issue per pass; complete only your own.
- All sub-issues share one branch: check the chat before touching a file another pass changed.
- Push promptly: the Lead opens the draft PR later, and a failing CI check on a live PR is yours to fix and re-push.
- **Blocked or unsure?** Say so in chat with `@yan` and what you need, then stop. Never work around an ambiguity.
- Narrate: starting, real progress, blockers, errors with the failing output, finishing. Silence is the worst outcome.
