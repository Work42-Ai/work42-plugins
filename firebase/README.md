# firebase — Work42 Firebase plugin

Four independent widgets, one per Firebase product, each showing that product's live Firebase Console page:

| Widget | Title | Console page |
|---|---|---|
| `firebase-auth` | Firebase Authentication | `…/project/<projectId>/authentication/users` |
| `firebase-analytics` | Firebase Analytics | `…/project/<projectId>/analytics/overview` |
| `firebase-firestore` | Firebase Firestore | `…/project/<projectId>/firestore` |
| `firebase-crashlytics` | Firebase Crashlytics | `…/project/<projectId>/crashlytics` |

Other Firebase products are not part of this release. The plugin adds no session type and no standalone project
picker: open any of the widgets from a session's `+ Widget` menu and place them wherever you like.

## Install

```sh
work42 plugin inspect work42-plugins/firebase --json
work42 plugin build   work42-plugins/firebase
work42 plugin test    work42-plugins/firebase
work42 plugin install work42-plugins/firebase
```

## Set Project and the shared project

Every widget has a **Set Project** button above the Console page. It runs `firebase projects:list --json
--non-interactive`, shows the projects (searchable, with refresh and cancel), and on confirm saves the choice to

```
~/.work42/firebase/config.json
{"version":1,"projectId":"my-project","displayName":"My Project"}
```

The choice is global: every open Firebase widget, in every window and workspace, switches to it within about two
seconds, and it persists across restarts. It does not depend on a session, a repository, `firebase use` or
`.firebaserc`. The file never holds credentials. Each widget follows the file itself (it is the only shared
state), so a hand edit is picked up too; an invalid file is reported and left untouched until you choose a
project.

## Two sign-ins

- The **Console page** in a widget needs a Google sign-in inside the widget. Widgets share the Work42 `browser`
  cookie store, so signing in once covers all of them.
- **Set Project** and the skills use the **Firebase CLI**, which has its own login (`firebase login`, in a
  terminal). One does not sign in the other.

If the CLI is missing or signed out, the picker says so and points at the `firebase-setup` skill.

## Skills

| Skill | Scope |
|---|---|
| `using-firebase` | global index and the project-selection contract |
| `firebase-setup` | install the CLI, sign in, check the selection |
| `firebase-auth` | `auth:export` / `auth:import`; everything else is Console or an Admin SDK |
| `firebase-analytics` | the CLI has no analytics commands; Console, BigQuery export, Analytics Data API |
| `firebase-firestore` | databases, indexes, backups, bulk delete, emulator, deploy; documents via SDK or Console |
| `firebase-crashlytics` | symbol and mapping-file upload; crash triage is in the Console |

Each product skill rereads the selection for every operation and passes `--project` explicitly. It never runs
`firebase use` or edits `.firebaserc`. Commands in the skills are checked against the installed CLI by the logic
tests (written against Firebase CLI 15.8.0).

## Layout

```
firebase/
  plugin.yaml
  shared/                       canonical Swift sources
    FirebaseProjectConfig.swift   selection file (atomic write) + live store
    FirebaseProjectPicker.swift   CLI listing, parser, picker model and sheet
    FirebaseProduct.swift         product catalog and Console URLs
    FirebaseConsoleWidget.swift   the widget: toolbar + BrowserSurface
  widgets/firebase-<product>/
    Sources/Widget.swift          loader symbols for that product
    Sources/Firebase*.swift       GENERATED copies of shared/ (do not edit)
    SKILL.md
  skills/                       firebase-setup, using-firebase, firebase-<product>
  scripts/sync-widget-sources.py
  Tests/LogicTests/             run.sh + main.swift
```

The installer builds and copies each widget's `Sources` on its own, so installed widgets cannot see `shared/`.
`scripts/sync-widget-sources.py` copies the shared files into every widget; edit `shared/`, run the script, commit
both. `--check` fails on any drift and runs as part of the tests.

## Tests

```sh
firebase/Tests/LogicTests/run.sh
```

Compiles the shared sources with the logic tests (no Work42 app needed) and runs them. All tests use temporary
directories and a fake shell; the real `~/.work42/firebase/config.json` and your Firebase account are never
touched. Covered: absent, corrupt and newer-version config, atomic replacement and failed saves, concurrent
writers, following the file across independent stores, CLI output parsing and failure classification, the picker
(single request, cancel, stale results, save failure), product URLs, widget and skill layout, and drift of the
generated copies.

## Limits

- Console routes are the products' entry pages; Google sign-in, billing, product setup and app selection are
  whatever the Console shows.
- The widgets run the CLI through the session's shell, so Set Project needs a session with a working directory.
- The app's shell has a minimal `PATH`. Set Project loads nvm if `firebase` isn't found; other version managers
  need `firebase` linked into `~/.work42/bin` (see the `firebase-setup` skill). An expired CLI login shows the
  CLI's generic "Failed to list Firebase projects" with a hint to run `firebase login --reauth`.
- The CLI covers only part of each product; the skills say which part. The Console content itself is not
  readable by the agent.
