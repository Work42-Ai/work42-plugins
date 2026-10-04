---
name: flow-creator
description: Create or replace a device-specific Flow42 definition from one or more completed Work42 device recordings. Use when asked to structure recordings into a reusable flow, add a browser/iOS/Android variant, or update an existing variant from newly demonstrated behavior.
---

# Flow Creator

Create standalone flow guidance from what actually happened on one Work42
device class. Recordings are temporary evidence; the saved flow contains only
durable actions, conditions, prose, and copied visual guidance.

Before authoring, read [references/schema.md](references/schema.md) completely.

## Required inputs

Collect:

- One or more completed Work42 recording directories.
- The conceptual flow id, or confirmation that this is a new flow.
- The intended variant id when updating an existing family.

Read every recording's `meta.yaml`, `events.jsonl`, action `meta.yaml` files,
and video/frames. All recordings used for one variant must have the same
Work42 `device_kind`. If identity, variant, device, or recording intent is
ambiguous, ask before drafting.

## Authoring workflow

1. Inspect `work42 device actions --json`. Treat it as the canonical action
   vocabulary and argument schema.
2. Read all supplied recordings. Use multiple recordings to distinguish stable
   procedure from corrections, retries, mistakes, and incidental navigation.
3. Build ordered phases and steps. Keep exactly one canonical Work42 action in
   every step. Preserve only portable semantic arguments accepted by the
   registry.
4. Reject `ref`, `at`, coordinates, geometry, transient element ids, recording
   ids/paths, session ids, timestamps, and source provenance. If an essential
   action has no semantic target, ask for clarification or a better recording.
5. Write useful `precondition` and `postcondition` prose for each step. Do not
   turn them into rigid machine assertions.
6. For each step, select one representative frame immediately before its
   action timestamp. Copy it into that variant's `references/` directory and
   use a relative `references/<file>` path. The image is visual guidance, not
   a pixel assertion. If no valid pre-action frame exists, omit the screenshot
   or request a better recording; never reuse a misleading frame.
7. Produce the complete proposed `manifest.yaml`, device `flow.yaml`, and
   screenshot inventory. For an existing variant, show an exact diff. Do not
   write anything until the user explicitly confirms the proposal.
8. After confirmation, stage the complete family in a same-filesystem sibling
   temporary directory, validate every variant path and screenshot, then
   replace `~/.work42/flows/<id>/` in one finalized move. Preserve unaffected
   variants. Updating a variant replaces its `flow.yaml` in place; do not keep
   registry revisions or recording snapshots.
9. Query `work42 debug devices --json` for currently registered Work42 device
   classes. Offer to record another variant only for available classes absent
   from the manifest. If accepted,
   let Work42 select the concrete device and begin a new recording. Add no
   manifest entry or empty directory until that recording is completed and a
   separate proposal is confirmed. Repeat until declined or none remain.

## Non-negotiable boundaries

- Write only under `~/.work42/flows/<id>/` after confirmation.
- Never retain or copy the source recording, its identifiers, or its metadata.
- Never infer sibling variants or translate actions across device classes.
- Never save literal shell command strings as actions.
- Never save coordinates or live scan references, even as fallbacks.
- Never silently merge a recording into a similarly named family.
- A human or agent may author a flow directly, but this workflow should prefer
  one or more recordings as prior knowledge.

## Final response

State the flow id, variant, device class, written files, number of steps and
screenshots, and which source recordings can now disappear without affecting
the flow. Then present only the other currently available, missing device
classes as optional next recordings.
