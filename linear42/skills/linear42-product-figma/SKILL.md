---
name: linear42-product-figma
description: Design-stage skill for a `linear-product` session — builds the Figma frames that show the confirmed product shape (every flow step plus the empty, loading, error, permission and other edge states), links them to the Linear issue and to the session's Figma tab, and asks the user to approve. Uses the agent's own Figma connector and the public Figma skills; product design only, never implementation.
---

# Product Shape: Figma design

Used in the **Design** stage of every Product Shape session, after `linear42-product` and the type skill have produced a confirmed Product Shape document (`shape/doc`).

## Prerequisites

1. **Figma tools.** `mcp__figma__*` tools must be available. work42 does not inject a Figma MCP; the user enables Figma in their agent's connector settings (see the `using-figma` skill). If the tools are missing, tell the user exactly that and wait. Don't describe frames in text as a substitute.
2. **The Figma skills ship with the `figma` plugin and are already in this session:** `figma-use` (**load it before every `use_figma` call**), `figma-generate-design` (building a flow or screen from a description) and `figma-create-new-file` (a new file when the user has none). Follow them for *how* to build; this skill decides *what* to draw. They talk about code and design systems: here there is no code, so build from the Product Shape document, and reuse the product's design system only if the user points you at one.
3. **A destination.** Ask the user which Figma file or team/project to use, or whether to create a new file. Never create files in a team you weren't given.

## What to draw

Read the Product Shape document (`linear api 'query{document(id:"<slug>"){content}}'`, slug from `shape/doc`). Make one section per flow, with a frame for:

- every step of the primary flow, in order, with the real copy you intend (no lorem ipsum);
- **every row of the shape's edge-case table that changes what the user sees**: first time, empty, loading, error with retry, no permission, too much data, concurrent change, interrupted, reversal/undo, existing users;
- for a bug: the corrected state and any new message.

Name frames `<flow> / <step or state>` (e.g. `Invite / Error: email already a member`) so the shape's edge-case rows map one-to-one onto frames. Reuse the product's existing components and tokens if the user points you at a design system; otherwise keep it plain and say so. Add a first "Overview" frame with the flow map and a legend of states. Don't invent features beyond the shape; if drawing exposes a gap, note it and offer `work42 transition "Shape"` rather than patching it silently.

## Link and hand over

```bash
work42 storage set figma/links "$(jq -nc --arg u "<figma url>" --arg n "<KEY> <short title>" '[{url:$u,name:$n}]')"
```

Append instead of overwrite when there are several files (read `figma/links` first). Then add the link to the Linear issue:

```bash
linear issue comment add <KEY> --body-file - <<'MD'
Design for this shape: <figma url>
_Posted from Work42_
MD
```

Show the user the Figma tab, summarise in chat which edge cases each frame covers and which rows are deliberately undrawn (with the reason), and ask for approval: `@yan [APPROVAL] …`. Remind them that approving means running `work42 storage set shape/approved_at "$(date -u +%FT%TZ)"`; you never write it. When it lands, the session offers Ready; run `work42 transition "Ready"`.
