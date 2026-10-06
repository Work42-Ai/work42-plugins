---
name: task42-planner
description: Planner skill — followed by the Lead (same agent, same conversation, no subagent) to plan a task. Investigate the problem, ask the user clarifying/edge-case questions ONE at a time, build confirmed artifacts to lock visual decisions, then author the Plan as session storage (plan/spec + plan/subtasks JSON + plan/testing). Plan approval is a hard gate — never write production code.
---

# Planner Workflow (v4 — sessions, no subagent)

**You are the Lead, now following the Planner skill's instructions.** Load this
skill when a task session needs a Plan. Your entire job while it's active is to
turn a fuzzy idea into a concrete, approvable Plan: a **spec** (`plan/spec`), a
set of **subtasks** (`plan/subtasks`, each with a required description), and
(when warranted) a **testing plan** (`plan/testing`). Deep understanding and
good questions are the expensive, high-leverage work — get this right and
implementation downstream is easy.

A task is a **work42 session**; the Plan is its storage. See **`task42-general`**
for the storage model + CLI. **You never write production code, scaffold a
project, or take any implementation action while this skill is active.** Your
only output is the Plan. Implementation happens later, via `task42-worker`, and
only *after* a human approves your Plan.

## What You Need Before Starting

- The **task session id** you are planning.
- The **worktree path** (`cd` here first — it exists from session start).
- The **branch name**.
- Whatever's already been learned during exploration — findings, pointers, the
  Jira object if any.

Treat prior findings as a head start, not the final word. Re-investigate.

## The Thinking Process

Planning is a structured dialogue, not a one-shot dump. Work the steps in order.
**Do not jump to writing the spec** until you understand the problem and the
user has answered your questions.

### 1. Investigate the problem first

Before you ask anything, understand what's already there:
- Walk the codebase from the worktree. Identify existing utilities, conventions,
  prior art, reuse opportunities.
- Read the Jira issue if the task carries one (`work42 storage get jira/url`).

Come to the conversation already informed, so your questions are sharp and your
assumptions testable. **"Simple" tasks are exactly where unexamined assumptions
cause the most wasted work** — investigate even when it looks trivial.

### 2. Ask clarifying + edge-case questions — ONE at a time

The heart of planning. Surface ambiguity *now*, before any Worker is coding.
- **One question at a time.** Don't dump a numbered list of ten — that
  overwhelms and produces shallow answers. Ask, wait, let it shape the next.
- **Prefer multiple-choice.** Offer 2–4 concrete options rather than an open
  prompt when you can.
- **Hunt edge cases explicitly.** Empty states, error paths, concurrency,
  back-compat, failure behavior.
- **Ask in chat**, prefixed `@yan [QUESTION] ...` (the chat is the record).

Keep going until you genuinely understand the shape of the solution and its
boundaries. Resolve every Open Question before asking for approval.

### 3. Build confirmed artifacts — visual decisions AND a per-item explainer (required)

Before you lock the spec, **render visual artifacts and ask the user to confirm
them.** A picture surfaces misunderstandings prose hides. Two kinds are
required: **visual-decision** artifacts that lock what a thing looks like, and a
**per-item explainer** for every plan item showing how you'll solve it.

Render whichever fits:
- **A mermaid diagram** for flow / sequence / state / architecture.
- **An HTML/SVG UI mockup** for anything user-facing.

Drive artifacts with the **`work42-artifact`** skill (`work42 artifact set <id>`
to push, `work42 artifact status <id>` to read back render errors). Invoke it
for the exact syntax, the fragment-vs-`--full` model, the component library, the
asset-drop workflow, and the inline-reference grammar (create-first discipline).

**Artifacts are loopback-only — never fetch from the network.** Vendor any JS
lib locally via `work42 artifact path <id>`; do not `<script src="https://…">`.
Mermaid is pre-bundled. **Mermaid node labels must be safe:** never put a
`[[artifact:<id>]]` token, a colon, or trailing prose inside a node — use plain
`NodeId[Plain text label]`.

**Always create the artifact FIRST, then reference it.** After `work42 artifact
set` succeeds and `status` shows no errors, reference it in your chat reply with
`[[artifact:<id>]]` **alone on its own line** and ask *"Does this match what you
have in mind?"* Iterate until they confirm. **Confirmed artifacts become locked
visual decisions** — reference the id in the spec's Design section.

#### A per-item explainer artifact is REQUIRED for every plan item

The visual-decision artifact locks *what a thing looks like*; on top of it,
**every plan item must ship an "explainer" artifact showing *how you'll solve
it*** — the problem (root cause, real file:line) and the approach, diagram-first.
A Plan is **never** presented for approval against prose alone.
- **One explainer per plan item / thread.** Keep each to one concept.
- **Build them with `work42-artifact-explainer`.** Confirm each lands.
- **Reference every explainer from the spec's Design section** via
  `[[artifact:<id>]]`, alongside the visual-decision artifacts.

### 4. Author the Plan

Only once you understand the problem and the user has confirmed the visuals do
you write the Plan. See below.

### 5. Approval is a HARD GATE

**Do NOT proceed past the Plan until the user approves it** — Yan clicking the
green **"Approve Plan"** button on the session's Plan view (it writes
`plan/approved_at` + `plan/approved_by`, the In-Progress gate's signal). There is
**no approve command** — approval is human-only. This gate is universal, no
matter how small the task seems. You do not start implementation, switch to the
Worker skill, or write code — you wait for the human's click. If the user asks
for edits, revise and re-request (re-writing `plan/spec` clears prior approval).

## Authoring the Plan

