---
name: task42-worker
description: Worker skill — followed by the Lead (same agent, same conversation, no subagent) to implement exactly ONE subtask in the shared task-session worktree. Implement, commit, push, mark the subtask done in plan/subtasks. Stay in lane.
---

# Worker Workflow (v4 — sessions, no subagent)

**You are the Lead, now following the Worker skill's instructions** for
**exactly one subtask** — not a separate agent. Loading this skill is how the
Lead narrows focus to implementation work; when the subtask is done, you go
back to following the `task42-lead` skill's process for whatever comes next
(the next subtask, or Testing once they're all done). You do not poll for work,
you do not pick the next subtask yourself while this skill is active, and this
skill's scope is exactly one subtask at a time — load it again for the next one.

A task is a **work42 session** of type `task`; its subtasks are a JSON array in
the session's `plan/subtasks` storage. See the **`task42-general`** skill for
the storage model and the full CLI reference.

## What You Need Before Starting

Before loading this skill for a subtask, the Lead process should already have
on hand:
- The **subtask id** (an entry's `id` in `plan/subtasks`).
- The **task session id** (the parent).
- The **worktree path** (`cd` here first).
- The **branch name** (already checked out).

**Your task is the subtask's title + description.** That pair fully carries
*what to build* — the Planner authored the description to stand on its own. The
spec (`plan/spec`) is your **wider context**: read it to understand the task,
the design, and how your slice fits — but the title + description is the actual
unit of work you implement. Read your subtask entry from the session storage:
`work42 storage get plan/subtasks` (find your `id`), and the spec via
`work42 storage get plan/spec`.

Anything not in the dispatch you should *not* assume.

## Inline Artifact References in the Spec — CHECK THEM BEFORE IMPLEMENTING

> **Mandatory.** When you read the spec, scan it for `[[artifact:<id>]]` tokens
> — they mark confirmed visual decisions (diagrams, mockups) the Planner built
> and Yan approved. For **every** one, view it BEFORE writing code:
> `work42 artifact url <id>` (or `work42 artifact status <id>`), open it in the
> `.artifacts` gallery, and match your implementation to it. If an artifact is
> missing (empty status, server down, unknown id), say so in chat and pause for
> Yan — never implement a referenced visual decision from guesswork. The
> `[[artifact:id]]` grammar is documented in the **`work42-artifact`** skill.

## Your Workflow

1. **`cd` to the worktree path.** Verify you're not in the main repo checkout.
   `work42 storage` auto-scopes to the current session via `WORK42_SESSION_ID`.
2. **Read your subtask entry, then the spec.** Your task is the subtask
   **title + description** from `plan/subtasks` (`work42 storage get
   plan/subtasks`). Then read the whole spec (`work42 storage get plan/spec`)
   for the design context + acceptance criteria. **Scan the spec for
   `[[artifact:<id>]]` references and view each one** — see above.
3. **Implement.** Stay in your lane. Do not touch files outside what your
   subtask requires. If the work overlaps another subtask's territory, say so
   in chat and stop rather than guess.
4. **Run local checks.** Whatever tests/lints the project uses. The project QA
   guide at `~/.work42/<slug>/qa-guide.md` describes how to exercise the build.
5. **`git add` + `git commit`.** Reference your subtask id in the message.
6. **`git push`** to the remote branch (already checked out for this subtask).
7. **Mark your subtask `done`** in `plan/subtasks`: read the array, set your
   entry's `"done": true`, and write the whole array back with
   `work42 storage set plan/subtasks '<updated JSON>'`. The all-subtasks-done
   gate advances the task to Testing by derivation — you do not run a
   transition command.
8. **State final status in chat** ("<subtask-id> done. <one-line summary>.
   Pushed <N> commits.") — the chat transcript is the record; there is no log
   command.
9. **Return to the `task42-lead` skill's process.** This subtask is finished —
   load the Worker skill again for the next one, or move on to Testing if that
   was the last one.

## Commands

| Command | When |
|---------|------|
| `work42 storage get plan/subtasks` | Read the subtask array; find your entry by `id` |
| `work42 storage get plan/spec` | Read the spec for wider context |
| `work42 storage set plan/subtasks '<updated JSON>'` | Mark your subtask `done:true` (write the whole array back) — the Testing gate reads this |
| `work42 storage get jira/url` | Read the Jira issue URL attached to the task |
| `work42 artifact url <id>` / `work42 artifact status <id>` | View an artifact referenced in the spec |

Storage auto-scopes to the current session; pass `--session <id>` only to target
another session.

## Jira & PR context on a task

The `jira/*` and `github/*` storage namespaces are documented authoritatively in
the **`task42-general`** skill. Two things matter here: (1) if your dispatch
references a Jira issue, read it via `work42 storage get jira/url`; (2) **push
your branch promptly** — the Lead opens/records the draft PR in `github/prs`, and
the github widget then delivers PR activity as `[system event]`s. If you see a
`[system event]` naming a **failing CI check** while a PR is live, fix it and
re-push without waiting to be asked.

## What to Say in Chat

- Starting: "Starting <subtask-id>: Build login form. Reading spec."
- Real progress (not "thinking..."): "Implemented the form component; wiring up
  the submit handler now."
- Blockers: "Stuck — the auth route expects a token shape the spec doesn't
  describe. @yan need clarification."
- Errors: "Tests failing on `auth/login.test.ts` — stack: ...".
- Finishing: "<subtask-id> done. Pushed 2 commits."

Silence is the worst outcome. The chat transcript is the record — narrate even
when things go sideways.

## Key Rules

- **One subtask per pass through this skill.** Finish, return to the
  `task42-lead` process, then load this skill again for the next one.
- **Always work in the worktree.** Verify with `pwd` if uncertain. Never edit
  files in the main repo checkout.
- **Check all `[[artifact:<id>]]` references in the spec before implementing.**
  View each via `work42 artifact url <id>`; your implementation must match what
  the artifact shows. Missing artifact = say so and pause for Yan.
- **Commit AND push before marking done.** The Testing gate blocks on
  uncommitted or unpushed work. Marking done without pushing stalls the task.
- **All subtasks share one branch.** Check the session/chat history before
  editing a file another subtask's pass already touched.
- **Never hand-set the task's status.** It derives — marking your subtask
  `done` in `plan/subtasks` is the only signal you write.
- **Mark only the subtask this pass is scoped to `done`.** Don't touch another
  entry.
- **Every fix you discover is its own subtask — never an ad-hoc inline edit.**
  If mid-build you find a bug outside this subtask's scope, do NOT silently fix
  it. Surface it so the Lead process adds a new entry to `plan/subtasks`
  (implemented through a later Worker pass). Route the fix in; don't swallow it.
- **If you're blocked, say so in chat and stop.** Don't work around an
  ambiguity — surface it to Yan and pause.

## Common Mistakes

1. **`git commit` without `git push`** — the worktree looks clean but the remote
   doesn't have your work. Testing gate will reject.
2. **Working in the main repo checkout** — commits land on the wrong branch.
3. **Marking done before finishing** — only after commit + push, and only when
   your implementation actually meets the subtask description.
4. **Treating the subtask title alone as the task** — the **description**
   carries the real spec of your slice; read it, not just the title.
5. **Skipping the spec** — the title + description is what you build, but read
   the whole spec for the wider context.
6. **Skipping `[[artifact:<id>]]` references** — always view them via
   `work42 artifact url <id>` before writing code.
