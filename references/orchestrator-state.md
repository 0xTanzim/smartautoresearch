# Orchestrator State (`orchestrator-state.json`)

This is the authoritative schema for the ledger the orchestrator loop reads and
writes. It is the single source of truth for routing — `scripts/orchestrate.sh`
(`next-hop`, `units`, `plateau`, `validate-state`, `screen-state-predicate`)
reads **only** the fields documented here. If you hand-build this file, or a
future subcommand writes it, match these names and types exactly: a drifted
field name silently disables the signal that reads it (jq `//` defaults hide the
typo), which mis-routes the loop.

`orchestrator-state.json` is **orchestrator-owned**. Each hop still writes its
own single-hop `handoff.json` (see `references/handoff-schema.md`); the
orchestrator folds the latest handoff into `last_handoff` and never mutates the
hop's own file. Two clearly-owned objects, no overlap.

## Field-by-field schema

| Field | Type | Default | Required | Consumed by | Meaning |
|---|---|---|---|---|---|
| `version` | string | `"1.0.0"` | no | (docs) | Schema version of this ledger. |
| `goal` | string | — | **yes** | `validate-state` | The user's original natural-language goal, verbatim. |
| `archetype` | string | — | **yes** | `validate-state` | Classified archetype (`scripts/orchestrate.sh classify`). One of the 10 in `orchestrator-routing.md`. |
| `mode` | string | `"loop"` | no | (docs) | `"loop"` (predicate-bearing) or `"dispatch"` (single-pass). |
| `predicate` | string | — | **yes** | `validate-state`, `screen-state-predicate` | The pinned Success predicate: the exact shell command that defines "done". Screened on init and on every resume; never re-derived silently. |
| `predicate_met` | bool | `false` | no | `next-hop` | Set true once the predicate command returns its expected output. Routes to `DONE`. |
| `terminal_choice` | string | `"stop-at-verified"` | no | (loop policy) | `"stop-at-verified"` or `"proceed-to-ship"` — chosen at the Round-0 confirm. |
| `cycle_count` | number | `0` | **yes** | `validate-state` | Cycles completed so far. Incremented by the loop, not the script. |
| `max_cycles` | number | `50` | no | (loop policy) | Hard ceiling (`--max-cycles N`). Loop reports `CEILING` when exceeded. |
| `units_remaining_history` | array&lt;number&gt; | `[]` | no | `plateau` | Append-only log of the `units` scalar per cycle. **Entries MUST be JSON numbers** (or the literal string `"unknown"` for a no-signal cycle — see type contract below). Lower is better. |
| `pending_verify` | bool | `false` | no | `next-hop` | A high-impact change was accepted on the working signal; an independent `verify` hop is owed before `DONE`/ship. |
| `untested_gaps` | bool | `false` | no | `next-hop` | Known gaps exist that no test currently covers. Routes to `debug`. |
| `requirements_drift` | bool | `false` | no | routing (drift) | Mechanical progress continuing while the predicate has gone unvalidated ≥ drift window (default 8 cycles). Routes to `probe --from-drift`. |
| `last_probe_cycle` | number | `0` | no | drift detection | `cycle_count` at which `probe`/`plan` last re-validated the predicate. Drift window = `cycle_count - last_probe_cycle`. |
| `last_hop_outcome` | string | `"none"` | no | `next-hop` | Outcome of the most recent hop: `progressed` / `no-op` / `failed` / `blocked`. |
| `retry_route_available` | bool | `false` | no | `next-hop` | Whether an alternative route exists after a `blocked`/`failed` hop. If false, routes to `BLOCKED`. |
| `preset_pipeline_remaining` | array&lt;string&gt; | `[]` | no | `next-hop` | Remaining preset pipeline steps for the archetype (see `orchestrator-routing.md` Preset Pipelines). `next-hop` returns the first element when no higher-priority signal fires. |
| `pipeline_log` | array&lt;object&gt; | `[]` | no | (audit) | Per-hop history: `{cycle, hop, outcome, note}`. Orchestrator-owned; not read by the script, kept for the final report and resume audit. |
| `incumbent` | object\|null | `null` | no | (loop policy) | Current best candidate/state for archetypes that carry one (e.g. optimize-metric, reason). Free-form. |
| `last_handoff` | object | `{}` | no | `next-hop`, `units` | The most recent hop's `handoff.json`, folded in. See `references/handoff-schema.md`. Sub-fields consumed below. |

