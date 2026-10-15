---
name: firebase-setup
description: Install and sign in the Firebase CLI and check the Work42 Firebase project list. Use when `firebase` is missing, not signed in, or a Firebase skill or the Projects selection window reports a CLI problem.
---

# Firebase setup

The Firebase widgets show Console pages in a Work42 browser. Everything that talks to Firebase from a terminal (listing projects for the **Projects** selection window, the product skills) uses the Firebase CLI, which has its own sign-in. These are two separate identities: signing in to the Console in a widget does not sign in the CLI, and `firebase login` does not sign in the widget.

## Checks

Run these in order and fix the first one that fails.

1. **CLI installed.** `command -v firebase` prints a path and `firebase --version` prints a version. If not, install it ([official install options](https://firebase.google.com/docs/cli#install_the_firebase_cli)):
   - with Node.js: `npm install -g firebase-tools`
   - or the standalone script (no Node.js needed): `curl -sL https://firebase.tools | bash`
   Then open a new shell and re-check. If the install needs `sudo` or a password prompt, ask the user to run it.
   **Installed, but Work42 can't see it.** The Work42 app is launched from the Dock, so its shell (the one the **Projects** window and widget commands use) has a minimal `PATH` and does not read `~/.zshrc`, where nvm, fnm, Volta and similar tools add Node programs. Symptom: `firebase` works in your terminal but the **Projects** window says Work42 couldn't find the CLI. Check with `env -i HOME="$HOME" /bin/zsh -lc 'command -v firebase'`; if that prints nothing, either:
   - for nvm: nothing to do, the **Projects** window already loads `${NVM_DIR:-$HOME/.nvm}/nvm.sh` when `firebase` isn't on the `PATH` (it uses nvm's default Node version, so make sure `nvm alias default <version>` is set and that version has `firebase-tools`); or
   - for any install: link it into `~/.work42/bin`, which is on the `PATH` for widget and agent shells: `mkdir -p ~/.work42/bin && ln -sf "$(command -v firebase)" ~/.work42/bin/firebase`. A link into a version-specific directory (such as an nvm Node version) breaks when that version is removed; re-run the command after switching Node versions.
2. **CLI signed in.** `firebase login:list` shows at least one account. If not, ask the user to run `firebase login` in a terminal (interactive, opens a browser; `firebase login --no-localhost` when no browser can open on that machine). See [CLI sign-in](https://firebase.google.com/docs/cli/auth). Never ask the user to paste a token, never use `--token` or `FIREBASE_TOKEN`, and never read the CLI's credential files.
3. **Projects visible.** `firebase projects:list --json --non-interactive` exits 0 and prints `{"status":"success","result":[...]}`. This is what the **Projects** window runs (after making `firebase` visible as above). If it fails, the account in step 2 is expired or has no access: ask the user to run `firebase login --reauth`, or `firebase login:add` for another account and `firebase login:use <email>`. An expired login looks like this: `firebase login:list` still shows the account, but `projects:list` exits 2 with only `Failed to list Firebase projects. See firebase-debug.log for more info.`; the log shows the token refresh being rejected.
4. **Projects listed.** Read the shared project list (below). If it is empty or missing, ask the user to add projects with the **Projects** button in any Firebase widget.

## The shared project list

All Firebase widgets and skills share one list of projects, stored by Work42 in `~/.work42/firebase/config.json`; every widget shows a tab per listed project:

```json
{"version":2,"projects":[{"projectId":"my-project","displayName":"My Project"}]}
```

A version 1 file from an older plugin (`{"version":1,"projectId":"…","displayName":"…"}`) is read as a one-project list.

Read it with (it prints one `projectId - name` per line):

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

Only the **Projects** window writes this file, when the user saves the projects they checked from the CLI's list. It never holds credentials. If it is missing, empty or invalid, the widgets say so and keep the Projects button; reading never changes the file.

## Rules

- Pass the project explicitly: `firebase <command> --project "$project"`. Never run `firebase use` and never create or edit a repository's `.firebaserc` to match the list; the project list is global to Work42, the repo's aliases are the repo's.
- Check what the installed CLI supports before relying on a command: `firebase --version`, then `firebase <command> --help`. The commands below were checked against Firebase CLI 15.8.0; newer or older versions may differ.
- Read-only commands are safe to run to answer a question. Anything that changes the cloud project or deletes data needs the user's explicit go-ahead for that specific operation, naming the project ID it will hit.

## References

- [Firebase CLI reference](https://firebase.google.com/docs/cli)
- [CLI sign-in options](https://firebase.google.com/docs/cli/auth)
