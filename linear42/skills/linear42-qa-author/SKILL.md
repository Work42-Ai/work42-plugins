---
name: linear42-qa-author
description: Select or prepare reusable Flow42 definitions for a linear42 testing plan (the Linear document). Use during planning when UI acceptance criteria need explicit flow and variant coverage, including multi-platform coverage or a request to record a missing variant.
---

# linear42 QA Author

Express optional, reusable UI guidance in the testing-plan document. This skill doesn't run a flow, own evidence or create task-local flow packs: saved definitions live in Flow42's global registry, and Work42 executes and records them.

## When a flow adds value

Use one for a repeatable UI journey whose visual behaviour must be exercised. Terminal, API and data acceptance criteria use terminal evidence; a testing plan with no flows is valid.

Before naming a flow, read `~/.work42/flows/<flow>/manifest.yaml`. Require an explicit variant key whose mapped `flow.yaml` exists, and read the whole variant and its screenshots to be sure it covers the criteria. Never infer a default variant or go by similarity.

## The entry

One per requested device variant:

```markdown
- flow: login
  variant: browser
  config: "Web QA"
  covers: AC3, AC7
  expected: Authentication completes and the signed-in home screen is visible.

  [login / browser](flow42://flow/login?variant=browser)
```

`flow` and `variant` are separate and required; browser, iOS and Android coverage repeats the entry three times. Confirm `config` with `work42 debug configs` (it starts the product and doesn't replace the variant).

## Missing coverage

If the flow or variant doesn't exist:

1. Say which criteria lack reusable guidance and ask Yan whether to record that variant.
2. If yes, let Work42 pick the device and create one or more completed Work42 recordings.
3. Invoke the global `flow-creator` skill to propose the standalone variant; Yan confirms it before it is added to the manifest.
4. Add the testing-plan entry only once the saved manifest maps that variant. Never invent empty variants, translate another platform's steps, author from coordinates or keep recording identifiers.

## Boundary and handoff

linear42 works without Flow42: don't import its code, require its widget, or add flows to criteria that other evidence covers. If an approved plan requires a flow that is unavailable at Testing, QA stops and asks Yan; it never swaps in other coverage.

Return the exact entries, the criteria each covers and the expected visual outcome. Don't run the flow while planning; at Testing `linear42-qa` follows it with `flow-player`.
