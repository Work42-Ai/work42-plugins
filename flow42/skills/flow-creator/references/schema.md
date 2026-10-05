# Flow42 registry schema

## Layout

```text
~/.work42/flows/<flow-id>/
  manifest.yaml
  <variant>/
    flow.yaml
    references/
```

The root manifest owns conceptual identity and variant discovery. A variant
file owns only the compatible Work42 device class and its instructions.

## `manifest.yaml`

```yaml
schema_version: 1
id: login
name: Log In
description: Authenticate an existing user.
tags:
  - authentication
variants:
  browser: browser/flow.yaml
  ios: ios/flow.yaml
```

Rules:

- `id` equals the family directory name and uses lowercase slug syntax.
- `variants` is an explicit map. There is no default variant.
- A variant entry exists only after that device recording has been authored and
  confirmed. Never create placeholders.
- Variant paths are relative, remain inside the family directory, and resolve
  to a file.

## Device `flow.yaml`

```yaml
schema_version: 1
device: browser
parameters:
  email:
    type: string
    description: Account email address.
phases:
  - id: authenticate
    intent: Authenticate the account.
    steps:
      - action: type
        arguments:
          label: Email
          role: textbox
          text: ${email}
          clear: true
        precondition: The sign-in form is visible and the Email field is enabled.
        postcondition: The Email field contains the requested account address.
        screenshot: references/authenticate-01.png
      - action: click
        arguments:
          label: Continue
          role: button
        precondition: The form contains a valid email address.
        postcondition: The password step is visible.
        screenshot: references/authenticate-02.png
```

Rules:

- `device` is a Work42 compatibility class such as `browser`, `ios`, or
  `android`; Work42 chooses the concrete device at run time.
- Do not repeat the family id or variant id in this file.
- `parameters` may be absent. Use `${name}` references for authored inputs.
- `phases` is ordered. Each phase has stable `id`, `intent`, and ordered
  `steps`.
- Every step has exactly one `action`, one `arguments` mapping, one prose
  `precondition`, and one prose `postcondition`.
- `action` and `arguments` must match `work42 device actions --json` for the
  declared device. Optional `screenshot` points inside the same variant.
- Screenshots show the state immediately before the action and are explanatory
  material only.

## Forbidden saved fields

Reject any proposed flow containing source recording ids/paths, session ids,
timestamps, video paths, coordinates (`x`, `y`, `at`, fractions), geometry,
runtime refs, transient element ids, copied CLI command strings, run status,
run history, definition hashes, or source provenance.

Incidental actions and failed attempts are authoring evidence, not canonical
steps. When several recordings disagree, prefer the successful semantic path
and ask the user if the difference changes intent.
