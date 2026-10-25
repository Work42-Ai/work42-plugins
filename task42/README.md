# task42 — the Task session, as a plugin

The built-in `task` session type — its 5-stage lifecycle (Planning ->
In-Progress -> Testing -> Human Review -> Done), its Spec/Subtasks/QA/
Testing-Plan widgets and its "New Task" creation — extracted into a
first-party bundle: a declarative workflow, a declarative session type +
create-intent and a compiled `onCreate` session hook. Agents work a task with
the Work42 tools (`storage_*`, `transition`, `workflow_status`, `artifact_*`,
`device_*`); the Planner/Worker/QA skills of the first version are gone.

This is a like-for-like extraction, not a redesign — installing this
plugin must leave every existing task session's behavior, gates, and
widgets unchanged.

## Bundle layout

```
task42/
  plugin.yaml                        plugin metadata (name, version, sdk_version)
  workflows/
    task42.json                      the 5-stage workflow: stages, transitions,
                                      gates, capability stage_rules, model pins
  session-types/
    task.json                        the `task` session_types row: workflow,
                                      layout_json, session_skills, args, create_intent
  intents/
    new-task.json                    the "New Task" create-intent
  widgets/
    spec/                            plan/spec — Approve Plan action, comments, artifacts
    subtasks/                        plan/subtasks — toggle/expand/delete rows
    qa/                               qa/report — read-only themed markdown
    testing-plan/                    plan/testing — read-only themed markdown
  Sources/
    Plugin.swift                     onCreate hook: linked To-Do (plan/kind
                                      seeds declaratively via session-types/task.json's
                                      declared `args`, not the hook)
```

See the parent [work42-plugins README](../README.md) for the general
plugin-authoring reference (manifest fields, install/list/remove, the
declarative session-type/workflow/intent schema, slug collisions).
