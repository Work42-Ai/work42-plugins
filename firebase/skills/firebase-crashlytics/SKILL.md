---
name: firebase-crashlytics
description: Work with Firebase Crashlytics for the project selected in the Firebase widgets. Use for uploading native symbols or Android mapping files with the Firebase CLI, and to explain where SDK setup and crash triage happen.
---

# Firebase Crashlytics

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

## What the Firebase CLI can do for Crashlytics

Three commands, all about making stack traces readable (the `crashlytics:` group in `firebase --help`):

- `firebase crashlytics:symbols:upload <symbolFiles...> --app <appID> --project "$project"` uploads native (NDK/C++) symbols. `--generator breakpad|csym` picks the generator; `--dry-run` generates the symbols without uploading, which is the safe way to check a setup ([NDK reports](https://firebase.google.com/docs/crashlytics/ndk-reports)).
- `firebase crashlytics:mappingfile:generateid --resource-file <path>` writes a mapping file ID into an Android resource XML file, which is built into the app.
- `firebase crashlytics:mappingfile:upload <mappingFile> --app <appID> --resource-file <path> --project "$project"` uploads a ProGuard/R8 mapping file ([deobfuscated reports](https://firebase.google.com/docs/crashlytics/get-deobfuscated-reports)).

Find the app ID with the read-only `firebase apps:list --project "$project"` and confirm it with the user, because a wrong app ID uploads to the wrong app. Uploads (not `--dry-run`) change the cloud project, so show the exact command and wait for approval. Check `firebase crashlytics:symbols:upload --help` first: flags differ between CLI versions.

## What it cannot do

There is no CLI command to list crashes or issues, read stack traces, see affected users, or change alerts. Do not invent one.

- **Triage crashes:** use the **Firebase Crashlytics** widget (Console Issues, Dashboard). Describe where to look; you cannot scrape the widget's browser.
- **Add Crashlytics to an app:** this is SDK and build-config work in the app's code, not a CLI action ([get started](https://firebase.google.com/docs/crashlytics/get-started)).
- **Query crash data in bulk:** enable BigQuery export in the Console, then query the exported tables ([BigQuery export](https://firebase.google.com/docs/projects/bigquery-export)).

## References

- [Crashlytics](https://firebase.google.com/docs/crashlytics)
- [Get started](https://firebase.google.com/docs/crashlytics/get-started)
- [Deobfuscated reports (Android)](https://firebase.google.com/docs/crashlytics/get-deobfuscated-reports)
- [NDK reports](https://firebase.google.com/docs/crashlytics/ndk-reports)
- [Firebase CLI reference](https://firebase.google.com/docs/cli)
