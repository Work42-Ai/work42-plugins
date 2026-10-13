---
name: widget-figma
description: |
  Use Figma in any session with the active widget:figma widget: read and attach
  files through figma/links, inspect designs through the agent's Figma connector,
  and create or edit Figma designs with the bundled figma-use,
  figma-generate-design and figma-create-new-file guides. Load this skill for
  Figma work, including before every use_figma call.
---

# Figma widget and design skills

This skill follows the active `widget:figma` widget in **any session type**.
The Figma plugin bundles the full upstream guides and their reference files;
use the paths below to read them. They are supporting resources for this widget
skill, not independently registered session or global skills.

## Prerequisites

1. For structured reads and design edits, discover the agent's available Figma
   connector tools. Work42 does not inject or authenticate a Figma MCP.
2. If the tools are missing or unauthenticated, ask the user to enable or sign
   in to their Figma connector in the agent's settings. The widget's browser
   sign-in alone does not authenticate the connector.
3. The bundled guides must exist under the current app's plugin directory:
   `~/.work42/plugins/figma/skills/` in Work42, or
   `~/.work42/plugins-qa/figma/skills/` in Work42 QA.
   If missing, reinstall or update the Figma plugin. Do not download skills
   into the user's global agent directories.

## Bundled Figma guides: load before using tools

Read these files from the installed plugin directory with your file-reading
or shell tool (expand `~` to the user's home directory). **In Work42 QA,
replace `plugins/` with `plugins-qa/` in every path below.** Use the directory
for the app hosting the session; do not fall back to another app's plugin copy:

| Task | Required guide |
|------|----------------|
| Every `use_figma` call, including programmatic reads | `~/.work42/plugins/figma/skills/figma-use/SKILL.md` |
| Creating or changing a visible design, screen or flow | Also read `~/.work42/plugins/figma/skills/figma-generate-design/SKILL.md` |
| Creating a new Figma file | `~/.work42/plugins/figma/skills/figma-create-new-file/SKILL.md` |

**Before every `use_figma` call, read the bundled `figma-use` guide.** Before
visible design changes, also read `figma-generate-design` and follow its design
system discovery, assembly and validation instructions. Include the guide names
in the tool's `skillNames` parameter as directed by the upstream guides.

Resolve each guide's relative links against its directory **in the installed
plugin**, not against this widget skill. For example, `figma-use`'s
`references/plugin-api-standalone.index.md` is at
`~/.work42/plugins/figma/skills/figma-use/references/plugin-api-standalone.index.md`.
The guides and their references are already shipped; no skill installation is
needed. If an upstream link names an unbundled companion (such as
`figma-generate-library`, `figma-code-connect` or `figma-use-slides`), do not
claim it is available. Use the connector's resources if available, or explain
what is missing for that task.

Use the current session's goals to decide what to design. For a Product Shape
session, follow its product-only rules and shape document; source-code and
engineering steps in the upstream guides apply only when the session asks for
them.

## Attached files live in session storage

The widget renders one tab per attached Figma file. Namespace `figma`, key
`links` holds a JSON array of `{ "url": <string>, "name": <string?> }`.
Read the current session's files:

```bash
work42 storage get figma/links
```

After creating or finding a file, attach it so it appears in the widget:

```bash
work42 storage set figma/links '[{"url":"https://www.figma.com/design/AbC123/My-Design","name":"My Design"}]'
```

Preserve existing links when adding a file: read the array first, then write
an updated array. The tab bar's `+` attaches a file; `×` detaches it. Browser
widgets share the `browser` cookie jar, so browser sign-in persists across them
and across restarts.

## Working flow

1. Read `figma/links` and the user's request to establish which files are in scope.
2. Discover Figma connector tools and check authentication.
3. Load the required bundled guides and their relevant references above.
4. Inspect or build in Figma, validate the result with the connector's evidence,
   and attach the resulting file through `figma/links`.
