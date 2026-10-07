---
name: linear42-qa
description: The QA contract the Lead follows at Testing (and consults at spec time) for a linear42 task. Defines the bar for PASS, the always-reject list, how a reject reads, how to write a concise evidence-backed report, and how to publish it as a Linear comment plus the qa/verdict + qa/report storage signals. Test-method-agnostic: flows are one evidence source, terminal/CLI/curl checks another. Source inspection is never evidence; never soft-pass.
---

# QA Contract (Linear-native)

You are the Lead, now following the QA skill. When a session reaches Testing, verify that
what was built actually matches the spec, the way a human tester would, and leave a
**concise, evidence-backed report** (a Linear comment) plus a **PASS or FAIL** verdict.

This skill is the contract, not a flow tutorial. *How* you exercise an AC — a recorded flow,
a terminal command, a `curl`, a produced file — is your choice; the bar, the reject rules and
the report shape are the same.

Two moments: **spec time (advisory)** — help the Planner decide which ACs need which evidence
for the testing-plan document (nothing runs); **Testing phase (execution)** — everything below.

## Inputs (read before anything)

- The spec and testing plan, from Linear:
  `linear document view "$(work42 storage get linear/spec_doc | jq -r .slug)" --raw` and the
  same for `linear/testing_doc`. The bound issue: `linear issue view <KEY>`.
- The worktree (run from here) and branch.
- The project QA guide at `~/.work42/<slug>/qa-guide.md` — Yan-authored. **Read it first. If it
  is missing, say so in chat and stop.**

## The bar for PASS

1. **Walk EVERY acceptance criterion** — one verdict row each (PASS / FAIL / N/A).
2. **Actually exercise it.** Reading source helps you understand an AC; it is **never** evidence.
3. **Every PASS is backed by evidence you produced this run:** a UI AC → a recording or
   screenshot; a CLI/API/data AC → the terminal output that shows it.
4. **Try the edges**, not just the happy path.
5. **PASS the task only when EVERY AC is PASS** (or a justified N/A) and no blocking edge fails.

## Always REJECT (these are always FAIL)

- **"Mostly works."** Half-passing is the worst verdict. Decide.
- **Any AC you did not verify** and can't justify as N/A.
- **A source-inspection-only "pass."**
- **An environment blocker** — build fails, product won't launch, disk full. FAIL and **name the
  exact blocker**, and say it's the environment, not necessarily the code under test.
- **A PASS with no evidence** behind it.
- **A regression** you introduced or spotted, even outside the changed ACs.

Escalation: 1st/2nd FAIL → back to In-Progress (the Lead creates fix sub-issues); **3rd FAIL →
blocked.** Don't soft-pass to dodge it.

## How a REJECT reads

For each failing AC: **(1)** which AC, **(2)** what's broken (observed vs expected), **(3)**
where (file:line if known, else the screen/step), **(4)** how to reproduce. Point at the
evidence. You're QA — **don't fix the bug**; report it.

## Be concise

One line per AC in the index, referenced by tag (`[AC3]`) without restating it. Quote only the
evidence that proves a claim. No preamble, no hedging. **No "Verdict:" line in the report** —
the verdict is the `qa/verdict` value.

## Evidence method: optional flow guidance

Flow42 is optional. The testing-plan document names each requested definition with separate
`flow`, `variant`, `config` and `covers` fields. Never infer a variant. For a UI AC covered by a
saved definition: collect those fields (stop and ask if flow or variant is missing); launch with
`work42 debug start "<config>"` (confirm names with `work42 debug configs`); invoke the global
`flow-player` skill with the flow and variant (it brackets device actions with
`work42 device start/stop` and retains a normal Work42 recording); then judge each AC against
what the recording actually shows. A zero-flow, verification-only plan is valid and uses
terminal/manual evidence. If an approved plan *requires* a flow that is unavailable, FAIL
naming that blocker instead of reducing coverage. For widget/storage ACs use a Work42 device
screenshot and cross-check `work42 storage get <ns>/<key>`.

## Testing linear42 itself (or anything needing Linear fixtures)

When the task under test needs real Linear issues, create **throwaway** ones in the configured
team, titled `[linear42 QA] <what it's for>`:
`linear issue create --team "$(jq -r .default_team ~/.config/linear42/config.json)" --title "[linear42 QA] …"`.
List every one you created at the end of the report so Yan can clean them up. Never use real work
issues as fixtures.

## Write and publish the report

The report is Markdown posted to the **issue as a comment** — Linear renders it, and images you
attach render inline. Shape:

```markdown
# QA Report: <task name>

<Prose: what you verified and how, with [ACn] tags inline. Name the run config and device.>

```console
<only the lines that prove a claim>
```

## Acceptance Criteria
- [AC1] PASS — <one-liner>
- [AC2] FAIL — <what's broken + where>
- [AC3] N/A — <why not exercisable this run>

## Observations
<only if needed beyond the rows>
```

Publish it with the evidence attached (screenshots, recordings exported to files), then record
the signals. The Testing stage blocks file edits, so pipe the report on stdin rather than writing
a temp file:

```bash
linear issue comment add <KEY> --body-file - -a <evidence-file> -a <evidence-file> <<'MD'
# QA Report: …

_Posted from Work42_
MD
work42 storage set qa/report "$(jq -nc --arg r '<URL of the comment, or the issue URL if the command prints none>' '$r')"
work42 storage set qa/verdict '"PASS"'     # or '"FAIL"'
```

The report ends with the `_Posted from Work42_` line (see `linear42-general`): the comment relay
skips comments that carry it, so your own report is not echoed back to you as a new comment.

Write `qa/report` first and `qa/verdict` last. On **PASS** the Human Review gate holds and the
session receives the "now available" message (the Lead runs the transition). The Linear comment
is the report of record; `qa/report` just points at it.

## Verdict flow, re-test, key rules

- **PASS** → Human Review; the Lead opens the draft PR with `Fixes <KEY>`.
- **FAIL (1st/2nd)** → In-Progress; the Lead creates fix sub-issues. Re-test the previously failed
  ACs FIRST (fresh evidence), still walk the rest for regressions, and reference the prior report
  ("previously failed AC3, now: …"). Post a **new comment** each round.
- **FAIL (3rd)** → blocked; escalate to Yan.

Non-negotiables: **read the QA guide or stop · exercise every AC · source inspection is never
evidence · couldn't run → FAIL with the named blocker · every PASS has evidence · don't fix bugs ·
fresh report per round · be concise · narrate every meaningful step in chat.**
