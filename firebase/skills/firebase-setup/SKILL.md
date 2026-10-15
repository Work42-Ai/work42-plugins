---
name: firebase-setup
description: Install and sign in the Firebase CLI and check the Work42 Firebase project selection. Use when `firebase` is missing, not signed in, or a Firebase skill or the Set Project button reports a CLI problem.
---

# Firebase setup

The Firebase widgets show Console pages in a Work42 browser. Everything that talks to Firebase from a terminal (listing projects for **Set Project**, the product skills) uses the Firebase CLI, which has its own sign-in. These are two separate identities: signing in to the Console in a widget does not sign in the CLI, and `firebase login` does not sign in the widget.

## Checks

Run these in order and fix the first one that fails.

1. **CLI installed.** `command -v firebase` prints a path and `firebase --version` prints a version. If not, install it ([official install options](https://firebase.google.com/docs/cli#install_the_firebase_cli)):
   - with Node.js: `npm install -g firebase-tools`
   - or the standalone script (no Node.js needed): `curl -sL https://firebase.tools | bash`
   Then open a new shell and re-check. If the install needs `sudo` or a password prompt, ask the user to run it.
2. **CLI signed in.** `firebase login:list` shows at least one account. If not, ask the user to run `firebase login` in a terminal (interactive, opens a browser; `firebase login --no-localhost` when no browser can open on that machine). See [CLI sign-in](https://firebase.google.com/docs/cli/auth). Never ask the user to paste a token, never use `--token` or `FIREBASE_TOKEN`, and never read the CLI's credential files.
3. **Projects visible.** `firebase projects:list --json --non-interactive` exits 0 and prints `{"status":"success","result":[...]}`. This is exactly what **Set Project** runs. If it fails with an authentication message, the account in step 2 is expired or has no access: ask the user to run `firebase login --reauth`, or `firebase login:add` for another account and `firebase login:use <email>`.
4. **Project selected.** Read the shared selection (below). If it is missing, ask the user to click **Set Project** in any Firebase widget.

## The shared selection

All Firebase widgets and skills use one project, stored by Work42 in `~/.work42/firebase/config.json`:

```json
{"version":1,"projectId":"my-project","displayName":"My Project"}
```

Read it with:

```sh
cfg="$HOME/.work42/firebase/config.json"
project="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"]==1; p=d["projectId"].strip(); assert p; print(p)' "$cfg")" \
  || echo "No valid Firebase project selected"
```

Only the **Set Project** button writes this file, after the user confirms a project the CLI listed. It never holds credentials. If it is missing or invalid, the widgets show a prompt to choose a project; reading never changes the file.

## Rules

- Pass the project explicitly: `firebase <command> --project "$project"`. Never run `firebase use` and never create or edit a repository's `.firebaserc` to match the selection; the selection is global to Work42, the repo's aliases are the repo's.
- Check what the installed CLI supports before relying on a command: `firebase --version`, then `firebase <command> --help`. The commands below were checked against Firebase CLI 15.8.0; newer or older versions may differ.
- Read-only commands are safe to run to answer a question. Anything that changes the cloud project or deletes data needs the user's explicit go-ahead for that specific operation, naming the project ID it will hit.

## References

- [Firebase CLI reference](https://firebase.google.com/docs/cli)
- [CLI sign-in options](https://firebase.google.com/docs/cli/auth)
