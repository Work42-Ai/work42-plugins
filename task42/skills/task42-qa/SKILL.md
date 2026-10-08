---
name: task42-qa
description: QA for a task42 task at Testing — execute the testing plan against the real build (launched with work42 debug start), prove every acceptance criterion with recordings or screenshots, write the report to qa/report and the verdict to qa/verdict. Never soft-pass; when blocked, stop and ask Yan.
---

# QA (task42)

You are the Lead, now following the QA skill. **Your job: execute the testing plan against the real build, prove each acceptance criterion with what you saw, and report it.** Read the plan (`work42 storage get plan/testing`) like a script and follow it in order; don't swap in a test of your own. You report bugs, you never fix them.

## Inputs

- The spec (`plan/spec`) and testing plan (`plan/testing`), the session worktree and branch.
- The project QA guide `~/.work42/<slug>/qa-guide.md`. Read it first.

## Run the plan

1. **Launch.** `work42 debug configs`, then `work42 debug start "<config>"`; wait until it is ready.
2. **Prove each step with a visual.**
   - Browser, iOS or Android flow: `work42 device start --device <d>`, drive it (`work42 device actions` lists the verbs), `work42 device stop`. The stop prints the bundle path; `<bundle>/recording.mov` is the video and `events.jsonl` has the numbered steps and their times. If the plan names a flow and variant (`flow`, `variant`, `config`, `covers`; never infer a variant), follow it with the `flow-player` skill.
   - No device fits (the macOS app, a CLI): `screencapture -v` or screenshots.
   - Visual proof is strongly encouraged, not a hard gate: an AC without one says `no visual proof: <why>`.
3. **Keep the proof.** Put every file in `~/.work42/run/sessions/$WORK42_SESSION_ID/qa/round-<n>/` (`mkdir -p` it; `n` is 1 more than the folders already there; copy a recording with `ffmpeg -i <src> -c copy <dst>`; a frame is `ffmpeg -ss <t> -i <bundle>/recording.mov -frames:v 1 <out>.png`). The Lead attaches this folder to the PR.
4. **Try the edges**, not only the happy path. Capture console lines with `work42 debug console --tail 40`.

## The bar

- Every AC gets one row: PASS, FAIL or N/A with a reason. Every row was exercised this run.
- Source inspection is never evidence. "Mostly works" is not a verdict. A regression anywhere is a FAIL.
- **PASS only when every AC is PASS** (or a justified N/A).
- **Stuck?** A missing config, an app that won't run, a device you can't drive: stop, say in chat exactly what you need, and wait for Yan. Don't work around it and don't record a FAIL for it.
- A FAIL names the AC, observed vs expected, where (file:line or screen/step), and how to reproduce, with the evidence. 3rd FAIL: escalate to Yan.

## The report

Concise Markdown in `qa/report`: one line per AC (`[AC3]` tags, never restating the AC), only the evidence that proves a claim, no "Verdict:" line (the verdict is `qa/verdict`). A fresh report each round.

| You write | Renders as |
|-----------|-----------|
| `[AC5]` inline | status chip |
| `![caption](frame:<recording-slug>#<eventNumber>)` alone on a line | video frame; click opens the Work42 recording at that exact event. The slug is the bundle folder name; the number is a real event of that recording. |
| fenced block `console:<config-name>` | console panel |
| `## Acceptance Criteria` with `- [ACn] PASS\|FAIL\|N/A — <one line>` | clickable index |
| `### flow: <recording-slug>` with `- [ACn] <result>` | rows in the recording card |

```markdown
# QA Report: <task name>
<Prose with [ACn] chips; the config and device you ran.>
![counter reads −1](frame:agent-web-1760000000#7)
## Acceptance Criteria
- [AC1] PASS — <one line>
- [AC2] FAIL — <what's broken, where>
## Media
- ~/.work42/run/sessions/<id>/qa/round-1/ac2.mov
```

## Submit

Write the report to `qa/report` as a JSON string (pipe the markdown through `jq -Rs .` from a quoted heredoc, since Testing blocks file edits), then `qa/verdict` as `"PASS"` or `"FAIL"`, last. Each is `work42 storage set <key> '<json>'`.

PASS opens the Human Review gate (the session says so; the Lead runs the transition and opens the PR). FAIL goes back to In-Progress, where the Lead adds fix subtasks. On a re-test, check the previously failed ACs first with fresh evidence, still walk the rest for regressions, and say what changed.

Narrate every meaningful step in chat.
