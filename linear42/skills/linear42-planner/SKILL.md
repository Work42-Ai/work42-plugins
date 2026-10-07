---
name: linear42-planner
description: Planner skill — followed by the Lead (same agent, same conversation, no subagent) to plan a linear42 task. Investigate the problem, ask the user clarifying/edge-case questions ONE at a time, build confirmed artifacts to lock visual decisions, then author the Plan IN LINEAR — the spec and testing plan as Linear documents and the subtasks as Linear sub-issues. Plan approval is a hard gate — never write production code.
---

# Planner Workflow (Linear-native)

**You are the Lead, now following the Planner skill.** Your whole job while it is active
is to turn a fuzzy idea into a concrete, approvable Plan, authored in Linear: a **spec**
(a Linear document), **sub-issues** (each with a required description), and — when
warranted — a **testing plan** (a second Linear document). Deep understanding and good
questions are the expensive, high-leverage work; get them right and implementation is easy.

A task is a **work42 session** bound to a Linear issue; see **`linear42-general`** for the
storage model, config and `linear` CLI. **You never write production code, scaffold a
project, or take any implementation action while this skill is active.** Implementation
happens later via `linear42-worker`, and only *after* a human approves the Plan.

## What you need before starting

- The session's worktree (`cd` there first) and branch.
- The bound issue, if any: `work42 storage get linear/issue_ref`. If it is set, read it:
  `linear issue view <KEY>`. If the session is **unbound**, you will create the issue once
  you understand the task (see *Bind or create the issue*).
- Config: `jq . ~/.config/linear42/config.json` (workspace, `default_team`). If it is
  missing or incomplete, stop and ask Yan — never guess a team.

## The thinking process

Planning is a dialogue, not a one-shot dump. **Do not write the spec** until you understand
the problem and Yan has answered your questions.

### 1. Investigate first

Walk the codebase from the worktree: existing utilities, conventions, prior art. Read the
Linear issue and its comments if bound. Come to the conversation informed so your
questions are sharp. "Simple" tasks are where unexamined assumptions waste the most work.

### 2. Ask clarifying + edge-case questions — ONE at a time

- **One question at a time**, multiple-choice (2–4 options) when you can.
- Hunt edge cases: empty states, error paths, concurrency, back-compat, failure behaviour.
- Ask in chat, prefixed `@yan [QUESTION] …`. Resolve every open question before asking
  for approval.

### 3. Build confirmed artifacts — visual decisions AND a per-item explainer (required)

Before you lock the spec, render artifacts and ask Yan to confirm them: a **visual-decision**
artifact for anything that looks like something (mermaid diagram or HTML/SVG mockup) and a
**per-item explainer** for every plan item showing how you'll solve it (problem with real
file:line, approach, diagram-first — build these with `work42-artifact-explainer`). Drive
them with the **`work42-artifact`** skill (`work42 artifact set <id>`, then `status`).

- Artifacts are loopback-only — vendor JS locally; never fetch from the network.
- Mermaid node labels must be safe: no colon, no `[[artifact:…]]` token, no trailing prose.
- Create the artifact FIRST, check `status` shows no errors, then reference it in chat with
  `[[artifact:<id>]]` alone on its own line and ask "Does this match what you have in mind?"
- Confirmed artifacts are locked decisions: reference them from the spec's Design section.

### 4. Bind or create the issue

If `linear/issue_ref` is unset, create the issue in the configured team and bind it:

```bash
TEAM="$(jq -r .default_team ~/.config/linear42/config.json)"
linear issue create --team "$TEAM" --title "<task title>" --description-file - <<'MD'
<one-paragraph summary of the task>
MD
# the command prints "<KEY>: <title>" and the URL — take the key from the output
work42 storage set linear/issue_ref '"<KEY>"'
```

Within one poll the sync agent resolves it into `linear/issue`. Wait for that (poll
`work42 storage get linear/issue`) before creating documents, so the issue exists for sure.

### 5. Author the Plan in Linear

Only once the problem is understood and the visuals are confirmed.

**Planning forbids editing files** — pass content on stdin with a quoted heredoc. Do not
create temp files.

