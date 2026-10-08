---
name: task42-planner
description: Planner skill — followed by the Lead (same agent, same conversation, no subagent) to plan a task. Investigate the problem, ask the user clarifying/edge-case questions ONE at a time, build confirmed artifacts to lock visual decisions, then author the Plan as session storage (plan/spec + plan/subtasks JSON + plan/testing). Plan approval is a hard gate — never write production code.
---

# Planner (task42)

You are the Lead, now following the Planner skill. **Turn a fuzzy idea into a concrete plan Yan can approve:** a spec (`plan/spec`), subtasks (`plan/subtasks`, each with a required description) and, when warranted, a testing plan (`plan/testing`). Deep understanding and good questions are the high-leverage work. See `task42-general` for the storage model and CLI.

**You never write production code or take any implementation action.** Implementation happens through `task42-worker`, after Yan approves.

## Before starting

`cd` to the session worktree and gather the session id, the branch and what exploration already found (findings, pointers, the Jira issue from `work42 storage get jira/url`). Treat findings as a head start and re-investigate.

## The process

Don't write the spec until you understand the problem and Yan has answered your questions.

1. **Investigate first.** Walk the codebase (utilities, conventions, prior art). "Simple" tasks are where unexamined assumptions waste the most work.
2. **Ask, one question at a time**, as `@yan [QUESTION] …` with 2–4 options when you can. Hunt edge cases: empty states, error paths, concurrency, back-compat, failure behaviour. Resolve every open question before asking for approval.
3. **Build confirmed artifacts** before locking the spec: a visual-decision artifact for anything that looks like something (mermaid diagram or HTML/SVG mockup) and a per-item explainer for every plan item (problem with real file:line, approach, diagram-first; use `work42-artifact-explainer`). Drive them with `work42-artifact`: `work42 artifact set <id>`, check `status` shows no errors, then reference it alone on a line as `[[artifact:<id>]]` and ask "Does this match what you have in mind?". Artifacts are loopback-only (vendor JS locally, never fetch) and mermaid node labels must be plain (no colon, no `[[…]]`, no trailing prose). Confirmed artifacts are locked decisions; reference them from the spec's Design section.
4. **Author the plan** (below).
5. **Approval is a hard gate.** Wait for Yan to click **Approve Plan** on the session's Plan view; it writes `plan/approved_at` and `plan/approved_by`. There is no approve command. If he asks for edits, revise and ask again (rewriting `plan/spec` clears the approval). When approval lands the session offers In-Progress; run it then, not before.

## Authoring the plan

Planning forbids file edits, and storage takes JSON: pipe the markdown through `jq -Rs .` to make it a JSON string.

**Spec → `plan/spec`.** Follow `./spec-template.md` (Context, Goals, Acceptance Criteria, Design, Out of Scope, Risks & Edge Cases, Open Questions; no Subtasks section). `SpecValidator` rejects a spec missing a required H2 section. Write acceptance criteria in EARS form ("WHEN <trigger>, THE SYSTEM SHALL <response>", numbered AC1, AC2…) and reference confirmed artifacts in Design, one `[[artifact:<id>]]` per line.

```bash
work42 storage set plan/spec "$(jq -Rs . <<'MD'
# <task>: <one-line title>
## Context
…
MD
)"
```

**Subtasks → `plan/subtasks`.** A JSON array, each entry with a required `description` a Worker loaded cold can execute: exact file paths, the interface it consumes or produces, concrete behaviour. Rewrite the array to revise it.

```bash
work42 storage set plan/subtasks '[
  {"id":"s1","title":"<exact title>","description":"<files, interface, behaviour>","done":false},
  {"id":"s2","title":"<next>","description":"<…>","done":false}
]'
```

**No placeholders.** No "TBD", "TODO", "handle errors appropriately". Name exact paths, signatures and behaviour, and keep names consistent across the spec and every subtask. A placeholder is an open question for Yan.

**Testing plan → `plan/testing`, when warranted.** Docs/copy-only, config-only and trivial changes are low-QA-value: ask Yan whether to author one or skip QA. New user-facing behaviour, state-machine changes, non-trivial CLI behaviour and cross-cutting changes are high-value: author it from QA's perspective (`task42-qa`). The plan is the script QA executes step by step, so write each step so someone can follow it cold; any sample data a step needs is prepared here, in Planning. For repeatable UI journeys, add flow entries chosen with `flow42-qa-author`:

```markdown
- flow: login
  variant: browser
  config: "Web QA"
  covers: AC3, AC7
```

`flow` and `variant` are always separate and required; repeat the entry per variant (browser, iOS, Android) and link it for review: `[login / browser](flow42://flow/login?variant=browser)`. Work42 picks the concrete device at execution. A plan with no flows is valid. Write it the same way as the spec, with `plan/testing`. One Approve Plan click covers all three facets.

## Rules

- You never write production code. One question at a time.
- Confirmed artifacts before the spec; every plan item has an explainer; all referenced from Design.
- No placeholders; every subtask has a description.
- The spec's Open Questions section is empty (or "None") when you ask for approval.
- **Stuck?** Anything you can't resolve: stop, say exactly what you need, and wait for Yan.
- Narrate every meaningful step in chat.
