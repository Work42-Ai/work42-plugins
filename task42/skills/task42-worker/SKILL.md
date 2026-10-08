---
name: task42-worker
description: Worker skill — followed by the Lead (same agent, same conversation, no subagent) to implement exactly ONE subtask in the shared task-session worktree. Implement, commit, push, mark the subtask done in plan/subtasks. Stay in lane.
---

# Worker (task42)

You are the Lead, now following the Worker skill for **exactly one subtask**. When it's done you return to `task42-lead`; load this skill again for the next one. See `task42-general` for the storage model and CLI.

**Your task is the subtask's title and description**, which the Planner wrote to stand alone. The spec is wider context. You need the subtask `id` (an entry in `work42 storage get plan/subtasks`), the worktree (`cd` there; never edit the main checkout) and the branch, already checked out.

## Workflow

1. **Read the subtask entry, then the whole spec** (`work42 storage get plan/subtasks`, `work42 storage get plan/spec`) for the design and acceptance criteria.
2. **View every `[[artifact:<id>]]` in the spec before writing code.** They are confirmed visual decisions: `work42 artifact url <id>` or `status <id>`; your work must match. A missing artifact (empty status, server down, unknown id): say so in chat and pause for Yan, never guess a visual decision.
3. **Implement, in your lane.** Touch only what the subtask needs. If it overlaps another subtask, say so and stop. A bug outside your scope is not yours to fix inline: surface it so the Lead adds a new subtask.
4. **Run the local checks** (the QA guide at `~/.work42/<slug>/qa-guide.md` says how to exercise the build).
5. **`git add`, `git commit` (name the subtask id), `git push`** to the task branch.
6. **Mark the subtask done**, only after the push: read `plan/subtasks`, set your entry's `"done": true`, write the whole array back with `work42 storage set plan/subtasks '<updated JSON>'`. Don't touch another entry, and don't hand-set the task's stage: when every entry is done the session offers Testing and the Lead runs it.
7. **Say it in chat:** "`<id>` done. <one line>. Pushed <N> commits." Then return to the Lead.

## Rules

- One subtask per pass.
- All subtasks share one branch: check the chat before touching a file another pass changed.
- Push promptly: the Lead opens the draft PR later (and records it in `github/prs`), and a failing CI check on a live PR is yours to fix and re-push.
- **Blocked or unsure?** Say so in chat with `@yan` and what you need, then stop. Never work around an ambiguity.
- Narrate: starting, real progress, blockers, errors with the failing output, finishing. Silence is the worst outcome.
