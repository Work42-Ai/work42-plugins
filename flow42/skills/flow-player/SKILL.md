---
name: flow-player
description: Run one explicit Flow42 flow and device variant as adaptable guidance on a Work42-managed device. Use when asked to execute or verify a saved flow while producing mandatory Work42 recording evidence.
---

# Flow Player

Use a saved Flow42 definition as guidance for an agent-controlled Work42 device
session. Flow42 does not own a run, cursor, harness, recording, or verdict.

## Required selection

Require two separate values before doing anything:

- `flow`: the family id under `~/.work42/flows/`
- `variant`: an explicit key from that family's `manifest.yaml`

Never infer a default variant, even when only one exists. If either value is
missing, ask the user and do not start a device or recording.

Resolve `~/.work42/flows/<flow>/manifest.yaml`, require its `id` to match the
directory, and require the selected variant in its `variants` map. Resolve the
mapped path relative to the family directory and reject traversal, absolute
paths, symlink escape, or a missing file. Read the entire device `flow.yaml`
and every referenced screenshot before execution. Treat malformed fields as
warnings when the remaining guidance is understandable; stop for an invalid
device, missing phases, unresolved parameters, or unusable action data.

## Mandatory Work42 recording envelope

1. Ask Work42 to resolve a concrete device compatible with the definition's
   `device` value.
2. Run `work42 device start --device <device-class>`. This must successfully
   start Work42 recording before the first flow action. If it fails, perform no
   flow actions and report that the flow was not run.
3. As soon as start succeeds, establish cleanup: `work42 device stop` is
   mandatory before every return path—success, failure, cancellation, action
   error, unexpected device state, or agent exception. Stopping persists the
   ordinary Work42 recording; never delete failed or cancelled evidence.
4. Never claim a completed execution without the retained Work42 recording.

## Execute as guidance

Resolve required parameter values, then consider the complete definition,
including phase intent, each one-action step, conditions, arguments, and
pre-action screenshot. For every step the agent may:

- invoke the declared action through `work42 device` using the canonical action
  id and semantic arguments;
- substitute another registered Work42 action; or
- skip the action entirely, including when its intended state already holds.

The agent—not Flow42—controls execution. Record a short reason for every
substitution or skip. Preconditions and postconditions inform observation and
recovery; they are not a mechanical pass/fail engine. Never turn screenshot
pixels into coordinates or selectors.

After gathering the whole device state and recording evidence, state the
agent's holistic successful/unsuccessful/inconclusive judgment and explain it.
Then stop and retain the Work42 recording even when the judgment is negative.
The recording remains a normal Work42 device recording and is cited through
Work42's existing recording card and timeline; do not create Flow42 run data.

## Successful adaptation feedback

When a substituted or skipped step still accomplished the intended result:

1. After recording stops, show the user the deviation and an exact proposed
   `flow.yaml` diff.
2. Include a replacement pre-action screenshot from the successful recording
   when the changed step needs new visual guidance.
3. Ask for explicit confirmation before replacing the canonical file.
4. On confirmation, apply the update with the same standalone and portable
   constraints used by Flow Creator.

Never mutate the flow from a failed workaround. Failed deviations remain only
in the agent's report and Work42 recording evidence.

## Final response

Name the flow and variant, concrete Work42 device, recording evidence, holistic
verdict, and reasons for every skipped or substituted step. If a successful
adaptation occurred, include the proposed update and ask for confirmation; do
not silently edit the definition.
