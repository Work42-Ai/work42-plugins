---
name: widget-firebase-crashlytics
description: How the Firebase Crashlytics widget works. It shows one browser tab per project in the shared Firebase project list, each on the Firebase Console page for crash issues and stability data; hand off to the firebase-crashlytics skill for CLI work.
---

# Firebase Crashlytics widget

## Prerequisites

1. This widget needs no CLI to display the Console, but the **Projects** window and the CLI work do: `command -v firebase` must print a path, and `firebase login:list` must show an account. If not, follow the `firebase-setup` skill.
2. The widget's Console pages need a Google sign-in inside the widget. That is separate from the CLI login. Ask the user to sign in in the widget themselves; never ask for their password.

## Behavior

- The widget is a browser with one tab per project in the shared list, titled with the project's name. Each tab opens the live Firebase Console at `https://console.firebase.google.com/project/<projectId>/crashlytics`. With one project there is a single tab and no tab bar.
- A small floating **Projects** button (Firebase flame, bottom right, transparent glass; tooltip "Open Projects Selection") and the `+` in the tab bar open the selection window. It runs `firebase projects:list --json --non-interactive`, lists the projects (searchable, with refresh), and on **Save** writes the checked projects to `~/.work42/firebase/config.json`. The list is **global**: every Firebase widget in every window shows the same tabs within about two seconds. There is no list per widget or per session.
- `×` on a tab hides that project in this widget only; it comes back when the shared list changes or Work42 restarts. It never edits the shared list.
- With no projects the widget asks the user to choose some; a broken config file is reported, never overwritten, until the user saves a list.
- Clicking a Firebase Console link for this product (`…/project/<projectId>/crashlytics…`) opens this widget on that project's tab, showing the exact page. A link to a project that isn't listed opens a temporary tab in this widget only; it is never saved. Links for other Firebase products open in the Browser.
- Navigating inside the Console is left alone; a tab only reloads when it is opened from a link or the list changes.

## Reading the project list

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

Read it before each operation; do not cache it.

Choose the project from that list. Exactly one: use it. Several: use the one the user named, otherwise ask which. None (no file, an empty list, or the command above fails): ask the user to add projects with the **Projects** button in any Firebase widget. Only use listed projects; if the user names one that isn't listed, ask them to add it first. Then set `project` to the chosen project ID and pass it explicitly. Do not write `~/.work42/firebase/config.json` yourself.

For CLI and API work on this product, follow the `firebase-crashlytics` skill. The Console in the widget is not readable by you; ask the user what they see.
