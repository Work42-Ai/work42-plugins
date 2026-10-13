# Third-party notices

The skills `figma-use`, `figma-generate-design` and `figma-create-new-file` are bundled **unmodified** from
https://github.com/figma/mcp-server-guide (`skills/`, commit b0bfad2) as supporting resources for widget-figma, so any session with the active Figma widget can build in
Figma through the agent's own Figma connector.

That repository ships no license file. Its README states that by using the Figma MCP server and the related resources,
including these skills, you agree to the [Figma Developer Terms](https://www.figma.com/legal/developer-terms/), and
that the skills are a Beta feature. Review those terms before redistributing this plugin outside your organization.

Some bundled files link to sibling skills that are not bundled (`figma-generate-library`, `figma-code-connect`,
`figma-use-slides`); those paths do not resolve here, and nothing in Product Shape sessions needs them.

To update, copy the three folders from the upstream commit again and change the commit here.
