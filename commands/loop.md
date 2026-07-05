---
name: smartautoresearch:loop
description: "Core autonomous loop: modify, verify, judge, keep/discard against a metric or rubric. Four-way role separation enforced."
argument-hint: "[Goal: <text>] [Scope: <glob>] [Metric: <text>] [Verify: <cmd>] [Guard: <cmd>] [Iterations: N] [--mode deterministic|ai_judge] [--evals] [--dashboard] [--timeout <s>] [--simplicity-band X]"
---

EXECUTE IMMEDIATELY — do not deliberate before reading this protocol.

## Architecture: Four-Way Separation (mandatory, both eval modes)

This is the single most important structural rule in this file. Violating it invalidates the loop's results — an optimizer that can see its own eval code will (even unintentionally) shape changes to game the metric rather than genuinely improve the target.

| Role | Who | Knows Eval Code/Rubric? | Knows Iteration History? |
|---|---|---|---|
| **Main Agent** | You (the optimizer) | **NO** — reads metric number + criteria names only | Yes — reads logs, plans changes |
| **Eval Agent** | `smartautoresearch-eval-agent` sub-agent | Yes — writes eval.py or rubric.md once | No |
| **Test Runner** | `smartautoresearch-test-runner` sub-agent | **NO** — fresh context every call | **NO** |
| **Judge** | `eval.py` (script) or `smartautoresearch-judge` (sub-agent) | IS the eval / follows rubric | **NO** — fresh context |

Full isolation contract: `references/four-way-separation.md`. Criteria quality bar every eval/rubric must pass before use: `references/three-rules.md`.

**Spawning (portable):** each role above is defined in `agents/<role>.md`. Spawn by its registered name (`smartautoresearch-eval-agent`, `smartautoresearch-test-runner`, `smartautoresearch-judge`); **if your host can't resolve the name, launch a fresh sub-agent with that file's contents as its instructions.** Never run the eval, generate outputs, or score in the main agent — a role that can't be spawned is a stop-and-tell-the-user condition, not a "do it myself" fallback.

Two mutually exclusive eval modes:
- **Deterministic** (default) — `eval.py` + proxy heuristics. Metric: `pass_rate`. Best for mechanical checks (word count, format, keywords, structure).
- **AI Judge** (opt-in, `--mode ai_judge`) — `rubric.md` scored by the Judge sub-agent. Metric: `quality_score`. Best for subjective/creative quality (tone, authenticity, narrative).

There is no combined score. Pick one mode per session.

---

## Parse Arguments