### `last_handoff` sub-fields the script reads

| Path | Type | Consumed by | Effect |
|---|---|---|---|
| `last_handoff.findings` | array&lt;object&gt; | `next-hop`, `units` | Count of entries with `.severity=="critical"` or `.severity=="high"` (or `.type=="error"` for `next-hop`) → `errors`. `errors > 0` routes to `fix`; the crit/high count is the primary `units` value. |
| `last_handoff.verdict` | string | `next-hop` | `"UNSTABLE"` routes to `regression`. |
| `last_handoff.config.metric_gap` | number | `units` | Fallback units value when `findings` is absent (see units precedence). |

## `units` precedence (how the scalar is computed)

`scripts/orchestrate.sh units` returns the first of these that applies:

1. **Count of `critical`+`high` findings** in `last_handoff.findings`. Note this
   is `0` when a handoff is present with no such findings — so for
   findings-driven archetypes (`fix-broken`, `harden`) this is the live signal.
2. **`last_handoff.config.metric_gap`** — used only when the `findings` key is
   entirely absent from the handoff.
3. **Total `findings` length** — next fallback.
4. **`"unknown"`** — when no usable signal exists (e.g. a runner crash). Unknown
   cycles are excluded from the plateau window, never counted as zero-progress.

> **Metric-optimization note.** Because an empty `findings` array yields `0`,
> pure `optimize-metric` runs (which carry no findings) should record their
> metric-gap scalar into `units_remaining_history` as a number directly, rather
> than relying on the findings-first `units` output — the loop "folds units into
> `units_remaining_history`" (SKILL.md loop step 5g), and it is the loop's job to
> record the archetype-appropriate scalar. Keep it a JSON number either way.

## `units_remaining_history` type contract (GAP-11)

- Every entry is a **JSON number** (`9`, not `"9"`), lower-is-better, OR the
  literal string `"unknown"` for a no-signal cycle.
- `plateau` coerces each entry with jq `tonumber?` before comparing, so a numeric
  *string* is tolerated, but **do not rely on it** — a non-numeric string is
  silently dropped from the window. Storing bare numbers keeps the ledger honest.
- Rationale: a naive `>=` on strings is lexicographic (`"9" >= "10"` is true), which
  would falsely flag a 10→9 improvement as a plateau. `scripts/smoke-test.sh`
  asserts both the numeric and string forms compare numerically.

## Init sequence (Round-0, before the first `next-hop`)

The orchestrator MUST populate the required fields before it routes:

1. `classify "<goal>"` → set `goal`, `archetype`, `mode`.
2. Derive the Success predicate (reuse `plan` logic) → set `predicate`.
3. `screen-cmd "<predicate>"` — refuse and re-derive if unsafe.
4. Confirm archetype + predicate + `terminal_choice` with the user (one prompt).
5. Write the ledger with `cycle_count: 0`, `units_remaining_history: []`,
   `preset_pipeline_remaining` = the archetype's preset pipeline, all bool flags
   at their defaults, `last_handoff: {}`.
6. `validate-state orchestrator-state.json` → must print `valid` before the loop
   starts. Only then call `next-hop`.

## Annotated example ledger

