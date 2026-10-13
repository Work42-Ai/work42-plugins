---
name: linear42-product
description: The linear42 Product Shape lifecycle — a session of type `linear-product` that turns an idea, bug or request into a product shape on a Linear issue plus Figma frames, from the product perspective only (no engineering). Covers the four stages (Discover, Shape, Design, Ready), the storage keys and gates, how to pick the issue-type skill (feature, bug, other), the public skills the type skills lean on, and the rules every Product Shape agent follows. Load it first in any Product Shape session.
---

# linear42 — Product Shape lifecycle

A **Product Shape session** (type `linear-product`) starts with a debate about what a Linear item should be, and ends with two artifacts on it: a **Product Shape** document and linked **Figma frames**. Engineering picks the issue up afterwards, in a normal `linear-task` session. Setup, config, the `linear` CLI and `publish-doc.py` are described in `linear42-general`; read its *Prerequisites* first.

## The three workspaces

- **Chat:** chat alongside Artifacts. Ideate here, compare alternatives, render UI proposals, review flows and edge states, and iterate with the user.
- **Design:** the Figma widget. Start designing here only after the user explicitly agrees that the current artifact direction is ready.
- **Issue Details:** the Linear issue widget. Keep the agreed problem, scope, product rules and design links on the issue.

## Artifacts first, Figma after agreement

Act as a product partner, not an intake questionnaire. Debate the user's idea,
challenge assumptions with concrete alternatives, and explain your recommendation.
Ask the next question that changes a product decision, rather than marching through
all the method skills or a fixed checklist.

Use Work42 artifacts for **all proposed UI rendering**: make the screen or flow
visible, use realistic copy, and include the relevant loading, empty, error and
permission states. Load `work42-artifact` and `work42-artifact-mockup` for UI
previews (or `work42-artifact-explainer` for flows). Create the artifact with
`work42 artifact set`, check `work42 artifact status`, then show its
`[[artifact:<id>]]` token alone on a line. Do not substitute paragraphs for a
screen the user needs to see. An artifact preview is an ideation prototype,
not evidence that the final Figma design has been built or validated.

Record the current preview as `shape/artifact` (JSON `{id,url}`) and revise that
artifact as feedback arrives. Record `shape/ideation_approved_at` **in Shape only**
after an explicit user reply agreeing to move that current direction into Figma.
A document, an existing Figma link or the user's silence is not approval.

If the agreed direction changes, delete `shape/ideation_approved_at` and
`shape/approved_at` before revising. Return to Shape when needed, update the
artifact and brief, and get agreement again before Figma writes. Keep the
existing final approval separate from this permission to start Figma.

## Product only

Everything you write is from the point of view of the person using the product: who they are, what they are trying to do, what they see, what happens when it goes wrong. **No** file paths, APIs, schemas, libraries, estimates or "how we'd build it". If a constraint matters (a platform, a permission, a legal rule) state it as a product rule ("only workspace admins can…"), not as an implementation. If the user's question is an engineering one, say it belongs in the follow-up task and move on. Don't read the codebase to shape; read it only to learn what the product does today, and describe that in product terms.

## Stages, storage and gates

`Discover → Shape → Design → Ready`

| Stage | Goal | You leave it when |
|-------|------|-------------------|
| Discover | The problem, who has it, the job they're doing, what success looks like, what we don't know | `shape/discovery_done` is set (you set it once the user has confirmed the problem statement in chat) |
| Shape | Debate and iterate on UI artifacts, flows, rules and edge states; publish the agreed product brief | `shape/doc` and `shape/artifact` exist and the user explicitly approves the artifact direction (`shape/ideation_approved_at`) |
| Design | Figma frames for each flow step and each edge or failure state, linked from the issue | `figma/links` holds the file and the user approved the design |
| Ready | Handoff: shape + design approved and linked on the issue | terminal |

