# figma — Work42 plugin

Figma integration for Work42: a **file browser widget** plus a **using-figma
skill**, wired through the work42 skill registry. work42 injects **no** Figma
MCP — design-data access is the host agent's own Figma connector.

## What's inside

- **`widgets/figma`** — a session-scoped browser widget rendering one tab per
  attached Figma file. Empty state is a paste-URL form; the tab bar's `+`
  attaches another file, a tab's `×` detaches. Shares the `"browser"` cookie jar,
  so one Figma sign-in persists across all browser-based widgets. Stores the
  attached files as a JSON array at storage `figma/links` (`{url, name}`).
- **No work42-injected Figma MCP.** Figma's MCP server is restricted to clients
  on Figma's approved **MCP Catalog** (an allowlist), so a work42-bridged client
  is rejected (`https://mcp.figma.com/mcp` → 403 on dynamic client registration).
  Instead, design-data access uses the **host agent's own Figma connector** — a
  client like **Claude** is catalog-approved and connects Figma directly with a
  one-time browser sign-in. The `using-figma` skill tells the agent to use its
  `mcp__figma__*` tools if present, and otherwise to ask the user to enable a
  Figma connector in their agent settings.
- **`widgets/figma/SKILL.md` (`widget-figma`)** — automatically composed into
  every session with the active Figma widget, for any session type. It covers
  connector setup, attached files, and routes to the full bundled design guides
  at `~/.work42/plugins/figma/skills/`. No global skills or cross-plugin
  `session_skills` references are needed.
- **`skills/using-figma`** — additional plugin documentation for attached files and connectors; the
  widget skill includes the instructions sessions need.
- **`skills/figma-use`, `skills/figma-generate-design`, `skills/figma-create-new-file`** — Figma's own agent skills
  (from `figma/mcp-server-guide`), bundled unmodified: how to write to a Figma file through the connector's `use_figma`
  tool, build a page or flow from a description, and create a new file. See `THIRD_PARTY_NOTICES.md` for the source,
  commit and the Figma Developer Terms they fall under. These folders are
  supporting resources read through `widget-figma`, not independent skill
  entries in the session catalog.
- **`tab-templates/figma-work.json`** — a "Figma Work" tab opening `widget:figma`.

## Install

```bash
work42 plugin install <path-to>/work42-plugins/figma
```

`widget.yaml` and the widget `.dylib` are generated at install time — do not
commit them.
