---
name: linear42-product-feature
description: Product Shape type skill for a FEATURE (new capability or improvement) — followed by the agent in a `linear-product` session. Takes a feature idea through discovery to a product shape with flows, rules, scope and every edge and failure state from the user's side, published as the Product Shape document on the Linear issue. Product perspective only, never engineering.
---

# Product Shape: feature

Load `linear42-product` first (product-only rule, stages, storage, gates). This skill is the method for `shape/type = "feature"`.

## Bundled method skills

Load these as the steps below call for them (they ship with the plugin; see `linear42-product` for how to use them):
`jobs-to-be-done` and `create-prd` in Discover; `user-stories` or `job-stories`, `test-scenarios` and `pre-mortem` in Shape;
`brainstorm-ideas-new` if the user wants options before committing. The steps below stand alone if you skip one.

## Discover

Get to a problem statement the user confirms. Ask one question at a time:

1. **Who** has this problem, and how often? One primary user; list secondary ones.
2. **The job**: what are they trying to get done, in their words? What do they do today instead, and what's painful about it?
3. **Success**: how would we know it worked? A user-visible outcome, not an internal metric.
4. **Why now / why not**: what happens if we do nothing?
5. **Unknowns**: assumptions that could sink it.

Use `jobs-to-be-done` to find the job and `create-prd`'s value-proposition part (who, why, what before, what after, alternatives) to sharpen it. Then write a three-line problem statement in chat (who · job · pain), get a yes, and set `work42 storage set shape/discovery_done "\"$(date -u +%FT%TZ)\""`.

## Shape

Start with Chat artifacts, not a finished document: render the relevant proposed
UI, flows and edge states, let the user review them, and revise in place. Follow
`linear42-product`'s artifact-first loop. Publish the agreed brief and explicitly
confirm the current artifact direction before recording `shape/ideation_approved_at`
and moving to Figma.

Iterate in Chat artifacts, publish when confirmed. Build the document in this order (use `[[artifact:<id>]]` lines for flow diagrams; `work42-artifact-explainer` for the mermaid/HTML):

1. **Problem and goal** (from Discover) and the **success signal**.
2. **Primary flow**: numbered steps from the user's point of view, each with what they see and what they choose.
3. **Rules**: decisions the product makes (who can do it, limits, defaults, what is remembered), each a short sentence a non-engineer can check.
4. **Edge cases and failure states**: the table below is mandatory, even if a row says "not applicable, because …".
5. **Scope**: in, explicitly out (non-goals), and a possible later phase.
6. **Open questions**: each with an owner; an empty list means none remain.

Edge-case table, one row per case with *what the user sees* and *what they can do next*:

| Case | Prompts to run through |
|------|------------------------|
| First time | No data, no history, no explanation yet |
| Empty | Nothing to show; nothing matches a search or filter |
| Loading and slow | Waiting, partial results, the user leaves and returns |
| Error | The action fails; the user retries; the failure repeats |
| Permission | Not allowed, signed out, read-only, wrong workspace |
| Too much | Very long names, thousands of items, huge files |
| Concurrent | Two people or two devices at once; stale view |
| Interrupted | Closed halfway, offline, session expired |
| Reversal | Undo, delete, cancel, restore |
| Existing users | Data or habits from before the feature; what changes for them |
| Accessibility and languages | Keyboard only, screen reader, long translations |

Write the primary flow as `user-stories` or `job-stories` with acceptance criteria, and turn each edge-case row into a `test-scenarios` entry (starting condition, steps, what the user sees). Then run `pre-mortem`: assume it shipped and failed, and fold the most likely reasons from the user's side into a rule or an edge case.

Publish (stdin, quoted heredoc), record, and confirm with the user:

```bash
.claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind shape --file - <<'MD'
# <KEY>: <feature title> — product shape
…
MD
work42 storage set shape/doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
work42 storage set linear/issues/<KEY>/spec_doc "$(jq -nc --arg s "<slug>" --arg u "<url>" '{slug:$s,url:$u}')"
```

Read it back (`linear api 'query{document(id:"<slug>"){content}}'`, never `document view --raw`) and ask: `@yan [QUESTION] Does this shape match what you want?`. Revisions: republish with `--slug <slug>` and the whole new markdown.

## Design and after

Move on when the session offers Design; load `linear42-product-figma`. Every row of the edge-case table that changes what the user sees needs a frame.
