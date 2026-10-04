---
name: flow42-qa-author
description: Select or prepare reusable Flow42 definitions for a Task42 Testing Plan. Use during planning when UI acceptance criteria need explicit flow and variant coverage, including multi-platform coverage or a request to record a missing variant.
---

# Flow42 QA Author

Help Task42 express optional reusable UI guidance. This skill does not create a
task-local flow pack, execute a flow, or own evidence. Saved definitions belong
to Flow42's global registry; execution and recording belong to Work42.

## Decide whether a flow adds value

Use flow guidance for repeatable UI journeys whose visual behavior must be
exercised. Terminal/API/data acceptance criteria use terminal evidence. A
verification-only Testing Plan with no flows is valid.

Before naming a flow, inspect `~/.work42/flows/<flow>/manifest.yaml` directly.
Require an explicit variant key whose mapped `flow.yaml` exists. Read the whole
variant and its referenced screenshots to ensure it actually covers the desired
acceptance criteria. Never infer a default variant or use similarity alone.

## Testing Plan contract

Write one entry per requested device variant:

```markdown
- flow: login
  variant: browser
  config: "Web QA"
  covers: AC3, AC7
  expected: Authentication completes and the signed-in home screen is visible.

  [login / browser](flow42://flow/login?variant=browser)
```

`flow` and `variant` are separate and required. For browser, iOS, and Android
coverage, repeat the conceptual flow three times. The variant selects the
definition; Work42 selects the concrete compatible registered device when the
global `flow-player` skill runs.

Confirm the exact launch configuration with `work42 debug configs`. A launch
config starts the product, not a Flow42 runtime, and does not replace the
variant field.

## Missing coverage

If the family or required variant does not exist:

1. State which acceptance criteria lack reusable guidance.
2. Ask the user whether they want to record that device variant.
3. If accepted, let Work42 choose the concrete device and create one or more
   completed Work42 recordings.
4. Invoke the global `flow-creator` skill to propose the standalone variant.
   The user must confirm it before it is added to the manifest.
5. Add the Testing Plan entry only after the saved manifest maps that variant.

Do not invent empty variants, translate another platform's steps, author from
coordinates, retain recording identifiers, or use legacy embeds/replicate
commands. Direct human/agent authoring is allowed, but prior knowledge from one
or more recordings is preferred.

## Optional-plugin boundary

Task42 must work without Flow42. Do not import Flow42 code, require its widget,
or add flow coverage to criteria that can be verified through approved non-flow
evidence. If an approved Testing Plan explicitly requires a saved flow and the
plugin or definition is unavailable at Testing time, QA reports that named
blocker; it does not silently replace the requested platform coverage.

## Handoff

Return the exact Markdown entries, the ACs covered by each, and the expected
visual outcome. Do not run the flow during planning. At Testing time,
`task42-qa` invokes `flow-player`; the resulting ordinary Work42 recording is
cited through the existing recording card and timeline grammar.