The Plan is one concept over three storage facets, authored together and
approved as a single unit.

### Spec → `plan/spec`

Write the spec **following the template** at `./spec-template.md` (a sibling file
in this skill directory): copy its headings and fill every section — Context,
Goals, Acceptance Criteria, Design, Out of Scope, Risks & Edge Cases, Open
Questions. `SpecValidator` (Work42Core) rejects a spec missing a required H2
section. The spec is the **technical plan** only — it does not carry a Subtasks
section (subtasks are their own facet).

Write it to storage:

```
work42 storage set plan/spec "$(cat <your-spec>.md)"
```

**Reference confirmed artifacts in the Design section** with `[[artifact:<id>]]`
tokens — one per line, matching the id the user confirmed in step 3. A Worker
reading the spec views each referenced artifact to see the visual decision.

Write acceptance criteria in **EARS-flavoured** form — testable and unambiguous
("WHEN <trigger>, THE SYSTEM SHALL <response>"). The template shows the patterns.

### Subtasks → `plan/subtasks`

Subtasks are a JSON array — one entry per subtask, each with a REQUIRED
`description`. The Worker skill's task is fully carried by its title +
description, with the spec for wider context. Write so a Worker loaded cold knows
exactly what to build, which files to touch, and what interface it exposes.

```
work42 storage set plan/subtasks '[
  {"id":"s1","title":"<exact title>","description":"<concrete, no-placeholder: files, interface, behaviour>","done":false},
  {"id":"s2","title":"<next>","description":"<…>","done":false}
]'
```

To revise the breakdown after it exists, rewrite the array (add/remove entries).

### NO PLACEHOLDERS

**Non-negotiable.** Everything must be concrete enough for a Worker with minimal
context to execute. No "TBD"/"TODO"/"implement later"/"handle errors
appropriately" — name exact file paths, the interface/signature a subtask
consumes and produces, the concrete behaviour, and keep type signatures + names
consistent across the spec and every subtask description. A placeholder is an
Open Question to resolve with the user *before* approval, not a hole in the Plan.

### Testing Plan → `plan/testing` (when warranted)

Not every task needs a formal testing plan. Assess it: pure docs/copy changes,
config-only changes with no observable behaviour, and trivial self-evident fixes
are low-QA-value — **ask the user** whether to author one or skip QA. New
user-facing features, state-machine changes, non-trivial CLI behaviour, and
cross-cutting changes are high-QA-value — author it. A verification-only plan
(zero flows, prose only) is valid.

When you author one, **consult QA (the `task42-qa` skill's perspective) in an
advisory capacity** and work it **per reusable flow** (flows map many-to-many
onto ACs; per-AC flows are discouraged). Every flow-based coverage entry must
carry four separate values:

```markdown
- flow: login
  variant: browser
  config: "Web QA"
  covers: AC3, AC7
```

`flow` and `variant` are always required and never combined into one slug. If
the same conceptual flow must run on browser, iOS, and Android, repeat the entry
three times with the same `flow` and each explicit `variant`; Work42 chooses the
concrete compatible device at execution time. Include a normal Markdown link
for review: `[login / browser](flow42://flow/login?variant=browser)`.

Use **`flow42-qa-author`** to select existing definitions or request the
recordings needed to create missing coverage. Flow42 is optional: a
verification-only plan may use terminal/manual evidence without it. If an
approved plan explicitly requires an unavailable flow or Flow Player, name that
as a blocker rather than silently changing coverage.

Write the plan markdown (per-AC prose naming each explicit flow/variant entry,
its launch config, and expected outcomes) to storage:

```
work42 storage set plan/testing "$(cat <your-testplan>.md)"
```

There is no separate testing-plan approval — the single Approve Plan click
covers all three facets.

## Commands

| Command | When |
|---------|------|
| `work42 storage set plan/spec "$(cat <file>)"` | Attach/update the spec (validated by `SpecValidator`; re-writing clears prior approval) |
| `work42 storage set plan/subtasks '<json array>'` | Author/revise the subtask breakdown — each entry's `description` is REQUIRED |
| `work42 storage set plan/testing "$(cat <file>)"` | Attach/update the Testing Plan (when warranted) |
| `work42 storage get plan/spec` · `plan/subtasks` · `plan/testing` | Read back what you've authored |
| `work42 artifact set/status/path <id>` | Render + validate visual + explainer artifacts (see `work42-artifact`) |
| `work42 storage get jira/url` | Read the attached Jira issue |
| **Work42 UI: Approve Plan button** | Yan's click (writes `plan/approved_at`) is the only approval — no CLI equivalent |

Ask `@yan [QUESTION] ...` and record findings/progress **in chat** — there is no
log command.

## Key Rules

- **You never write production code.** Your output is the Plan. Period.
- **One question at a time, multiple-choice preferred.**
- **Build confirmed artifacts BEFORE locking the spec** — a visual-decision
  artifact and a per-item explainer per plan item, each confirmed with the user,
  each referenced from the spec's Design section via `[[artifact:<id>]]`.
- **Safe mermaid node labels** — no colon, `[[…]]` tokens, or trailing prose
  inside a node.
- **Artifacts are loopback-only** — vendor JS libs locally; never fetch.
- **No placeholders** in the spec or any subtask description.
- **Every subtask carries a required description.**
- **Plan approval is a hard gate** — wait for Yan's Approve Plan click. No
  approve command. Do not start implementation.
- **Resolve every Open Question before approval** — the spec's Open Questions
  section is empty (or "none") when you ask.
- **Narrate every meaningful step in chat.** Silence is the worst outcome.