Extract from $ARGUMENTS:
- `Goal:` — what to improve
- `Scope:` or `--scope` — file globs
- `Metric:` — what to measure
- `Direction:` — higher_is_better (default) or lower_is_better
- `Verify:` — shell command that outputs a number (deterministic classic mode)
- `--mode deterministic|ai_judge` — eval mode (default deterministic)
- `Guard:` — optional safety command (must always pass)
- `Iterations:` or `--iterations` — integer N for bounded mode (default: 25). "unlimited" for unbounded.
- `--evals` — enable mid-loop checkpoints
- `--evals-interval N` — checkpoint frequency override
- `--chain <targets>` — comma-separated downstream commands
- `--dashboard` — maintain an optional live `dashboard.html` (additive view over the TSV; see Dashboard)
- `--timeout <seconds>` — per-iteration execute/Verify timeout; a run exceeding it is killed and treated as a crash
- `--simplicity-band X` — near-equal band for the simplicity criterion (default: 1% of the metric's typical iteration swing)

## Setup (if required context missing)

If Goal, Scope, Metric, or Verify missing → use request_user_input (single batched call):
  Q1 (Goal): "What do you want to improve?"
  Q2 (Scope): "Which files?" — suggest globs from project
  Q3 (Eval mode): "How should quality be judged?" — "Deterministic (mechanical checks)" / "AI Judge (rubric-scored, better for subjective quality)"
  Q4 (Metric+Verify): "How to measure?" — for deterministic: a shell command that outputs a number; for AI judge: skip, criteria drive the rubric instead
  Q5 (Guard): "Safety command that must always pass?" — options: test cmd, build cmd, skip
If ALL provided inline → skip setup, proceed directly.

If the user pastes raw content (a prompt/skill/template to optimize) instead of a Goal+Metric — save it to a file in the working directory first, then walk The Three Rules before proposing criteria. See `references/three-rules.md` for the exact walkthrough script (explain rules in chat, propose 5-7 criteria, confirm via `AskUserQuestion` with SHORT question text only — details go in chat, never in the popup).

## Precondition Checks

1. Verify git repo exists (`git rev-parse --git-dir`)
2. Check clean working tree (`git status --porcelain`) — warn if dirty
3. Check for stale lock files, detached HEAD
4. If Guard set → run Guard to establish guard baseline
5. Fail fast on any critical issue. Warn on non-critical.

## Verify Safety Screen

Before first dry-run, screen the Verify command via `scripts/orchestrate.sh screen-cmd "<cmd>"`. Refuse and ask for a different command if it returns `refuse`.

---

## Phase 1: Generate the Eval System (via Eval Agent Sub-Agent, once)

Spawn `smartautoresearch-eval-agent` with: the target file/prompt path, confirmed criteria, working directory, eval mode, **and the absolute path to `references/three-rules.md`**. The eval agent runs with fresh context and cannot resolve this skill's relative paths — pass the reference path explicitly, exactly as the Test Runner is handed its reference paths in Phase 2 (this skill guards against relative-path-resolution failures for every fresh-context sub-agent, not just the runner). It produces:
- **Deterministic**: `eval.py` + `test_cases.json`
- **AI Judge**: `rubric.md` + `test_cases.json`

For a worked example of a well-formed deterministic eval, see `references/example-eval.py` (target under test: `references/example-prompt.md`; inputs: `references/example-test-cases.json`) — the eval agent calibrates the *shape* of its output (pure-Python assertions, multi-signal proxy heuristics, `METRIC pass_rate=` final line) against these, then copies the shape, not the file.

**You (the optimizer) MUST NOT read the eval artifacts in detail afterward.** Show the user the generated file once and get an explicit go-ahead before locking it — `request_user_input`: *"Does this eval capture what you mean?"* (options: looks good / adjust). Treat it as **READ-ONLY** only after they confirm; a bad eval locked silently wastes every iteration, so this gate is not optional. If they want changes, re-spawn the eval agent with the adjustment and re-confirm. Once locked, the eval agent is never called again during the loop.

## Phase 2: Establish Baseline (Iteration 0)

1. Create the `outputs/` directory.
2. Spawn `smartautoresearch-test-runner` with the prompt/target path + `test_cases.json` path. Fresh context — it does not know what the eval checks for.
   - **Before spawning**, scan the target for references to other files (`references/`, linked files, imported data) and pass their absolute paths explicitly — the test runner cannot resolve relative paths with fresh context.
3. Evaluate:
   - **Deterministic**: run `python eval.py outputs/`, parse `METRIC pass_rate=X.XXXX` from stdout.
   - **AI Judge**: spawn `smartautoresearch-judge` against `outputs/` + `rubric.md`, parse `quality_score` from `judge-scores.json`.
4. Record iteration 0 in the results TSV as baseline. **Print the run header to chat** to open the live progress stream — include the iteration budget so a long autonomous run is never a surprise:
   ```
   ● Goal: {goal} · baseline {metric} · budget {N} iterations
   ```
   If the user never passed `Iterations:`, {N} is the default **25** — say so (`budget 25 iterations (default)`) so they can interrupt or pass `Iterations: N` / `unlimited` for a different length.
5. Create output directory: `smartautoresearch/loop-{YYMMDD}-{HHMM}/`.
6. Write TSV header: `# metric_direction: {direction}\niteration\tcommit\ttimestamp\thypothesis\tmetric_name\tmetric_value\tbaseline\tbest_so_far\tdelta\teval_mode\tguard\tstatus\tdescription`. The `commit` column records the short hash of each kept commit so `commands/evals.md` can run its file-hotspot analysis; write `-` when there is no commit (discard, crash, or `.backup` mode).
7. **(Optional) Create the live dashboard.** If `--dashboard` is set or the user asks for a live view, copy `references/dashboard-template.html` into the run directory as `dashboard.html` and fill the baseline markers (`GOAL`, `MAX_ITER`, `METRIC_NAME`, `BASELINE`). It is an additive presentation view over the TSV, never the source of truth; if the template is missing or the write fails, log a note and continue — the loop never blocks on it.

---

## Phase 3: The Loop (repeat until stop condition)

### Step 1 — Review
- Read the current state of the modifiable file(s)
- Read the last 10-20 rows of the results TSV
- Run `git log --oneline -20` if using git backup
- Read `smartautoresearch-ideas.md` if it exists
- **Loop 4 (cross-run learning):** read `smartautoresearch-lessons.md` if it exists (see `references/lessons-memory.md`). Treat entries as **advisory priors** — they bias where you look first, never override a hard gate or excuse skipping a real re-check. This is what lets the system improve across runs, not just within one.
- Read the last few `loop-breakdown.jsonl` entries if present — the per-criterion scores across recent iterations, so a criterion stuck low for many iterations is visible, not just the latest eval.
- Identify: which criteria/assertions score lowest, and which have stayed weakest across iterations? Which test cases are hardest?

### Step 2 — Ideate
- Pick ONE idea to try this iteration — atomic, one hypothesis
- Write the hypothesis in plain English before making the change
- Target the weakest area from the last eval

### Step 3 — Modify
- Git available: commit will serve as the revert point. Git unavailable: copy the modifiable file to `[filename].backup` first.
- Make exactly ONE change.

### Step 4 — Execute (via Test Runner Sub-Agent)
Spawn `smartautoresearch-test-runner` fresh each iteration. It never learns what iteration this is, what changed, or what the eval checks for. Pass it the prompt path, `test_cases.json` path, and every reference file path the prompt depends on.

**Per-iteration timeout (optional, `--timeout <seconds>`).** An autonomous loop must never stall on a hung command. When a timeout is set, wrap the execute/Verify step so a run exceeding it is killed and treated as a **crash** (revert, log `crash`, triage per Step 7). A killed run is never recorded as a real metric value (e.g. never logged as `0` that a later step could mistake for a legitimate result). Default: no timeout, unless the Verify command is known to be long-running.

### Step 5 — Evaluate
- **Deterministic**: run `python eval.py outputs/`, parse `METRIC pass_rate=X.XXXX`. Crash → status `crash`.
- **AI Judge**: spawn `smartautoresearch-judge` fresh, parse `quality_score` from `judge-scores.json`.

### Step 6 — Guard Check (if guard is set)
Run the guard. Guard failure → this iteration is automatically `discard`, regardless of metric movement.

### Step 7 — Decide

| Condition | Action |
|---|---|
| Metric improved (correct direction) AND guard passed | **keep** — commit stays / update `.backup` |
| Metric ~equal (within the simplicity band) AND the change reduces complexity AND guard passed | **keep** — simplification win (see Simplicity Criterion) |
| Metric ~equal but the change adds substantial complexity | **discard** — complexity cost not worth it |
| Metric worse | **discard** — revert |
| Eval crashed | **crash** — triage (see Crash Triage) |
| Guard failed | **discard** regardless of metric |
| No change was actually made this iteration | **no-op** — see Process Outcomes |
| A git hook rejected the commit | **hook-blocked** — see Process Outcomes |
| Verify/eval ran but its output was not a parseable number | **metric-error** — see Process Outcomes |

These are the complete set of status values the loop writes to the TSV —
`baseline` (iteration 0), `keep`, `discard`, `crash`, `no-op`, `hook-blocked`,
`metric-error`. `commands/evals.md` parses exactly this set for its trend and
plateau analysis, so never invent a status outside it.

#### Process Outcomes (not metric keep/discard decisions)
Three outcomes are *process* results, not judgments on the metric — they still get logged (Rule 8: log everything), but they mean "this iteration didn't produce a comparable metric," not "the change was worse":
- **no-op** — Step 2 produced nothing actionable, or the "change" was byte-identical to the incumbent. Nothing to revert. Log `no-op` and move on. A no-op does **not** count as a zero-progress cycle for plateau purposes (it's "no attempt," not "attempt that didn't help") — mirrors the orchestrator's unknown-units rule.
- **hook-blocked** — git mode only: a pre-commit / commit-msg hook rejected the commit, so the change never landed as a commit. Log `hook-blocked`, restore the working tree to the incumbent (the change is not kept), and surface the hook's message so it's not mistaken for a metric regression. **Never** force past a hook with `--no-verify` to make the iteration "succeed" — a blocked hook is a real signal, not an obstacle to route around (see the repo's git-safety rules).
- **metric-error** — the Verify command / eval *ran* but its output was not a parseable number (empty, `NaN`, a stack-trace-to-stdout, a format change). This is distinct from `crash` (the command itself failed to run): the command ran, the *result* is unusable. Revert the change (an unmeasurable change can't be kept on faith), log `metric-error`, and if it recurs, the eval/Verify contract itself is the bug to fix — not the target.

#### Simplicity Criterion (karpathy)
All else being equal, simpler is better — so "metric unchanged" is **not**
automatically a discard. When the metric lands within a small near-equal band
(default `|delta| ≤ 1%` of the metric's typical iteration swing; override with
`--simplicity-band X`), weigh complexity against improvement:
- Metric ~equal **but the change deletes code / removes a dependency / nets
  negative LOC** → **keep** (a simplification win — a great outcome, per karpathy).
- A tiny improvement (~0) that adds **substantial** complexity (e.g. +20 lines of
  hacky code for +0.001) → **discard**; the complexity cost outweighs the gain.
- A clear metric improvement keeps regardless of complexity.

Record the complexity rationale in the `description` column so the log shows
*why* a near-equal change was kept or discarded. (The orchestrator applies the
same keep semantics — see SKILL.md "Keep semantics".)

#### Crash Triage (karpathy)
On a crash, read the error first (tail the run log — do not flood context):
- **Trivial/dumb crash** in the change you just made (typo, missing import,
  obvious off-by-one) → fix it and re-run **once**. Do not count the retry as a
  new iteration.
- **Fundamentally broken idea** (OOM, the approach itself cannot work) → log
  status `crash`, revert, and move on. Do not keep retrying the same idea.
- A crash fix touches **only the target** — never `eval.py`, `rubric.md`, or
  `test_cases.json` (they stay read-only; four-way separation).

### Step 8 — Log

**First, show the user this iteration — print ONE compact line to chat.** This is the live progress stream, and the main thing the user watches during a run:
```
#{n}  {hypothesis}    {before} → {after}   {keep ✓ | discard ↩ | crash ✗}{ append " (simpler wins)" when kept on the simplicity criterion}
```
One scannable line per iteration — never a paragraph. For example:
```
#4  add a specific-number CTA        0.62 → 0.71   keep ✓
#5  soften the opening line          0.71 → 0.68   discard ↩
#6  move pain-point before pitch     0.71 → 0.79   keep ✓
#7  trim system prompt 40%           0.79 → 0.79   keep ✓ (simpler wins)
```

Then append a row to the results TSV, including the short `commit` hash for a kept commit (or `-` for discard/crash/`.backup` mode — this powers the `evals` file-hotspot analysis). Update `smartautoresearch-worklog.md` with a human-readable entry.

Also append one line to `loop-breakdown.jsonl`: `{"iteration": N, "status": "...", "per_criterion": {"<name>": <pass_count | avg_score>, ...}}` — the per-criterion breakdown from this iteration's eval (assertion pass-counts in deterministic mode, per-criterion averages in AI-judge mode). Step 1 reads this back to target the criterion that has stayed weakest *across* iterations, not just the last one; `commands/evals.md` can trend it. Never write raw outputs or secrets here — counts and criterion names only.

**Loop 4 (cross-run learning):** on a *notable* outcome only — a keep that worked after several failures, a discard/crash with a non-obvious recurring cause, a plateau broken by a specific strategy, or an escalation — append one generalizable lesson to `smartautoresearch-lessons.md` per `references/lessons-memory.md`. Never log routine keeps, never log secrets or one-off literals, never overwrite prior entries. This is the write half of the loop that makes the *system* compound across runs.

**(Optional) Refresh the dashboard.** If `dashboard.html` exists in the run directory, regenerate it from the TSV by substituting the marker pairs in `references/dashboard-template.html`: `ITERATIONS`, `BEST`, `BASELINE`, `IMPROVEMENT`, the progress bar (`BEST_PCT`/`BEST_WIDTH`), the `KEEP_COUNT`/`DISCARD_COUNT`/`CRASH_COUNT` pills, `TIMESTAMP`, and prepend the new iteration to the `ROWS` block. A failed dashboard write is logged and skipped — never fatal to the loop.

### Eval Checkpoint (--evals flag)
- Interval: `floor(max_iterations / 3)`, min 1. Fixed 10 if unbounded. Override `--evals-interval N`.
- Print: `--- Eval Checkpoint (iterations {X}-{Y}) ---\nMetric: {start} → {end} ({delta}) | Kept: {n}/{total} | Trend: {up/flat/down}\n{one-line recommendation}\n---`
- Plateau 3+ checkpoints → recommend early stop.
- At loop end → full evals summary to `evals-summary.md` (or dispatch to `commands/evals.md`).

### Bounded Check
`current_iteration >= max_iterations` → exit loop, print summary.

### Step 9 — Repeat
- After 3+ consecutive discards on similar ideas → pivot radically, try a different area entirely.
- If the metric or criteria feel like they no longer match what the user actually wants (drift), stop and suggest `$smartautoresearch probe` to re-derive requirements before continuing — do not keep grinding a stale target silently.
- If the user messages mid-loop → pause, respond, resume.

---

## The Separation Rules (non-negotiable)

1. **You are the optimizer. You NEVER generate outputs, write eval code, or score quality yourself.**
2. **The eval agent writes the eval system once, then disappears.** Never called mid-loop.
3. **The test runner NEVER sees the eval or rubric.** Fresh context every call.
4. **The judge is READ-ONLY.** Never modify `eval.py`, `rubric.md`, or `test_cases.json` during the loop.
5. **The judge agent NEVER sees iteration history (AI judge mode).** Fresh context every call — no iteration count, no prior changes, no optimization goal.
6. **ONE change per iteration.** Never bundle multiple ideas.
7. **Always revert on discard.** Never accumulate failed changes.
8. **Log everything**, including crashes and no-ops.
9. **Don't ask permission mid-loop.** Only pause if the user messages you.
10. **No cherry-picking.** Run the full eval every time, not a subset of test cases.

---

## Git Integration

- Git available: branch `smartautoresearch/[goal-slug]-[date]` before starting. Commit on every `keep`. `git checkout -- [file]` (or `git revert HEAD --no-edit` if already committed) on every `discard`.
- Git unavailable: `.backup` file swap as described in Step 3/Step 7.

## State Files & Resume

Everything the loop needs to resume lives in the run directory
`smartautoresearch/loop-{YYMMDD}-{HHMM}/`. Ownership and mutability:

| File | Owner | Mutability | Purpose |
|---|---|---|---|
| target file(s) (`Scope`) | Main Agent | read-write | The thing being optimized; committed/reverted each keep/discard. |
| `eval.py` / `rubric.md` | Eval Agent (Phase 1) | **READ-ONLY** after Phase 1 | The judge — never edited mid-loop (four-way separation). |
| `test_cases.json` | Eval Agent (Phase 1) | **READ-ONLY** after Phase 1 | Fixed test inputs. |
| `outputs/output_XX.txt` | Test Runner | overwritten each iteration | Real outputs to be scored. |
| `loop-results.tsv` | Main Agent | append-only | Source of truth for trends + dashboard. |
| `handoff.json` | this command | overwritten at end | Chain bridge (`references/handoff-schema.md`). |
| `orchestrator-state.json` | Orchestrator (if launched via orchestrator) | read-write per cycle | Resumable routing ledger (`references/orchestrator-state.md`). |
| `smartautoresearch-worklog.md` | Main Agent | append-only | Human-readable per-iteration narrative. |
| `smartautoresearch-ideas.md` | Main Agent | append-only | Deferred ideas — seeds the NEVER-STOP ladder. |
| `smartautoresearch-lessons.md` | Main Agent (Loop 4) | append-only, **project-local (persists across runs)** | Cross-run learning (`references/lessons-memory.md`). Lives in the working project dir, NOT the per-run dir — that's what makes it persist. |
| `dashboard.html` | Main Agent | regenerated from TSV | Optional live view; presentation only, never state. |

**Resume:** read the existing `loop-results.tsv` (last row = last completed
iteration) and the target's git log / `.backup` to re-establish the incumbent,
then continue at the next iteration. When the loop was driven by the
orchestrator, follow the full detect → `validate-state` → `screen-state-predicate`
→ resume flow in `references/orchestrator-state.md` — every command read back
from a persisted file is re-screened via `scripts/orchestrate.sh screen-cmd`
before it runs; persisted commands are never trusted.

## Stopping

**Bounded mode (default, `Iterations: N`).** The loop stops when: the user says
stop/pause, the iteration count is reached, or the metric plateaus (no
improvement in 10+ consecutive iterations). In bounded mode a plateau *recommends
stop* and writes the final summary.

**Unlimited mode (`Iterations: unlimited`, opt-in — karpathy's "NEVER STOP"
contract).** The loop does **not** stop on plateau and never asks "should I keep
going?" or "is this a good stopping point?". The human may be asleep and expects
work to continue indefinitely; you are autonomous. On plateau (or when out of
obvious ideas), climb the escalation ladder instead of stopping:

### NEVER-STOP Escalation Ladder (unlimited mode only)
1. **Re-read the in-scope files** and the last ~20 TSV rows for angles you missed.
2. **Combine prior near-misses** — pair changes that each almost helped.
3. **Dispatch `commands/research.md`** for new external angles/techniques
   (findings are advisory — fed into ideation, never auto-applied).
4. **Try a radical redesign** — abandon the current local optimum for a
   structurally different approach.

Only two things stop an unlimited run: an explicit **user interrupt**, or an
explicit **hard ceiling** if one was set (`--max-cycles N`). With no ceiling set,
an unlimited run continues until interrupted — that is the karpathy contract,
verbatim. Bounded-by-default remains the safety invariant; unlimited is always an
explicit opt-in, never the default.

On any stop, first print this one-line board to chat:
```
best so far: {best} ({+X%} over baseline) · {n} experiments · {kept} kept
```
Then write a final summary: total iterations, best metric vs baseline,
top 3 most impactful changes, and ideas never tried (save to
`smartautoresearch-ideas.md` — these seed the ladder on the next run).

## Dashboard

Optional, additive, and off by default. When `--dashboard` is set (or the user
asks for a live view), the loop maintains a single self-contained `dashboard.html`
in the run directory, regenerated from `references/dashboard-template.html` at
baseline (Phase 2 step 7) and after every iteration (Step 8). It is a
presentation layer over the `*-results.tsv` log — the TSV (plus `eval.py`/rubric)
remains the only source of truth. The template carries no JavaScript and makes no
network calls, so it opens offline. A dashboard read/write failure is always
non-fatal: log a note and keep looping.

## Chain Handoff

After completion, write `handoff.json` to the output directory: version "1.0.0", source "loop", timestamp, status (COMPLETE|USER_INTERRUPT|BOUNDED|ERROR), results_tsv path, findings[], config{goal, scope, metric, direction, verify, eval_mode, metric_gap}. `metric_gap` is the remaining distance to target (lower-is-better) so the orchestrator's `units` reads real optimize progress instead of a zero findings-count — omit it and an optimize run reads as a false plateau. Canonical envelope, status enum, and `findings[]` shape: `references/handoff-schema.md`. Invoke next target in `--chain` order. Propagate `--evals` flag.
