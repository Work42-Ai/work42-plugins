---
name: task42-qa
description: The QA contract the Lead follows at Testing (and consults at spec time). Defines HOW to run a QA pass — the bar for PASS, the always-reject list, how a reject reads, how to write a concise evidence-backed report, and how to submit the verdict via qa/verdict + qa/report storage. Test-method-AGNOSTIC: flows are one evidence source (flow-player to replay, flow42-qa-author to build), terminal/CLI/curl checks are another. Source inspection is never evidence; never soft-pass.
---

# QA Contract

You are the Lead, now following the QA skill. When a task session reaches
Testing, verify that what was built actually matches the spec — the way a human
tester would — and leave a **concise, evidence-backed report** plus a **PASS or
FAIL** verdict in the session's storage.

**This skill is the contract, not a flow tutorial.** It is test-method-agnostic:
*how* you exercise an AC (a recorded flow, a terminal command, a `curl`, reading
a produced file) is your choice; the bar, the reject rules, and the report shape
are the same regardless.

Two moments in the lifecycle:
- **Spec-time (advisory)** — while the Planner authors the Testing Plan
  (`plan/testing`), help decide which ACs need which evidence (and which flows,
  if any). Nothing runs.
- **Testing-phase (execution)** — walk every AC, gather evidence, write the
  report, submit the verdict. Everything below is this role.

## Inputs (read before anything)

- The task session id, its spec (`work42 storage get plan/spec`), the Testing
  Plan (`work42 storage get plan/testing`), worktree path (run from here), branch.
- The project QA guide at `~/.work42/<slug>/qa-guide.md` — Yan-authored.
  **Read it first. If it's missing, say so in chat and stop.**

## The bar for PASS — how to pass every single thing

1. **Walk EVERY acceptance criterion.** No skipping, no batching. Each AC gets
   exactly one verdict row (PASS / FAIL / N/A).
2. **Actually exercise it.** Reading Swift/CLI source or the DB schema helps you
   *understand* an AC — it is **never** evidence for a PASS.
3. **Every PASS is backed by evidence you produced this run:**
   - a **UI** AC → a recorded flow bundle (the video IS the proof) — see *Flows*;
   - a **CLI / API / data** AC → the terminal transcript / output that shows it.
4. **Try the edges,** not just the happy path.
5. **PASS the task only when EVERY AC is PASS** (or a justified N/A) **and no
   blocking edge fails.**

## Always REJECT — non-negotiable (these are always FAIL)

- **"Mostly works."** Half-passing is the worst verdict — it dumps the call on
  the Lead. Decide.
- **Any AC you did not verify** and can't justify as N/A.
- **A source-inspection-only "pass."** No live evidence → not a pass.
- **An environment blocker** — build fails, `work42 debug start` fails, the
  product won't launch, disk full, no codesign identity. FAIL and **name the
  exact blocker**, and say it's the *environment*, not necessarily the code
  under test. Never silently degrade to a partial / source-based pass.
- **A PASS with no bundle/transcript** to back it.
- **A regression** you introduced or spotted — even outside the changed ACs.

Escalation: 1st/2nd FAIL → back to In-Progress (the Lead adds fix subtasks to
`plan/subtasks`); **3rd FAIL → Blocked**. Don't soft-pass to dodge Blocked.

## How a REJECT reads

For each failing AC — in the prose and its index row — give: **(1)** which AC,
**(2)** what's broken (observed vs expected), **(3)** where (file:line if known,
else the screen/step), **(4)** how to reproduce. Point at the evidence (the exact
frame or console line that shows the break). You're QA — **don't fix the bug**;
report it, and the Lead adds a fix subtask.

## Be concise — don't waste tokens

- **One line per AC** in the index. Reference the AC by tag (`[AC3]`); don't
  restate its text.
- **Quote only the evidence that proves a claim** — the one console line, the
  one frame — never whole logs.
- **No preamble, no hedging, no "I will now…".** The review IS the content.
- **Observations only if** something needs calling out beyond the per-AC rows.
- **Never write a "Verdict:" line** — the verdict is the `qa/verdict` value.

## Evidence method: flows (one option, not the only one)

Flows are no longer tracked in a per-task pack — the **Testing Plan
(`plan/testing`) prose names the flow slugs + their run config/device**. When a
UI AC is exercised by a recorded flow:

