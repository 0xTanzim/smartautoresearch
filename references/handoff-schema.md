# Handoff Schema (`handoff.json`)

Every subcommand writes exactly one `handoff.json` to its run directory when it
finishes. It is the **single-hop chain bridge**: the next `--chain` target reads
it, and the orchestrator folds it into `orchestrator-state.json` as
`last_handoff` (see `references/orchestrator-state.md`). This file is the one
canonical contract; the per-command "Chain Handoff" sections describe how each
command populates it, not fifteen different schemas.

## Common envelope (all subcommands)

```jsonc
{
  "version": "1.0.0",                 // string, REQUIRED. Handoff schema version, unified across all commands.
  "source": "loop",                   // string, REQUIRED. Emitting subcommand: loop|plan|debug|fix|security|ship|scenario|predict|learn|reason|probe|improve|research|evals|regression.
  "timestamp": "2026-07-04T10:00:00Z",// string (ISO-8601 UTC), REQUIRED.
  "status": "COMPLETE",               // string, REQUIRED. See status enum below.
  "results_tsv": "loop-260704-1000/loop-results.tsv", // string|null. Path to the run's TSV, if any.
  "findings": [ /* see findings[] */ ],
  "config": { /* command-specific echo of the resolved config */ }
}
```

### `status` enum (superset — a consumer must tolerate any of these)

| Value | Meaning | Emitted by (typical) |
|---|---|---|
| `COMPLETE` | Ran to a normal, successful end. | all |
| `CONVERGED` | Reached a stable/converged result (== `DONE` in routing terms). | reason, regression, orchestrator |
| `SATURATED` | Search space exhausted (no new results). | scenario, regression |
| `BOUNDED` | Stopped because the iteration/cycle budget was hit. | any looping command |
| `PARTIAL` | Finished with partial results (some queries/dims failed but usable). | research, regression |
| `USER_INTERRUPT` | User stopped the run mid-loop. | any looping command |
| `DRY_RUN` | Planned only; nothing was applied/deployed. | ship, orchestrator `--dry-run` |
| `ROLLBACK` | A change/deploy was rolled back. | ship |
| `ERROR` | Aborted on an error. | all |

Individual commands MAY restrict which subset they emit, but consumers
(especially `evals`, `ship`, and the orchestrator) MUST NOT crash on any value in
this superset. `CONVERGED` and the router's terminal `DONE` are the same state
(see `orchestrator-routing.md` Glossary).

### Regression-only optional fields

`regression` additionally sets (see `commands/regression.md`):

```jsonc
  "verdict": "STABLE",                // STABLE | UNSTABLE | BASELINE_UNAVAILABLE
  "regression_state": "none"          // REGRESSION_FOUND | REGRESSION_FIXED | none
```

`ship` reads `verdict` for its deploy gate; the orchestrator's `next-hop` reads
`verdict == "UNSTABLE"` to route back to `regression`.

## `findings[]` shape

`findings` is an array of objects. All keys are optional individually, but the
orchestrator's routing depends on `type`/`severity` being present when they
apply, so populate them whenever meaningful:

```jsonc
{
  "id": "F1",                         // string, optional. Stable id within this run.
  "type": "error",                    // string, optional. error|bug|constraint|scenario|recommendation|vulnerability|gap
  "severity": "critical",             // string, optional. critical|high|medium|low|info
  "file_line": "src/auth.py:42",      // string, optional. "path:line" locator.
  "summary": "NoneType on empty login"// string, optional. One-line human description.
}
```

Semantics by emitter (the array's *contents* vary; the *shape* does not):

| Emitter | `findings[]` holds | Typical `type` |
|---|---|---|
| debug / fix | bugs / errors to resolve | `bug`, `error` |
| security | vulnerabilities | `vulnerability` |
| scenario | generated edge cases (severity-ranked) | `scenario` |
| probe | open requirement constraints | `constraint` |
| improve / reason | recommendations / chosen option | `recommendation` |
| regression | blocking regressions | `error` (+ `verdict`) |
| research | advisory citations (never auto-applied) | `recommendation` |

## Orchestrator contract (what `next-hop`/`units` actually read)

The orchestrator only depends on this minimal subset of a folded
`last_handoff`. Keeping these accurate is what makes routing correct:

| Contract field | Type | Router effect |
|---|---|---|
| `findings[].severity == "critical"\|"high"` (or `findings[].type == "error"`) | — | any present → `errors > 0` → route to `fix`; crit/high count is the primary `units` value |
| `verdict == "UNSTABLE"` | string | route to `regression` |
| `config.metric_gap` | number | fallback `units` value when `findings` is absent |

Anything else in the handoff is informational for the chain / the final report.

## Status enum by command (quick reference)

| Command | `status` values it emits |
|---|---|
| loop | `COMPLETE` \| `USER_INTERRUPT` \| `BOUNDED` \| `ERROR` |
| research | `COMPLETE` \| `PARTIAL` \| `USER_INTERRUPT` \| `ERROR` |
| scenario | `COMPLETE` \| `SATURATED` \| `BOUNDED` \| `USER_INTERRUPT` \| `ERROR` |
| learn | `COMPLETE` \| `BOUNDED` \| `USER_INTERRUPT` \| `ERROR` |
| reason | `CONVERGED` \| `BOUNDED` \| `USER_INTERRUPT` \| `ERROR` |
| regression | `COMPLETE` \| `CONVERGED` \| `SATURATED` \| `BOUNDED` \| `USER_INTERRUPT` \| `ERROR` (+ `verdict`, `regression_state`) |
| ship | `COMPLETE` \| `DRY_RUN` \| `ROLLBACK` \| `USER_INTERRUPT` \| `ERROR` |
| plan / probe / improve / predict / debug / fix / security / evals | `COMPLETE` \| `USER_INTERRUPT` \| `ERROR` |
