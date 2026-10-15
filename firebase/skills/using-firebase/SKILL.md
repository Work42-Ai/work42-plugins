---
name: using-firebase
description: Index of the Firebase plugin. Use when the user mentions Firebase, a Firebase project, or the Firebase Authentication, Analytics, Firestore or Crashlytics widgets, to find the right skill and the shared list of Firebase projects.
---

# Using Firebase in Work42

The Firebase plugin adds four independent widgets, each showing one product's live Firebase Console pages, one browser tab per project in a **list shared by all of them**:

| Widget | Skill | CLI coverage |
|---|---|---|
| Firebase Authentication | `firebase-auth` | export and import of users only |
| Firebase Analytics | `firebase-analytics` | none: Console, BigQuery export, Analytics APIs |
| Firebase Firestore | `firebase-firestore` | databases, indexes, backups, bulk delete, emulator, deploy |
| Firebase Crashlytics | `firebase-crashlytics` | symbol and mapping-file upload only |

Setup, installing the CLI and signing in: `firebase-setup`.

## The project list

Every widget has a small floating **Projects** button at the bottom right (also the `+` in its tab bar). It runs `firebase projects:list --json --non-interactive`, lets the user check the projects to keep, and saves them to `~/.work42/firebase/config.json` (`{"version":2,"projects":[{"projectId":"…","displayName":"…"}]}`; a version 1 file is read as one project). All open Firebase widgets, in every window, show a tab per listed project, each on its own product page. `×` on a tab only hides it in that widget. There is no per-widget or per-session list. Clicking a Firebase Console link for a product opens that product's widget on the project's tab; a link to an unlisted project opens a temporary tab that is not saved.

Before any Firebase operation, read the list fresh (it can change between two of your commands); it prints one `projectId - name` per line:

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

## Ground rules

- Pass the project explicitly with `--project "$project"`. Never run `firebase use` or edit `.firebaserc` to follow the list.
- Signing in to the Console inside a widget and signing in the Firebase CLI are different; either can be missing independently.
- The CLI covers only part of what the Console shows. Each product skill says exactly which part, and what to do for the rest. Do not invent commands: check `firebase <command> --help` first.
- Anything that changes the cloud project or deletes data needs the user's explicit approval for that operation, naming the project ID.

## References

- [Firebase CLI reference](https://firebase.google.com/docs/cli)