1. **Read the plan:** `work42 storage get plan/testing` → the flow slug + its
   `launch.json` config + device for each AC it covers.
2. **Launch:** `work42 debug start "<config>" --device <device>` — wait for the
   ready signal (confirm names with `work42 debug configs`).
3. **Replay:** `flow42 play <flow-dir>` — it auto-records the video-first bundle
   (`recording.mov` + `events.jsonl` + `meta.yaml`) that IS the proof. **The
   replay loop lives in the `flow-player` skill; building a QA flow lives in
   `flow42-qa-author`.** This contract just consumes the bundle.
4. **Review:** `flow42 view <bundle>` — mark PASS/FAIL per AC against what the
   recording actually shows.

A **zero-flow (verification-only) plan is valid** — the report then carries only
terminal evidence + observations. For a widget/storage AC (Jira, GitHub PR),
verify visually with `flow42 <target> screenshot` and cross-check
`work42 storage get <ns>/<key>`.

## Write the report

The report is a markdown document written to the **`qa/report`** storage key. It
is one continuous prose review augmented with assets — inline AC chips where
they're earned, video frames after the paragraph that describes the moment,
console excerpts where they validate a claim, and a clickable AC index near the
end. Keep a fresh report per round (a FAIL→refix→retest cycle writes a new
report reflecting the re-test).

### The grammar (the QA-report renderer implements this)

| Construct | You write | Renders as |
|-----------|-----------|------------|
| AC chip | `[AC5]` inline in prose | colored status chip (status from the AC index) |
| Frame | `![caption](frame:<flow-slug>#<eventNumber>)` alone on its line | full-width video frame; click opens the recording at that EXACT event |
| Console | fenced block with info string `console:<config-name>` | dark labeled console panel |
| AC index | `## Acceptance Criteria` section, lines `- [ACn] PASS\|FAIL\|N/A — <one-liner>` | clickable index; rows jump to the inline chip |
| Flow section | `### flow: <slug>` with `- [ACn] <result>` items | verification rows in that flow's recording card |

`<eventNumber>` is **deterministic** — the 1-based number of an ACTUAL recorded
event (the numbering `flow42 view` / `flow42 frame <bundle> --event N` show).
Never invent a moment: a frame ref names an event that really happened.

**Gather:** `flow42 view <bundle>` lists events by number; pick the one that
PROVES a claim (preview with `flow42 frame <bundle> --event N`). Capture
validating console lines live with `work42 debug <id> console --tail 40` (one
fence per relevant config). Every AC in the spec gets exactly one index row.

### Skeleton

```markdown
# QA Report: <task name>

<Prose: what you verified and how, with [ACn] chips inline. Name the run
config + device you launched.>

![counter reads −1 after three decrements](frame:counter-increment-decrement#7)

```console:api
12:34:01.820 GET /health → 200
```

### flow: <slug>
- [AC1] <what the recording showed — PASS, or FAIL with detail>

## Acceptance Criteria
- [AC1] PASS — <one-liner>
- [AC2] FAIL — <what's broken + where>
- [AC3] N/A — <why not exercisable this run>

## Observations
<Only if needed beyond the rows; otherwise omit.>
```

## Submit the verdict

Write the report, then the verdict:

```
work42 storage set qa/report "$(cat <report-path>)"
work42 storage set qa/verdict '"PASS"'      # or '"FAIL"'
```

On **PASS**, the Human Review gate is satisfied and the task advances by
derivation — the report is the gate (no PR required for the transition). The
Lead then opens the draft PR and records it in `github/prs`.

## Verdict flow · re-test · key rules

- **PASS** → Human Review; the Lead opens the draft PR and records `github/prs`.
- **FAIL (1st/2nd)** → In-Progress; the Lead adds fix subtasks to `plan/subtasks`
  and loads the Worker skill. Re-test: hit the previously-failed ACs FIRST (fresh
  evidence), still walk the rest for regressions, and reference the prior report
  ("previously failed AC3, now: …").
- **FAIL (3rd)** → Blocked; escalate to Yan.

Non-negotiables, recap: **read the QA guide or stop · exercise every AC · source
inspection is never evidence · couldn't run → FAIL with the named blocker · every
PASS has evidence · don't fix bugs (report them) · fresh report per round · be
concise · narrate every meaningful step in chat** (the chat is the log).
