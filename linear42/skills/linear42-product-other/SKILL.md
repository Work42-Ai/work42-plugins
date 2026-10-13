---
name: linear42-product-other
description: Product Shape type skill for anything that is neither a clear feature nor a bug (research ask, onboarding or copy change, pricing or policy idea, workflow change, an idea that isn't formed yet) — followed by the agent in a `linear-product` session. Brainstorms options, compares them on user value, and lands on a shaped recommendation with its edge cases, published on the Linear issue and designed in Figma if it has an interface. Product perspective only.
---

# Product Shape: other

Load `linear42-product` first. This skill is the method for `shape/type = "other"`. Often this type turns into a feature or a bug halfway: if the work firms up, tell the user, switch with `work42 storage set shape/type '"feature"'` (or `"bug"`), and continue with that skill from where you are.

## Bundled method skills

`brainstorm-ideas-new` (options), `prioritization-frameworks` (only if the user wants a ranking), `jobs-to-be-done` (what the user is really hiring this for), and, once it firms up, the feature skill's set. All ship with the plugin; see `linear42-product`. Without them, use the steps below.

## Discover

Find out what kind of thing this is and what decision it serves:

1. In one sentence, what does the user want to be true when this is done?
2. Who is it for, and what changes for them?
3. Is there a decision to make (option A or B), a thing to design, or a thing to learn?
4. What's the deadline pressure, if any, and what happens if we wait?

Confirm the framing in chat, then `work42 storage set shape/discovery_done "\"$(date -u +%FT%TZ)\""`.

## Shape

Start with Chat artifacts, not a finished document: render the relevant proposed
UI, flows and edge states, let the user review them, and revise in place. Follow
`linear42-product`'s artifact-first loop. Publish the agreed brief and explicitly
confirm the current artifact direction before recording `shape/ideation_approved_at`
and moving to Figma.

- **If the work is a decision**: list 3–5 distinct options (including "do nothing"), and for each the user value, the risk to users, what we'd have to give up, and the edge cases that decide it. Recommend one, say why, and what would change your mind. Use a prioritization framework only if the user wants a ranking; otherwise a table is enough.
- **If the work is to design something** (copy, onboarding, a policy, a setting): shape it as a feature would be: primary flow, rules, and the edge-case table from `linear42-product-feature`, skipping rows that truly don't apply and saying why.
- **If the work is to learn something**: write the questions, who could answer them, and what answer would change what we build; no flows needed.

Always end the document with **Scope** (in / out) and **Open questions**. Publish with `--kind shape`, record `shape/doc` and `linear/issues/<KEY>/spec_doc` as in `linear42-product-feature`, and ask for confirmation.

## Design and after

If the outcome has an interface, copy or layout, load `linear42-product-figma`. If it is a decision or learning with no interface, use artifacts to validate the outcome and discuss whether a Figma deliverable is appropriate. Do not manufacture a Figma board or attach an unrelated file merely to satisfy the Ready gate; keep the session open and explain the gate limitation.