```jsonc
{
  "version": "1.0.0",
  "goal": "improve test coverage in the payment module",
  "archetype": "optimize-metric",          // from `classify`
  "mode": "loop",
  "predicate": "pytest --cov=payment --cov-fail-under=90 -q",  // pinned, screened, never silently re-derived
  "predicate_met": false,
  "terminal_choice": "stop-at-verified",    // do NOT auto-proceed to ship
  "cycle_count": 3,
  "max_cycles": 50,
  "units_remaining_history": [12, 10, 9],   // JSON numbers, lower-is-better; not a plateau (still falling)
  "pending_verify": false,
  "untested_gaps": false,
  "requirements_drift": false,
  "last_probe_cycle": 0,                    // drift window = cycle_count - last_probe_cycle = 3 (< 8, no drift)
  "last_hop_outcome": "progressed",
  "retry_route_available": true,
  "preset_pipeline_remaining": ["evals"],   // next-hop returns "evals" when no higher-priority signal fires
  "pipeline_log": [
    { "cycle": 1, "hop": "plan",  "outcome": "progressed", "note": "derived cov predicate" },
    { "cycle": 2, "hop": "loop",  "outcome": "progressed", "note": "added tests for refund path" },
    { "cycle": 3, "hop": "loop",  "outcome": "progressed", "note": "covered decline path" }
  ],
  "incumbent": null,
  "last_handoff": {
    "version": "1.0.0",
    "source": "loop",
    "status": "BOUNDED",
    "verdict": "none",
    "findings": [],
    "config": { "metric_gap": 9 }
  }
}
```

For this ledger, `next-hop` returns `evals` (no errors, verdict not `UNSTABLE`,
no untested gaps, no pending verify, predicate not met, hop `progressed`, not a
plateau, one preset step remaining). `scripts/smoke-test.sh` runs exactly this
ledger and asserts that result, so the schema and the script cannot drift apart
unnoticed.

## Session-resume flow (GAP-7)

The orchestrator is resumable: the ledger is the whole memory. To resume an
interrupted run:

1. **Detect** — an `orchestrator-state.json` exists in the run directory with
   `cycle_count > 0` and `predicate_met != true`.
2. **Validate** — `scripts/orchestrate.sh validate-state orchestrator-state.json`.
   If it does not print `valid`, stop and surface the error; never route from a
   malformed ledger.
3. **Re-screen the pinned predicate** —
   `scripts/orchestrate.sh screen-state-predicate orchestrator-state.json`.
   Persisted commands are **never trusted**: if it prints `refuse` (exit 2), stop
   and ask the user for a safe predicate before doing anything else.
4. **Resume** — continue the loop at cycle `cycle_count + 1`, calling `next-hop`
   exactly as in a fresh run. The pinned `predicate` is reused verbatim (never
   re-derived on resume), so "done" stays reproducible across sessions.
5. Any command read back from the ledger and executed on resume is re-screened
   via `screen-cmd` first — the resume path has no un-screened-command exception.

## Runtime state files (consolidated)

Every file the loop and orchestrator touch, and who owns it:

| File | Owner | Mutability | Purpose |
|---|---|---|---|
| target file(s) (`Scope`) | Main Agent | read-write | The thing being optimized; committed/reverted each keep/discard. |
| `eval.py` / `rubric.md` | Eval Agent (Phase 1) | **READ-ONLY** after Phase 1 | The judge. Never edited mid-loop (four-way separation). |
| `test_cases.json` | Eval Agent (Phase 1) | **READ-ONLY** after Phase 1 | Fixed test inputs. |
| `outputs/output_XX.txt` | Test Runner | overwritten each iteration | Real outputs to be scored. |
| `<sub>-results.tsv` | Main Agent | append-only | Iteration log (baseline + every iteration). Source of truth for trends/dashboard. |
| `handoff.json` | each subcommand | overwritten per hop | Single-hop chain bridge (`references/handoff-schema.md`). |
| `orchestrator-state.json` | Orchestrator | read-write per cycle | This ledger. The resumable routing memory. |
| `smartautoresearch-worklog.md` | Main Agent | append-only | Human-readable per-iteration narrative. |
| `smartautoresearch-ideas.md` | Main Agent | append-only | Ideas not yet tried / deferred (fuels the NEVER-STOP ladder). |
| `dashboard.html` | Main Agent | regenerated from TSV | Optional live view (`references/dashboard-template.html`). Presentation only, never state. |

All of the above live under the run directory
`smartautoresearch/{subcommand}-{YYMMDD}-{HHMM}/`.