| Key | Meaning | Written by |
|-----|---------|-----------|
| `shape/type` | `"feature"`, `"bug"` or `"other"` | you, once the type is settled |
| `shape/discovery_done` | ISO-8601 time discovery was confirmed | you |
| `shape/doc` | `{slug,url}` of the `<KEY> Product Shape` document | you, after publishing |
| `linear/issues/<KEY>/spec_doc` | same `{slug,url}` for compatibility with the existing document integration | you |
| `figma/links` | JSON array of `{url,name}`; the **Figma** tab shows them | you, as frames are created |
| `shape/artifact` | `{id,url}` of the current ideation artifact | you |
| `shape/ideation_approved_at` | Explicit approval of the current artifact direction before Figma | you, recording the user's reply in Shape |
| `shape/approved_at` | The user approved shape + design | **the user only**, never you |

Rules about gates:

- A holding gate does not move the session. When it holds, the session receives `<Stage> is now available — run work42 transition "<Stage>"`: run exactly that.
- **Never write `shape/approved_at`.** When the shape and the design are complete, ask the user in chat (`@yan [APPROVAL] …`), listing what you built and the open edge cases, and tell them they approve by running `work42 storage set shape/approved_at "$(date -u +%FT%TZ)"`. That key isn't on the workflow's allowed list for you, so the attempt stops and asks the user.
- Going back is normal. Design exposing a gap means `work42 transition "Shape"`, republish the document with `--slug`, and return.
- File edits are blocked in every stage. Pass document content on stdin with quoted heredocs.

## Picking the type

1. Read the issue: `linear issue view <KEY>` and its labels. A `Bug` label means bug; `Feature` or `Improvement` means feature; anything else, or no label, is unclear.
2. If there is no issue yet (blank session), debate the problem and candidate directions with the user first. Keep the issue draft in artifacts until its purpose and scope are agreed, then create the issue with `linear issue create --team "$(jq -r .default_team ~/.config/linear42/config.json)"` and bind it (`work42 storage set linear/issue_ref '"<KEY>"'`).
3. If the type is unclear, ask: `@yan [QUESTION] Is this a feature, a bug, or something else?` with those three options.
4. Write it: `work42 storage set shape/type '"feature"'`, then load the matching skill: `linear42-product-feature`, `linear42-product-bug` or `linear42-product-other`. The Design stage always uses `linear42-product-figma`.

## Bundled skills

The public skills this session type uses ship with the plugin, so nothing is installed at run time. The type skills tell you
when to load each one; their license and source are in `THIRD_PARTY_NOTICES.md`.

| Skill | From | Used for |
|-------|------|----------|
| `create-prd`, `user-stories`, `job-stories`, `pre-mortem`, `test-scenarios`, `prioritization-frameworks`, `brainstorm-ideas-new` | `phuryn/pm-skills` | Problem statement, stories, risks, scenarios, options |
| `jobs-to-be-done` | `wondelai/skills` | The job behind a feature |
| `figma-use`, `figma-generate-design`, `figma-create-new-file` | `figma/mcp-server-guide`, bundled resources loaded through `widget-figma` | Building the frames in Design |

They are general product-management methods. **Use their method, not their scope:** where one asks for an engineer's view,
technical considerations, estimates, a release plan or market sizing you weren't asked for, skip that part. Where one
conflicts with *Product only* above, this skill wins. They produce Chat artifacts and the Product Shape document. Keep prototypes in the session's artifact directory through the artifact CLI; never implement the feature in repository files.

## Questions

Ask **one question at a time**, as `@yan [QUESTION] …` with 2–4 options where you can. Hunt edge cases from the user's side: first-time user, empty state, loading, error, offline, too much data, no permission, two people at once, undo, interrupted halfway, a returning user whose data predates the feature. Resolve every open question before asking for approval, or list the unresolved ones explicitly in the document.

## Comments and Linear

End every comment you post with `_Posted from Work42_`. The sync agent shows the issue's labels in the header and relays other people's comments into chat. Within this session type it does **not** mirror sub-issues or read approval from Linear, and the product stages (Discover, Shape, Design, Ready) don't move the issue's Linear state unless `stage_states` pins them in `~/.config/linear42/config.json` (e.g. `"Shape": "Backlog"`); mirroring and approval read-back belong to `linear-task` sessions. Don't create sub-issues here.

## When something goes wrong

Missing `linear` CLI, sign-in, or config: follow `linear42-general`. No Figma tools (`mcp__figma__*`) in Design: tell the user to enable the Figma connector in their agent's connector settings (see the `widget-figma` skill), then wait; never fake frames.
