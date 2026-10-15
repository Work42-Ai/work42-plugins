---
name: firebase-firestore
description: Work with Cloud Firestore for the project selected in the Firebase widgets. Use for the Firebase CLI's database, index, backup, emulator and deploy workflows, and to decide where reading and writing documents belongs.
---

# Cloud Firestore

## Prerequisites

1. `command -v firebase` must print a path. If it prints nothing, or `firebase --version` fails, follow the `firebase-setup` skill.
2. `firebase login:list` must show an account. If not, ask the user to run `firebase login` in a terminal themselves (it is interactive and opens a browser); never ask for or handle tokens. Signing in to the Firebase Console in a Work42 widget does **not** sign in the CLI.
3. The shared project selection must exist and be valid. Read it fresh before every operation (never cache it, the user can change it at any time in any Firebase widget):

```sh
cfg="$HOME/.work42/firebase/config.json"
project="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"]==1; p=d["projectId"].strip(); assert p; print(p)' "$cfg")" \
  || echo "No valid Firebase project selected"
```

   If that fails, ask the user to click **Set Project** in any Firebase widget. Do not write `~/.work42/firebase/config.json` yourself and do not guess a project.

If any step fails and you cannot fix it, follow the `firebase-setup` skill.

## Rules

- Pass the project explicitly: `firebase <command> --project "$project"`. Never run `firebase use` and never create or edit a repository's `.firebaserc` to match the selection; the selection is global to Work42, the repo's aliases are the repo's.
- Check what the installed CLI supports before relying on a command: `firebase --version`, then `firebase <command> --help`. The commands below were checked against Firebase CLI 15.8.0; newer or older versions may differ.
- Read-only commands are safe to run to answer a question. Anything that changes the cloud project or deletes data needs the user's explicit go-ahead for that specific operation, naming the project ID it will hit.

## Read-only commands (safe to run)

- `firebase firestore:databases:list --project "$project"` and `firebase firestore:databases:get [database] --project "$project"`: which databases exist and their settings.
- `firebase firestore:indexes --project "$project"` (add `--database <id>` for a non-default database, `--pretty` for a readable list): the deployed indexes as the JSON that `firestore.indexes.json` uses.
- `firebase firestore:locations --project "$project"`: locations a new database could use.
- `firebase firestore:operations:list [--database <id>] [--limit <n>]` / `firestore:operations:describe <name>`: status of long-running admin operations.
- `firebase firestore:backups:list [--location <locationId>]` and `firebase firestore:backups:schedules:list [--database <id>]`: backups and backup schedules.

## Commands that change or delete things (ask first, name the project ID)

`firestore:delete`, `firestore:bulkdelete`, `firestore:databases:create|update|delete|restore|clone`, `firestore:backups:schedules:create|update|delete`, `firestore:backups:delete`, `firestore:operations:cancel`. `firestore:delete -r` removes a path and everything under it with no undo. Always show the exact command and wait for the user's go-ahead. Never run these to demonstrate that a command works.

## Rules and indexes live in the repository

The CLI does not print the deployed security rules. They are files in the repo (see `firebase.json`), deployed with `firebase deploy --only firestore:rules,firestore:indexes --project "$project"`. A deploy overwrites what is in the cloud project, so only run it on request, from the repository that owns those files. Use `firebase firestore:indexes` to compare the cloud's indexes with `firestore.indexes.json`.

## Reading and writing documents

The CLI has no command to read or write documents (only to delete them). For that:

- Browse and edit in the **Firebase Firestore** widget (Console Data tab).
- In code, use a client or Admin SDK or the REST API with credentials the user has set up for that code ([Firestore docs](https://firebase.google.com/docs/firestore)); do not take credentials from the CLI or the widget's browser.

## Local testing

`firebase emulators:start --only firestore` runs the Firestore emulator from the repository's `firebase.json`; `--import <dir>` loads saved data and `--export-on-exit <dir>` saves it ([Emulator Suite](https://firebase.google.com/docs/emulator-suite)). It does not touch the cloud project.

## References

- [Cloud Firestore](https://firebase.google.com/docs/firestore)
- [Indexes](https://firebase.google.com/docs/firestore/query-data/indexing)
- [Security rules](https://firebase.google.com/docs/firestore/security/get-started)
- [Deleting data](https://firebase.google.com/docs/firestore/manage-data/delete-data)
- [Firebase CLI reference](https://firebase.google.com/docs/cli)
