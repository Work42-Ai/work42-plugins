---
name: linear42-product-bug
description: Product Shape type skill for a BUG — followed by the agent in a `linear-product` session. Describes the defect from the user's side (what they did, what they expected, what happened, how bad, who is affected), defines the correct behaviour and the cases around it, and designs the fixed experience in Figma. Product perspective only, never root-cause or code.
---

# Product Shape: bug

Load `linear42-product` first. This skill is the method for `shape/type = "bug"`. A product bug shape answers "what *should* the user get", not "why is it broken": **no root-cause analysis, no code reading, no fix proposals**. If the user volunteers a cause, note it as a hint on the issue for the follow-up engineering task.

## Bundled method skills

`test-scenarios` (the correct behaviour and the cases around it as scenarios), `user-stories` or `job-stories` (the expected
behaviour in the user's words) and `pre-mortem` (how the fix could still fail the user). All ship with the plugin; see
`linear42-product` for how to use them. The steps below stand alone.

## Discover

Establish, one question at a time, and write the answers into the issue description as a clean report:

1. **What the user did**: numbered steps, from where they started. Ask for the exact path, not a summary.
2. **Expected vs actual**: what they expected to see, what they saw (a screenshot or recording if they have one).
3. **Impact**: who is affected (everyone / one plan / one platform / one account), how often, and what they lose (data, money, time, trust). Name a severity: *blocker* (no workaround), *major* (painful workaround), *minor* (annoyance).
4. **Workaround**: what users do today.
5. **First seen / changed**: when it began, if known, and what changed for the user around then.

Confirm a one-paragraph report in chat, then call `storage_set` with key `shape/discovery_done` and the current UTC timestamp as the value.

## Shape

Start with Chat artifacts, not a finished document: render the relevant proposed
UI, flows and edge states, let the user review them, and revise in place. Follow
`linear42-product`'s artifact-first loop. Publish the agreed brief and explicitly
confirm the current artifact direction before recording `shape/ideation_approved_at`
and moving to Figma.

Publish the Product Shape document with:

1. **Report** (from Discover) and **severity with the reason**.
2. **Correct behaviour**: the flow as it should work, step by step, from the user's side; this is the acceptance of the fix in plain words (a `job-stories` entry per step that matters).
3. **Around the bug**: the neighbouring cases that must also be right. Walk the same dimensions as a feature (first time, empty, error, permission, too much, concurrent, interrupted, reversal, existing users) and mark each *affected* or *unaffected*, with what the user should see when affected; write each as a `test-scenarios` entry.
4. **Users already hit**: what happens to data or state the bug already damaged (repair, apology message, nothing); this is a product decision for the user to make.
5. **Not in scope**: tempting adjacent improvements, parked.
6. **Open questions**.

Publish and record exactly as in `linear42-product-feature` (`--kind shape`, then `shape/doc` and `linear/issues/<KEY>/spec_doc`) and ask for confirmation.

## Design and after

Design only what changes: the broken screen's corrected state and any new message (error, confirmation, repair notice). If nothing visual changes, say so, add a single frame or annotated screenshot showing the correct state, and let the user confirm. Load `linear42-product-figma`.
