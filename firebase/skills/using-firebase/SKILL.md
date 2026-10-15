---
name: using-firebase
description: Index of the Firebase plugin. Use when the user mentions Firebase, a Firebase project, or the Firebase Authentication, Analytics, Firestore or Crashlytics widgets, to find the right skill and the shared project selection.
---

# Using Firebase in Work42

The Firebase plugin adds four independent widgets, each showing one product's live Firebase Console page for the **one project shared by all of them**:

| Widget | Skill | CLI coverage |
|---|---|---|
| Firebase Authentication | `firebase-auth` | export and import of users only |
| Firebase Analytics | `firebase-analytics` | none: Console, BigQuery export, Analytics APIs |
| Firebase Firestore | `firebase-firestore` | databases, indexes, backups, bulk delete, emulator, deploy |
| Firebase Crashlytics | `firebase-crashlytics` | symbol and mapping-file upload only |

Setup, installing the CLI and signing in: `firebase-setup`.

## The project selection

Every widget has a **Set Project** button. It runs `firebase projects:list --json --non-interactive`, lets the user pick, and saves the choice to `~/.work42/firebase/config.json`. All open Firebase widgets, in every window, switch to it. There is no per-widget or per-session project.

Before any Firebase operation, read the file fresh (it can change between two of your commands):

```sh
cfg="$HOME/.work42/firebase/config.json"
project="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"]==1; p=d["projectId"].strip(); assert p; print(p)' "$cfg")" \
  || echo "No valid Firebase project selected"
```

If there is no valid selection, ask the user to click **Set Project** in a Firebase widget. Do not create the file yourself and do not guess a project.

## Ground rules

- Pass the project explicitly with `--project "$project"`. Never run `firebase use` or edit `.firebaserc` to follow the selection.
- Signing in to the Console inside a widget and signing in the Firebase CLI are different; either can be missing independently.
- The CLI covers only part of what the Console shows. Each product skill says exactly which part, and what to do for the rest. Do not invent commands: check `firebase <command> --help` first.
- Anything that changes the cloud project or deletes data needs the user's explicit approval for that operation, naming the project ID.

## References

- [Firebase CLI reference](https://firebase.google.com/docs/cli)
