---
name: firebase-analytics
description: Work with Google Analytics for Firebase for a project in the Firebase widgets' shared project list. Use when the user asks about analytics events, audiences, conversions, DebugView, BigQuery export or reporting data, and to explain that the Firebase CLI has no analytics reporting commands.
---

# Firebase Analytics

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

## The Firebase CLI has no Analytics commands

`firebase --help` lists no analytics command: you cannot read reports, events, audiences or user counts from the CLI. Do not try `firebase analytics:...`, and do not invent flags for another command. Use these instead.

- **See the data:** the **Firebase Analytics** widget shows the Console's Analytics pages for the chosen project (dashboard, events, audiences, DebugView). Describe what to open and let the user read it; you cannot scrape the widget's browser.
- **Query the data in code or SQL:** link the project to BigQuery in the Console (Project settings, Integrations) and query the exported `events_*` tables ([BigQuery export](https://firebase.google.com/docs/projects/bigquery-export)). Exports only contain data from after linking.
- **Reporting API:** the [Google Analytics Data API](https://developers.google.com/analytics/devguides/reporting/data/v1) reads reports for a GA4 **property**. The property ID is not the Firebase project ID; the user finds it in Analytics settings for the project. Credentials for it are the user's to set up; do not borrow the CLI's or the browser's.
- **Instrument an app:** events are logged by the SDK in the app ([getting started](https://firebase.google.com/docs/analytics/get-started)); verify them live with DebugView in the Console.

## Use the CLI only for context

`firebase apps:list --project "$project"` (read-only) lists the project's registered apps, useful to tell the user which app IDs to look for in the Console.

## References

- [Google Analytics for Firebase](https://firebase.google.com/docs/analytics)
- [Get started](https://firebase.google.com/docs/analytics/get-started)
- [BigQuery export](https://firebase.google.com/docs/projects/bigquery-export)
- [Analytics Data API](https://developers.google.com/analytics/devguides/reporting/data/v1)
