---
name: firebase-auth
description: Work with Firebase Authentication for the project selected in the Firebase widgets. Use for exporting or importing users with the Firebase CLI, and for deciding where else to manage users, sign-in providers and the Auth emulator.
---

# Firebase Authentication

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

## What the Firebase CLI can do for Authentication

Only two commands exist, both for bulk user data ([docs](https://firebase.google.com/docs/auth/admin/import-users)):

- **Export users** (read-only against the cloud; writes a local file):
  `firebase auth:export users.json --format json --project "$project"` (`csv` also works; the extension of the file name wins over `--format`).
  The file contains personal data and password hashes. Write it to a path the user names or a temp directory, never inside a repository that could be committed, and delete it when the task is done.
- **Import users** (changes the project): `firebase auth:import users.json --project "$project"`. Password hashes need `--hash-algo` and the matching options (`--hash-key`, `--salt-separator`, `--rounds`, and so on, see `firebase auth:import --help`). Confirm the file, the project ID and the effect with the user before running it.

## What it cannot do

There is no CLI command to list, create, disable or delete a single user, change sign-in providers, or edit templates and settings. For those:

- Look and click in the **Firebase Authentication** widget (Console, Users and Sign-in method tabs).
- In code, use an Admin SDK ([Authentication docs](https://firebase.google.com/docs/auth)) with credentials the user has set up for that code; do not extract credentials from the CLI or the widget's browser.

## Local testing

`firebase emulators:start --only auth` starts the Authentication emulator locally, using the repository's `firebase.json` ([Emulator Suite](https://firebase.google.com/docs/emulator-suite)). It never touches the cloud project's users.

## References

- [Authentication](https://firebase.google.com/docs/auth)
- [Import and export users](https://firebase.google.com/docs/auth/admin/import-users)
- [Firebase CLI reference](https://firebase.google.com/docs/cli)
