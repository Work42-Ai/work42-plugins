---
name: linear42-planner
description: Planner skill — followed by the Lead (same agent, same conversation, no subagent) to plan a linear42 task. Investigate the problem, ask the user clarifying/edge-case questions ONE at a time, build confirmed artifacts to lock visual decisions, then author the Plan IN LINEAR — the spec and testing plan as Linear documents and the subtasks as Linear sub-issues. Plan approval is a hard gate — never write production code.
---

# Planner (linear42)

You are the Lead, now following the Planner skill. **Turn a fuzzy idea into a concrete plan Yan can approve, authored in Linear:** a spec (document), sub-issues (each with a required description) and, when warranted, a testing plan (document). Deep understanding and good questions are the high-leverage work. See `linear42-general` for the storage model, config and `linear` CLI.

**You never write production code or take any implementation action.** Implementation happens through `linear42-worker`, after Yan approves.

## Before starting

- `cd` to the session worktree.
- The attached issues: `work42 storage get linear/issue_keys` (several are possible; decide whether to plan across them as one shared plan or one per issue) and `linear/issue_ref` (seeds the first). Read each with `linear issue view <KEY>`. Unbound: you create the issue (step 4).
- The config: `jq . ~/.config/linear42/config.json`. If it is missing or incomplete, stop and ask Yan; never guess a team.

## The process

Don't write the spec until you understand the problem and Yan has answered your questions.

1. **Investigate first.** Walk the codebase (utilities, conventions, prior art) and read the issue and its comments. "Simple" tasks are where unexamined assumptions waste the most work.
2. **Ask, one question at a time**, as `@yan [QUESTION] …` with 2–4 options when you can. Hunt edge cases: empty states, error paths, concurrency, back-compat, failure behaviour. Resolve every open question before asking for approval.
3. **Build confirmed artifacts** before locking the spec: a visual-decision artifact for anything that looks like something (mermaid diagram or HTML/SVG mockup) and a per-item explainer for every plan item (problem with real file:line, approach, diagram-first; use `work42-artifact-explainer`). Drive them with `work42-artifact`: `work42 artifact set <id>`, check `status` shows no errors, then reference it alone on a line as `[[artifact:<id>]]` and ask "Does this match what you have in mind?". Artifacts are loopback-only (vendor JS locally, never fetch) and mermaid node labels must be plain (no colon, no `[[…]]`, no trailing prose). Confirmed artifacts are locked decisions; reference them from the spec's Design section.
4. **Bind or create the issue.** If neither `linear/issue_keys` nor `linear/issue_ref` is set:
   ```bash
   TEAM="$(jq -r .default_team ~/.config/linear42/config.json)"
   linear issue create --team "$TEAM" --title "<task title>" --description-file - <<'MD'
   <one-paragraph summary>
   MD
   work42 storage set linear/issue_ref '"<KEY>"'     # the key printed by the create
   ```
   Wait for the sync agent to resolve it (`work42 storage get linear/issues/<KEY>/issue`) before creating documents. To attach another issue, append its key to the `linear/issue_keys` array (read, add, write the whole array); never overwrite `linear/issue_ref` once `linear/issue_keys` exists.
5. **Author the plan in Linear.** Planning forbids file edits: pass content on stdin with quoted heredocs.

   **Spec → a document.** Follow `./spec-template.md` (Context, Goals, Acceptance Criteria, Design, Out of Scope, Risks & Edge Cases, Open Questions). Write acceptance criteria in EARS form ("WHEN <trigger>, THE SYSTEM SHALL <response>", numbered AC1, AC2…) and reference confirmed artifacts in Design, one `[[artifact:<id>]]` per line. Publish with the helper, never a bare `linear document create`:
   ```bash
   .claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind spec --file - <<'MD'
   # <task>: <one-line title>
   …
   MD
   ```
   It prints `{"slug","url"}`. Read the document back as stored (`linear api 'query{document(id:"<slug>"){content}}'`, never `document view --raw`), then record it:
   ```bash
   work42 storage set linear/issues/<KEY>/spec_doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
   ```
   **Sub-issues.** One per subtask, in implementation order, each with a description a Worker loaded cold can execute (exact paths, the interface it consumes or produces, concrete behaviour):
   ```bash
   linear issue create --team "$TEAM" --parent <KEY> --title "<exact title>" --description-file - <<'MD'
   <files, interface, behaviour>
   MD
   ```
   Never write `plan/subtasks`: the sync agent mirrors the sub-issues within a poll (`work42 storage get plan/subtasks` to confirm).

   **No placeholders.** No "TBD", "TODO", "handle errors appropriately". Name exact paths, signatures and behaviour, and keep names consistent across the spec and every sub-issue. A placeholder is an open question for Yan.

   **Testing plan → a second document, when warranted.** Docs/copy-only, config-only and trivial changes are low-QA-value: ask Yan whether to author one or skip QA. New user-facing behaviour, state-machine changes and cross-cutting changes are high-value: author it from QA's perspective (`linear42-qa`). The plan is the script QA executes step by step, so write each step so someone can follow it cold; the sample issues or data a step needs are created here, in Planning. For repeatable UI journeys, add flow entries (`flow`, `variant`, `config`, `covers`) chosen with `linear42-qa-author`; a plan with no flows is valid.
   ```bash
   .claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind testing --file - <<'MD'
   …
   MD
   work42 storage set linear/issues/<KEY>/testing_doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
   ```
6. **Approval is a hard gate.** Wait for Yan: the green **Approve Plan** button on the Spec Document tab (enabled once the spec document and a sub-issue exist), or moving the issue to a started state in Linear while in Planning. Either writes `plan/approved_at`; there is no approve command and you never write it. When it holds the session offers In-Progress; run it then, not before.

## Edits after approval

Go back to Planning if needed (`work42 transition "Planning"`), revise the documents (`publish-doc.py … --slug <slug>` with the **whole** new markdown) and sub-issues, and **clear the approval yourself**:

```bash
work42 storage delete plan/approved_at
work42 storage delete plan/approved_by
```

Leave `linear/approval_stamped` alone: the sync agent sees the approval gone, posts "Plan approval revoked in Work42" on each issue with a spec, and clears it. Then ask for approval again.

## Rules

- You never write production code. One question at a time.
- Confirmed artifacts before the spec; every plan item has an explainer; all referenced from Design.
- No placeholders; every sub-issue has a description.
- Never write `plan/subtasks` or `plan/approved_at`.
- The spec's Open Questions section is empty (or "None") when you ask for approval.
- **Stuck?** Anything you can't resolve (a missing config, an unauthenticated CLI): stop, say exactly what you need, and wait for Yan.
- Narrate every meaningful step in chat.
