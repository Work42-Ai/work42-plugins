---
name: task42-general
description: work42 task lifecycle — exploration-first specs, roles as skills the Lead follows in one continuous conversation (no subagents), worktree-per-session, and QA as the headline phase. A task is a work42 SESSION of type `task`; its state lives in the session's namespaced storage and its status is DERIVED from the workflow gates. Everything goes through the `work42` CLI.
---

# work42 — Task Lifecycle (v4 — sessions, derived status)

A **task is a work42 session** of type `task`. There is no separate `task42`
CLI and no `tracker.db` — a task is created with `work42 session start`, all of
its state (spec, subtasks, QA, PRs, Jira) lives in the session's **namespaced
key/value storage**, and its **status is DERIVED** by the workflow engine from
that storage (never set by hand). Every operation goes through the `work42`
CLI. Never edit `~/.work42/work42.db` by hand.

## Where task state lives

- **One global `~/.work42/work42.db`** holds every session (its type, name,
  workspace, bound workflow, cached derived stage) plus a `storage` table — the
  namespaced key/value store that IS the task's dynamic content.
- **Workspaces** are repo-grouping folders (the existing project registry);
  `work42 session start --workspace <slug-or-path>` scopes a session to one.
- **Status is derived, not stored by hand.** The session's bound workflow (the
  built-in `task42` workflow: Planning → In-Progress → Testing → Human Review →
  Done) defines each stage's **entry gate** as declarative JSON over the
  session's storage. The engine evaluates the gates against storage and caches
  the highest-ordinal satisfied stage as the session's stage. You advance a task
  by **writing the storage signals a gate reads** (approve the plan, mark
  subtasks done, submit a QA verdict), never by a `transition` command.
- **The chat IS the log.** There is no audit-log command — the session's chat
  transcript records what the agent did. Progress/questions/blockers go in chat.

## Core Rules

1. **Every task starts in the workflow's initial stage (Planning).** Create it
   with a name + workspace; it immediately enters exploration.
2. **In-Progress requires Yan's approval of the Plan.** The spec-phase
   deliverable is the **Plan** — three facets authored together by the
   **Planner** and approved as a single unit: the **Spec** (`plan/spec`), the
   **Subtasks** (`plan/subtasks`), and the **Testing Plan** (`plan/testing`).
   One click of the green **Approve Plan** button writes `plan/approved_at` +
   `plan/approved_by`; the In-Progress gate reads those.
3. **One worktree per session, created at session start.** All subtasks share
   the one worktree. Subtasks never get their own worktrees.
4. **Subtasks are the Lead loading the Worker skill, in the same
   conversation.** No subagents: one agent follows the `task42-worker` skill's
   process once per subtask, sequentially, in the task's own session. Provider-
   neutral (Claude or Codex).
5. **QA is the headline phase.** Following the `task42-qa` skill's process, the
   Lead walks the spec's acceptance criteria using flow42 visual tools + the
   terminal and produces evidence (recordings + transcripts) — not just prose —
   then writes the verdict to `qa/verdict` (+ `qa/report`).
6. **QA PASS advances to Human Review by derivation.** Writing a PASS verdict
   satisfies the Human Review gate; no PR is required for the transition. The
   Lead opens the draft PR after and records it in `github/prs`.
7. **Done is derived too.** There is no manual accept. Before considering a task
   done, the Lead verifies every PR in `github/prs` is merged (widget events or
   `gh pr view`); the workflow's Done gate reflects the completed signals.

## The Plan (spec-phase deliverable)

The initial phase produces one approvable thing: the **Plan**, unifying **Spec +
Subtasks + Testing Plan**, **authored by the Lead following the `task42-planner`
skill's process** (loaded inline, not delegated to a separate agent).

- **Spec** — the technical plan (Context, Goals, Acceptance Criteria, Design,
  Out of Scope, Risks & Edge Cases, Open Questions), written to the `plan/spec`
  storage key. Structurally validated by `SpecValidator` (Work42Core) — a spec
  missing a required H2 section is rejected.
