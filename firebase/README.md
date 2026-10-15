# firebase — Work42 Firebase plugin

Four independent widgets, one per Firebase product, each with its official Firebase icon and showing that
product's live Firebase Console pages, one browser tab per project:

| Widget | Title | Console page of each tab |
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

## Projects and tabs

Every widget has a small floating **Projects** button at the bottom right (Firebase flame, transparent Liquid
Glass; tooltip "Open Projects Selection"), and the `+` in the browser's tab bar does the same. It opens the
selection window: it runs `firebase projects:list --json --non-interactive`, lists the projects (name, ID,
checkbox; search and refresh), and **Save** writes the checked ones to

```
~/.work42/firebase/config.json
{"version":2,"projects":[{"projectId":"my-project","displayName":"My Project"}]}
```

The list is shared: every open Firebase widget, in every window and workspace, shows one tab per listed project
within about two seconds, each on its own product page, and the list persists across restarts. It does not
depend on a session, a repository, `firebase use` or `.firebaserc`. The file never holds credentials.

- Projects you already saved keep their order; newly checked projects are appended in the CLI's order. A saved
  project the CLI no longer lists stays in the window, checked and marked "not listed by the CLI", so you can
  remove it.
- `×` on a tab hides that project **in that widget only**. It comes back when the shared list changes or Work42
  restarts. It never edits the list.
- With one project the widget shows a single tab and no tab bar. With none, it says so and keeps the Projects
  button.
- A version 1 file written by plugin 0.1.0 (`{"version":1,"projectId":…}`) is read as a one-project list and only
  rewritten as version 2 the next time you save. Plugin 0.1.0 cannot read a version 2 file.
- An absent file is "no projects yet"; a corrupt or newer-version file is reported and left untouched until you
  save a list. Each widget follows the file itself (it is the only shared state), so a hand edit is picked up too.

## Console links

Clicking a Firebase Console link opens the matching widget: `…/project/<id>/authentication…` opens Firebase
Authentication, `analytics…` Analytics, `firestore…` Firestore, `crashlytics…` Crashlytics (with or without a
`/u/<n>/` account prefix). The widget selects that project's tab and shows the exact page. A link to a project
that isn't in your list opens a **temporary** tab in that widget only; it is never saved and disappears when
closed. Links for other Firebase products (Storage, Hosting, …) still open in the Browser. A link inside a
widget's page to another page of the same project and product navigates in place.

## Two sign-ins

- The **Console pages** in a widget need a Google sign-in inside the widget. Widgets share the Work42 `browser`
  cookie store, so signing in once covers all of them.
- The **Projects** window and the skills use the **Firebase CLI**, which has its own login (`firebase login`, in a
  terminal). One does not sign in the other.

If the CLI is missing or signed out, the window says so and points at the `firebase-setup` skill.

## Skills

| Skill | Scope |
|---|---|
| `using-firebase` | global index and the project-list contract |
| `firebase-setup` | install the CLI, sign in, check the project list |
| `firebase-auth` | `auth:export` / `auth:import`; everything else is Console or an Admin SDK |
| `firebase-analytics` | the CLI has no analytics commands; Console, BigQuery export, Analytics Data API |
| `firebase-firestore` | databases, indexes, backups, bulk delete, emulator, deploy; documents via SDK or Console |
| `firebase-crashlytics` | symbol and mapping-file upload; crash triage is in the Console |

Each product skill rereads the project list for every operation. With one listed project it uses it; with several
it uses the one you named, otherwise it asks; with none it asks you to add projects with the Projects button. It
always passes `--project` explicitly and never runs `firebase use` or edits `.firebaserc`. Commands in the skills
are checked against the installed CLI by the logic tests (written against Firebase CLI 15.8.0), and the read
snippet in the skills is run against real config files by them too.

## Layout

```
firebase/
  plugin.yaml
  shared/                       canonical Swift sources
    FirebaseProjectConfig.swift   project list file (atomic write) + live store
    FirebaseProjectPicker.swift   CLI listing, parser, selection model and window
    FirebaseProduct.swift         product catalog, Console URLs, link patterns
    FirebaseTabs.swift            which tabs a widget shows, link actions
    FirebaseBrand.swift           embedded official icons and the Firebase logomark
    FirebaseConsoleWidget.swift   the widget: tabs, Projects button, links
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

## Icons

The widget icons are Firebase's own product icons (Build and Run pages of https://firebase.google.com/products-build)
and the Projects button uses the Firebase logomark from https://firebase.google.com/brand-guidelines, rendered
unmodified to 64x64 PNGs with transparency and embedded in `shared/FirebaseBrand.swift` (the file header lists
each source URL and how it was rendered). Their use is subject to Firebase's brand guidelines.

## Tests

```sh
firebase/Tests/LogicTests/run.sh
```

Compiles the shared sources with the logic tests (no Work42 app needed) and runs them. All tests use temporary
directories and a fake shell (plus a fake nvm for the CLI lookup); the real `~/.work42/firebase/config.json` and
your Firebase account are never touched. Covered: absent, version 1, version 2, corrupt and newer-version config,
atomic replacement and failed saves, concurrent writers, following the file across independent stores, CLI output
parsing and failure classification, finding the CLI from the app's minimal shell, the selection model (checks,
order, not-listed projects, cancel, stale results, save failure), tab building and hiding, Console link
matching/parsing/same-page rules, icon PNG pixels, product URLs, widget and skill layout, and drift of the
generated copies.

## Limits

- Console routes are the products' entry pages; Google sign-in, billing, product setup and app selection are
  whatever the Console shows.
- The SDK has no way to load a URL into an existing tab, so a link to a listed project's tab replaces that tab
  with a new one at the link (the tab's back history is lost).
- The SDK always shows `+` and `×` in the tab bar; here they open the selection window and hide a tab.
- The widgets run the CLI through the session's shell, so the Projects window needs a session with a working
  directory.
- The app's shell has a minimal `PATH`. The Projects window loads nvm if `firebase` isn't found; other version
  managers need `firebase` linked into `~/.work42/bin` (see the `firebase-setup` skill). An expired CLI login shows
  the CLI's generic "Failed to list Firebase projects" with a hint to run `firebase login --reauth`.
- The CLI covers only part of each product; the skills say which part. The Console content itself is not
  readable by the agent.
