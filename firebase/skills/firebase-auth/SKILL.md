---
name: firebase-auth
description: Work with Firebase Authentication for a project in the Firebase widgets' shared project list. Use for exporting or importing users with the Firebase CLI, and for deciding where else to manage users, sign-in providers and the Auth emulator.
---

# Firebase Authentication

## Prerequisites

1. `command -v firebase` must print a path. If it prints nothing, or `firebase --version` fails, follow the `firebase-setup` skill.
2. `firebase login:list` must show an account. If not, ask the user to run `firebase login` in a terminal themselves (it is interactive and opens a browser); never ask for or handle tokens. Signing in to the Firebase Console in a Work42 widget does **not** sign in the CLI.
3. The shared project list must contain the project to use. Read it fresh before every operation (never cache it, the user can change it at any time in any Firebase widget); it prints one `projectId - name` per line:

```sh
cfg="$HOME/.work42/firebase/config.json"
python3 - "$cfg" <<'PY' || echo "No Firebase projects listed"
import json, sys
d = json.load(open(sys.argv[1]))
if d["version"] == 1:
    projects = [d]
elif d["version"] == 2:
    projects = d["projects"]
else:
    sys.exit("unsupported config version %s" % d["version"])
if not projects:
    sys.exit("empty project list")
for p in projects:
    print(p["projectId"].strip(), "-", p.get("displayName", ""))
PY
```

   Choose the project from that list. Exactly one: use it. Several: use the one the user named, otherwise ask which. None (no file, an empty list, or the command above fails): ask the user to add projects with the **Projects** button in any Firebase widget. Only use listed projects; if the user names one that isn't listed, ask them to add it first. Then set `project` to the chosen project ID and pass it explicitly. Do not write `~/.work42/firebase/config.json` yourself.

If any step fails and you cannot fix it, follow the `firebase-setup` skill.

## Rules

- Pass the project explicitly: `firebase <command> --project "$project"`. Never run `firebase use` and never create or edit a repository's `.firebaserc` to match the list; the project list is global to Work42, the repo's aliases are the repo's.
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