- **Subtasks** — the implementation breakdown, a JSON array at `plan/subtasks`:
  `[{"id":"...","title":"...","description":"...","done":false}]`. Each carries
  a required `description` so a Worker's task is its title + description, with
  the spec for wider context. The subtasks gate counts `done` entries.
- **Testing Plan** — written to `plan/testing`, authored as a spec-time
  **Planner↔QA dialogue**: per AC, QA proposes how to verify it visually and
  what the expected visual output is.

**Plan view + Approve Plan.** A task session lands on a special **Plan
view/tab** pre-composing three tiles — **Spec · Subtasks · Testing Plan**. On it,
the `+ Widget` control is joined by a green **"Approve Plan"** button: one click
is the human approval gate covering the whole Plan and writes `plan/approved_at`
+ `plan/approved_by`. Approving unlocks Planning → In-Progress.

## Roles

**Roles are skills the Lead loads, not separate agents.** One agent (Claude or
Codex) stays in one conversation for the whole task; each role below is a skill
it follows for that phase.

| Role | Responsibility |
|------|---------------|
| **Human (Yan)** | Approves the Plan (Spec + Subtasks + Testing Plan) via the Approve Plan button, shakes the build in Human Review, merges the PR on GitHub |
| **Lead** | The **orchestrating main app agent** — the default mode. Owns the lifecycle: runs planning, carries the Plan to Yan's approval, runs the Worker skill per subtask and the QA skill, triages QA + PR feedback. Doesn't write code or author the Plan except by following the Planner/Worker skills. |
| **Planner** (`task42-planner`) | Loaded by the Lead. Owns deep understanding, edge-case questioning (one at a time), visual validation on the canvas, and authoring the Plan — `plan/spec` + `plan/subtasks` + `plan/testing` (co-authored with QA's perspective). Never writes production code. |
| **Worker** (`task42-worker`) | Loaded by the Lead once per subtask, sequentially. Implements, commits, pushes, marks the subtask `done` in `plan/subtasks`. |
| **QA** (`task42-qa`) | Loaded by the Lead when the task reaches Testing. Tests against the project QA guide + spec, produces an evidence-rich report, writes `qa/verdict` (+ `qa/report`). |

## Task Lifecycle

```
Planning             — Lead loads task42-planner, which authors the Plan
                       (plan/spec + plan/subtasks + plan/testing); Lead seeks
                       Yan's Approve Plan (writes plan/approved_at)
   ↓ (Yan approves the Plan → In-Progress gate satisfied)
In-Progress          — Lead loads task42-worker once per subtask, sequentially,
                       in the session's worktree; marks each done in plan/subtasks
   ↓ (all subtasks done → Testing gate satisfied)
Testing              — Lead loads task42-qa; runs against the QA guide + spec;
                       writes qa/verdict PASS or FAIL
   ↓ PASS (qa/verdict)               ↘ FAIL (1st/2nd)
Human Review                            In-Progress (Lead adds fix subtasks to
   ↓ (Yan accepts + PRs merged)         plan/subtasks, loads task42-worker again)
Done                                  ↘ FAIL (3rd) → Blocked
```

Status is DERIVED at every arrow — you satisfy a gate by writing storage, you do
not run a transition command. Blocked is a side state reached when Yan needs to
intervene.

## Project QA Guide

Each project has a QA guide at `~/.work42/<project>/qa-guide.md` (Yan authors it
on setup). It tells the QA skill how to *actually test this product* — which
surfaces exist (UI/CLI/HTTP API), test credentials, fragile areas. *How to run*
the product for each test is named in the task's **Testing Plan** (`plan/testing`):
each test names the `launch.json` config to launch via `work42 debug start
<config>` (confirm with `work42 debug configs`), authored via `flow42-qa-author`.

## CLI Reference

Session id is discovered from `WORK42_SESSION_ID` (env, primary) or `--session`;
inside a task session you can omit it. Storage values must be canonical JSON.

### Creating & inspecting

| Command | Purpose |
|---------|---------|
| `work42 session start --type task --workspace <slug\|path> --name "..."` | Create a NEW task session (starts in the workflow's initial stage). `--storage ns/key=json` (repeatable) pre-seeds storage at creation; `--branch repo=branch` (repeatable) starts a repo from a specific branch. |
| `work42 session types` | List the built-in + custom session types (each names its workflow). |
| `work42 sessions list [--json] [--since <ts>]` | List sessions (with activity filter). |

### Reading & writing task state (storage)

| Command | Purpose |
|---------|---------|
| `work42 storage set [--session <id>] <ns>/<key> <json>` | Write a JSON value (upsert; idempotent). Writing a gate signal re-derives the stage. |
| `work42 storage get [--session <id>] <ns>/<key>` | Read a value. |
| `work42 storage list [--session <id>] [<namespace>]` | List entries (all, or one namespace). |
| `work42 storage delete [--session <id>] <ns>/<key>` | Remove an entry. |

**Storage namespaces / keys used by the task lifecycle:**

| Key | Meaning |
|-----|---------|
| `plan/spec` | The spec markdown (technical plan). Validated by `SpecValidator`. |
| `plan/subtasks` | JSON array `[{id,title,description,done}]` — the implementation breakdown. The Testing/all-done gates count `done`. |
| `plan/testing` | The Testing Plan (per-AC verification). |
| `plan/approved_at` / `plan/approved_by` | Written by the **Approve Plan** button — the human approval gate for In-Progress. There is **no** approve command. |
| `qa/verdict` | `PASS` / `FAIL` — satisfies (or fails) the Human Review gate. |
| `qa/report` | The QA report markdown + evidence pointers. |
| `jira/url` | A Jira issue URL — the jira widget renders it. Attach: `work42 storage set jira/url '"<url>"'`. |
| `github/prs` | JSON array of `{url,status,merged_at}` — the github widget renders one tab per PR and updates status via its watch loop. |

### The `jira/*` namespace

A task carries a Jira issue URL in `jira/url`; the jira prebuilt widget reads it
and renders the issue with persistent login. Attaching is agent-only:
`work42 storage set jira/url '"<url>"'` (value is a JSON string). See the
work42-plugins sibling repo's `jira/SKILL.md`.

### The `github/*` namespace and PR tracking

PR URLs live in `github/prs` as a JSON array of `{url, status, merged_at}`. The
github prebuilt widget renders one browser tab per entry; its background poll
updates `status`/`merged_at` and delivers PR activity as `[system event]`s.

```bash
# Attach a PR (after opening the draft PR in Human Review)
work42 storage set github/prs \
  '[{"url":"https://github.com/owner/repo/pull/42","status":"open","merged_at":null}]'

# Check merge discipline before considering the task done
work42 storage get github/prs | jq '[.[] | select(.status != "merged")] | length'   # must be 0
```

See the work42-plugins sibling repo's `github/SKILL.md`.

### Human-only gate (no CLI surface)

| Gate | How it happens |
|------|----------------|
| **Plan approval** (unlocks Planning → In-Progress) | Yan clicks the green **Approve Plan** button on the task session's Plan view — writes `plan/approved_at` + `plan/approved_by`. There is intentionally no CLI approve; only the human approves. If an agent reaches for one, that's a bug — ask Yan to approve in the app. |

## Logging

There is no log command — **the chat transcript is the record.** State progress,
blockers, triage decisions, role-skill transitions, and QA results in chat.
Silence is the worst outcome.

## Rules for All Agents

1. **Never edit work42.db directly.** Use `work42` commands only.
2. **Work in the session worktree.** Never in the main repo checkout.
3. **Commit and push before marking a subtask `done`** (flip its `done:true` in
   `plan/subtasks`). The Testing gate blocks on all subtasks done.
4. **Never hand-set status.** Status derives — write the gate's storage signal.
5. **Before considering a task done, verify all `github/prs` are merged.**
6. **Every fix is its own subtask — never an ad-hoc inline edit.** Any fix
   discovered at any point becomes a new entry in `plan/subtasks`, implemented
   through the Worker skill.
7. **Drive phase transitions by writing storage; don't pause for Yan to
   greenlight them.** The only human checkpoints are Plan approval (Approve
   Plan button) and build acceptance (Human Review).