**Spec → a Linear document.** Follow `./spec-template.md` (copy its headings: Context,
Goals, Acceptance Criteria, Design, Out of Scope, Risks & Edge Cases, Open Questions). Write
acceptance criteria in EARS form ("WHEN <trigger>, THE SYSTEM SHALL <response>", numbered
AC1, AC2…). Reference confirmed artifacts in the Design section with `[[artifact:<id>]]`
tokens, one per line, so Workers view each before implementing.

```bash
linear document create --issue <KEY> --title "Spec" --content-file - <<'MD'
# <task>: <one-line title>
## Context
…
MD
```

The command prints the new document's URL; the slug is the last path segment
(`https://linear.app/<ws>/document/<slug>`). **Verify before recording it:**
`linear document view <slug> --json`. Then record it:

```bash
work42 storage set linear/spec_doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
```

**Subtasks → sub-issues.** One per subtask, each with a REQUIRED description a Worker loaded
cold can execute: exact file paths, the interface it consumes/produces, concrete behaviour.

```bash
linear issue create --team "$TEAM" --parent <KEY> --title "<exact title>" --description-file - <<'MD'
<files, interface, behaviour — concrete>
MD
```

Create them in implementation order. **Never write `plan/subtasks`** — the sync agent mirrors
the sub-issues into it within a poll. Check the mirror landed: `work42 storage get plan/subtasks`.

**NO PLACEHOLDERS.** Non-negotiable: no "TBD", "TODO", "implement later", "handle errors
appropriately". Name exact paths, signatures and behaviour; keep names consistent across
the spec and every sub-issue. A placeholder is an open question for Yan, not a hole in the Plan.

**Testing plan → a second document, when warranted.** Pure docs/copy, config-only and
trivial self-evident changes are low-QA-value — ask Yan whether to author one or skip QA.
New user-facing behaviour, state-machine changes, non-trivial CLI behaviour and
cross-cutting changes are high-QA-value: author it, consulting QA's perspective
(`linear42-qa`). A verification-only plan (no flows) is valid. Per reusable flow, use the
four-field entry (`flow`, `variant`, `config`, `covers`) and select/record flows with
`linear42-qa-author`.

```bash
linear document create --issue <KEY> --title "Testing plan" --content-file - <<'MD'
…per-AC verification…
MD
work42 storage set linear/testing_doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
```

There is no separate testing-plan approval — one Approve Plan click covers spec,
sub-issues and testing plan.

### 6. Approval is a HARD GATE

Do **not** proceed until Yan approves: the green **Approve Plan** button on the Spec tab
(enabled once the spec doc and at least one sub-issue exist), **or** moving the issue into a
started state in Linear while the session is in Planning. Both write `plan/approved_at`.
**There is no approve command and you never write it.** When it holds, the session gets
`In-Progress is now available — run work42 transition "In-Progress"`; run it then — not
before. You do not start implementation or load the Worker skill until then.

**If Yan asks for edits after approval:** go back to Planning if needed
(`work42 transition "Planning"`), update the documents / sub-issues, and **clear the approval
yourself** — nothing does it automatically:

```bash
work42 storage delete plan/approved_at
work42 storage delete plan/approved_by
work42 storage delete linear/approval_stamped
```

(Planning is the only stage that allows `linear document update` and these deletes.) Then
re-request approval.

## Commands

| Command | When |
|---------|------|
| `linear issue view <KEY>` | Read the bound issue |
| `linear issue create --team <T> [--parent <KEY>] --title … --description-file -` | Create the issue / a sub-issue |
| `linear document create --issue <KEY> --title … --content-file -` | Author the spec / testing plan |
| `linear document view <slug> --json` · `update <slug> --content-file -` | Verify / revise a document |
| `work42 storage set linear/issue_ref` · `linear/spec_doc` · `linear/testing_doc` | Record what you created |
| `work42 storage get plan/subtasks` | Confirm the sub-issue mirror |
| `work42 artifact set/status/path <id>` | Render and validate artifacts |
| `work42 transition "In-Progress"` | After the "now available" message — never before |

## Key rules

- **You never write production code.** Your output is the Plan.
- **One question at a time, multiple-choice preferred.**
- **Confirmed artifacts BEFORE locking the spec**; every plan item has an explainer; all
  referenced from the spec's Design section.
- **No placeholders**; every sub-issue has a description.
- **Never write `plan/subtasks` or `plan/approved_at`.**
- **Resolve every Open Question before asking for approval** — the spec's Open Questions
  section is empty (or "None") when you ask.
- **Narrate every meaningful step in chat.**
