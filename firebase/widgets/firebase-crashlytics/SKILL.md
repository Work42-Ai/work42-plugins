---
name: widget-firebase-crashlytics
description: How the Firebase Crashlytics widget works. It shows the Firebase Console page for crash issues and stability data of the project chosen with Set Project; hand off to the firebase-crashlytics skill for CLI work.
---

# Firebase Crashlytics widget

## Prerequisites

1. This widget needs no CLI to display the Console, but **Set Project** and the CLI work do: `command -v firebase` must print a path, and `firebase login:list` must show an account. If not, follow the `firebase-setup` skill.
2. The widget's Console page needs a Google sign-in inside the widget. That is separate from the CLI login. Ask the user to sign in in the widget themselves; never ask for their password.

## Behavior

- The toolbar above the page shows the selected project and a **Set Project** button. The page below is the live Firebase Console at `https://console.firebase.google.com/project/<projectId>/crashlytics`.
- **Set Project** runs `firebase projects:list --json --non-interactive`, lists the projects (searchable), and on confirm saves the choice to `~/.work42/firebase/config.json`. The project is **global**: every Firebase widget in every window switches to it within about two seconds. There is no project per widget or per session.
- With no valid selection the widget asks the user to choose one instead of opening a page. A broken config file is reported, never overwritten, until the user picks a project.
- Navigating inside the Console is left alone; the page only reloads when the selected project changes.

## Reading the selection

```sh
cfg="$HOME/.work42/firebase/config.json"
project="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"]==1; p=d["projectId"].strip(); assert p; print(p)' "$cfg")" \
  || echo "No valid Firebase project selected"
```

Read it before each operation; do not cache it. To change it, ask the user to click **Set Project**.

For CLI and API work on this product, follow the `firebase-crashlytics` skill. The Console in the widget is not readable by you; ask the user what they see.
