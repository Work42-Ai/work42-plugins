---
name: linear42-qa
description: QA for a linear42 task at Testing — execute the testing plan against the real build (launched with work42 debug start), prove every acceptance criterion with recordings or screenshots, publish the QA report as the issue's "<KEY> QA Report" Linear document with the media uploaded, then write qa/report and qa/verdict. Never soft-pass; when blocked, stop and ask Yan.
---

# QA (linear42)

You are the Lead, now following the QA skill. **Your job: execute the testing plan against the real build, prove each acceptance criterion with what you saw, and publish the result.** Read the testing plan like a script and follow it in order; don't swap in a test of your own. You report bugs, you never fix them.

## Inputs

- The spec and testing plan: for each key in `work42 storage get linear/issue_keys`,
  `linear document view "$(work42 storage get linear/issues/<KEY>/spec_doc | jq -r .slug)" --raw` (and `testing_doc`). Read only; never feed `--raw` output back into an update.
- The project QA guide `~/.work42/<slug>/qa-guide.md`. Read it first.
- The session worktree, on the task branch.

## Run the plan

1. **Launch.** `work42 debug configs`, then `work42 debug start "<config>"`; wait until it is ready.
2. **Prove each step with a visual.**
   - Browser, iOS or Android flow: `work42 device start --device <d>`, drive it (`work42 device actions` lists the verbs), `work42 device stop`. The stop prints the bundle path; its `recording.mov` is the video and `events.jsonl` has step times, so a frame is `ffmpeg -ss <t> -i <bundle>/recording.mov -frames:v 1 <out>.png`. If the plan names a flow and variant, follow it with the `flow-player` skill.
   - No device fits (the macOS app, a CLI): `screencapture -v` or screenshots.
   - Visual proof is strongly encouraged, not a hard gate: an AC without one says `no visual proof: <why>`.
3. **Keep the proof.** Put every file in `~/.work42/run/sessions/$WORK42_SESSION_ID/qa/round-<n>/` (`mkdir -p` it; `n` is 1 more than the folders already there; copy a recording with `ffmpeg -i <src> -c copy <dst>`). The Lead attaches this folder to the PR.
4. **Try the edges**, not only the happy path.

## The bar

- Every AC gets one row: PASS, FAIL or N/A with a reason. Every row was exercised this run.
- Source inspection is never evidence. "Mostly works" is not a verdict. A regression anywhere is a FAIL.
- **PASS only when every AC is PASS** (or a justified N/A).
- **Stuck?** A missing config, an app that won't run, a device you can't drive: stop, say in chat exactly what you need, and wait for Yan. Don't work around it and don't record a FAIL for it.
- A FAIL names the AC, observed vs expected, where, and how to reproduce, with the evidence. 3rd FAIL: escalate to Yan.

## The report

One continuous, concise Markdown body: one line per AC (`[AC3]` tags, never restating the AC), the media inline, nothing else unless it earns its place. Reference every file by absolute path (`![AC3 approved](/Users/.../round-1/ac3.png)`, videos the same way); `publish-doc.py` uploads them to Linear.

```markdown
# QA Report: <task name>
Round <n> · <config> on <device>

- [AC1] PASS — <one line>
![AC1 plan approved](/abs/path/round-1/ac1.png)
- [AC2] FAIL — <what's broken, where, how to reproduce>
![AC2 recording](/abs/path/round-1/ac2.mov)
- [AC3] N/A — <why>

## Previous rounds
<one line per earlier round: its date and its failing ACs>
```

## Publish and record

The Testing stage blocks file edits and Linear issue writes: pipe the body on stdin; the QA document is the only thing you write to Linear.

```bash
.claude/skills/linear42-general/publish-doc.py --issue <KEY> --kind qa --file - [--slug <slug>] <<'MD'
…the report…
MD
```

It creates (or with `--slug` rewrites) `<KEY> QA Report` and prints `{"slug","url"}`. Do it once per attached issue. Round 1 creates; later rounds rewrite the same document with the `--slug` read from the `qa/docs` storage key, keeping earlier rounds as the short "Previous rounds" section.

Then record the signals, `qa/verdict` last:

- `qa/docs`: a JSON object `{"<KEY>": {"slug": "...", "url": "..."}}` with an entry per issue. Build it with `jq -nc --arg`.
- `qa/report`: the JSON string of the first issue's document URL.
- `qa/verdict`: `"PASS"` or `"FAIL"`.

Each is written with `work42 storage set <key> '<json>'`.

PASS opens the Human Review gate (the session says so; the Lead runs the transition). FAIL goes back to In-Progress, where the Lead creates fix sub-issues. On a re-test, check the previously failed ACs first with fresh evidence, still walk the rest for regressions, and say what changed.

Narrate every meaningful step in chat.
