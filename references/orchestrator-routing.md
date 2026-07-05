# Orchestrator Routing

## Goal Archetypes

| Archetype | Trigger Keywords | Mode | Preset Pipeline |
|---|---|---|---|
| `ship-ready` | ship, release, deploy, publish, production-ready, merge | loop | probe, debug, fix, regression, ship |
| `optimize-metric` | improve, optimize, increase, reduce, raise, boost, iterate, maximize, minimize, tune, refine, lift, faster, smaller, coverage, score, pass_rate, hit_rate | loop | plan, (core loop), evals |
| `fix-broken` | fix, broken, failing, error, crash, bug, cannot run, tests fail | loop | debug, fix, regression |
| `harden` | security, vulnerability, OWASP, CVE, harden, lock down | loop | security, fix, security |
| `build-feature` | build, add, implement, create, new feature, acceptance test | loop | (acceptance-test derive), debug, fix, regression |
| `explore` | understand, explore, investigate, what does, how does, edge cases | loop | probe, scenario, plan |
| `document` | document, wiki, generate docs, explain codebase, write guide | dispatch | learn |
| `what-to-build` | what should I build, ideas, improvements, PRD, roadmap | dispatch | improve |
| `decide-design` | which approach, compare options, design decision, architecture choice | dispatch | reason |
| `research` | research, latest, current, news, find out, look up, whats new | dispatch | research |

Keyword matching is fuzzy — partial matches and synonyms qualify. When a goal matches multiple archetypes, prefer the more specific one (fix-broken over explore; ship-ready over fix-broken if "ship" is explicit; research over explore if the goal is externally-facing rather than about the local codebase; **what-to-build over build-feature** — "what should I build" contains the word "build" but is asking for ideas, not asking to implement something, so it must be checked first). When ambiguous, show the top two candidates in the upfront confirm and let the user choose.

This table is the policy description. The actual matcher is `scripts/orchestrate.sh classify` — keep both in sync; if you change the keyword set here, update the regex branches in the script too (and re-run its smoke test — apostrophes inside an unquoted `[[ =~ ]]` literal will silently corrupt the whole classify function, this has bitten this exact script before).

## Router Decision Table

The `next-hop` subcommand of `scripts/orchestrate.sh` reads `orchestrator-state.json` and applies these rules in order. First match wins.

| State Signal | Source | Next Hop |
|---|---|---|
| `errors > 0` in last handoff | handoff.json `findings` | `fix` |
| regression verdict `UNSTABLE` | handoff.json `verdict` | `regression` |
| regression verdict `BASELINE_UNAVAILABLE` | handoff.json `verdict` | `debug` (stability unverified — establish a baseline first) |
| `untested_gaps` flagged | handoff.json or units output | `debug` |
| `pending_verify` true | orchestrator-state.json | `verify` (fresh independent acceptance check) |
| `requirements_drift` true, not yet resolved (`last_handoff.drift_resolution` absent) | orchestrator-state.json | `probe --from-drift` (once — re-validate the stale predicate) |
| `requirements_drift` true, resolution folded in | `last_handoff.drift_resolution` | `obsolete` → `plan` (re-derive); `confirmed_no_change` / `revised` → cleared, resume normal routing. This is what prevents a probe livelock. |
| predicate met | Success predicate command exit/output | `DONE` (exit loop) |
| hop outcome `blocked` or `failed`, no retry route | orchestrator-state.json | `BLOCKED` (checkpoint + stop) |
| plateau detected | `scripts/orchestrate.sh plateau` | `PLATEAU` (stop + report) |
| archetype pipeline has remaining steps | preset pipeline sequence | next preset step |
| all preset steps exhausted, predicate not met | — | `regression` (convergence re-check) |

State signals are cheap reads — last `handoff.json` plus the regression verdict field, error count, and drift flag. No re-run of the full suite just to route.

## Requirements-Drift Detection

New in smartautoresearch. The orchestrator sets `requirements_drift: true` in `orchestrator-state.json` when:
- `units_remaining` has been improving (loop is making mechanical progress) for 8+ consecutive cycles, AND
- the `plan`/`probe` output backing the pinned predicate has not been re-confirmed in that same window.

This catches the failure mode where a loop keeps satisfying its own Verify command while the Verify command itself has quietly stopped reflecting what the user wants (scope crept, a dependency changed the meaning of "passing," etc.). `next-hop` routes to `probe --from-drift`, which re-validates (not blindly re-derives) the stale constraints and only updates the pinned predicate if the user explicitly adopts a revision (see `commands/plan.md` Phase 0 and the "predicate pinned, not re-derived" safety invariant in SKILL.md). Detection is a hint, never an automatic rewrite.

## Independent Verify & Overfit Guard

The orchestrator must not optimize and accept against the same signal — that lets a
change game its own metric. For `optimize-metric` and `build-feature`, the acceptance
check runs on a **held-out** set (a fresh scenario set or holdout assertions), separate
from the `units` signal used to choose the change. When a high-impact change is accepted
on the working signal, the orchestrator sets `pending_verify` in `orchestrator-state.json`;
`next-hop` then routes to a **verify** hop (dispatched to `reason` or `predict` as an
independent adversarial check) before declaring `DONE` or shipping. The verify hop is
advisory input to convergence — it never auto-approves ship, which stays human-gated.

Concretely, when `next-hop` returns `verify`: dispatch **`reason`** by default (one-shot —
the accepted change as candidate-A, no incumbent) or **`predict`** for `--adversarial` /
holdout-heavy goals, per `reason-judge-protocol.md` "Use as an Independent Verify Hop";
run it once, fold its result, then clear `pending_verify`. This mapping is mirrored in
SKILL.md "Verify Hop Dispatch" — keep the two in sync.

## Two-Mode Split

**Orchestration loop** — used when the goal has an external, mechanical Success predicate: a shell command that returns a value the orchestrator can compare across cycles. Progress is objective (Units remaining falls), plateau is well-defined, and the loop terminates on convergence or a safety backstop. Archetypes: ship-ready, optimize-metric, fix-broken, harden, build-feature, explore.

**Single-pass dispatch** — used when no mechanical predicate exists. The goal is subjective, the subcommand is internally-converging (reason runs its own adversarial loop), or it is a one-shot terminal emitter (learn, improve, research produce a document and stop). The orchestrator routes once, the subcommand self-terminates, and the orchestrator reports the result. No Units remaining, no Plateau counter, no ship gate. Archetypes: document, what-to-build, decide-design, research.

The criterion is: "Can the orchestrator independently verify done without re-running the subcommand?" If yes → loop. If no → dispatch.

## Build-Feature: TDD Ladder

The `build-feature` archetype has no pre-existing metric, so progress is reframed as `green-assertion-count` (monotone integer, higher-is-better). A change that turns a red sub-test green is kept; a change that regresses a green sub-test is reverted. A floor-guard prevents reverting scaffolding commits that compile and add no new failures but pass zero new tests. Large net-new scope (greenfield with no existing test suite) is detected and the orchestrator advises handing off to a dedicated build command rather than grinding cycles.

Note: this archetype's ladder is a project-management framing for the orchestrator loop, not a substitute for the RED→GREEN→REFACTOR discipline itself — the actual test-writing process (write the failing test first, verify it fails for the right reason, minimal code to pass, refactor with tests green) still applies to every unit of work the loop advances through, per the project's own TDD steering.

## Preset Pipelines (Reference)

Emitted verbatim by `scripts/orchestrate.sh seed <archetype>` — the script is the source of truth and orchestrator init seeds `preset_pipeline_remaining` from it; this table mirrors the script (keep the two in sync, the smoke suite pins the mapping).

| Archetype | Step 1 | Step 2 | Step 3 | Step 4 | Step 5 |
|---|---|---|---|---|---|
| ship-ready | probe | debug | fix | regression | ship |
| optimize-metric | plan | (core loop) | holdout-verify | evals | — |
| fix-broken | debug | fix | regression | — | — |
| harden | security | fix | security | — | — |
| build-feature | (acceptance-test derive) | debug | fix | regression | — |
| explore | probe | scenario | plan | — | — |
| document | learn | — | — | — | — |
| what-to-build | improve | — | — | — | — |
| decide-design | reason | — | — | — | — |
| research | research | — | — | — | — |

Presets are starting pipelines. The router adapts per cycle from observed state — it may skip, repeat, or reorder steps based on the decision table above. The preset is a prior, not a fixed schedule.

## Glossary

Terms used consistently across this file, SKILL.md, and orchestrator-state.json.

| Term | Short meaning |
|---|---|
| Goal archetype | Classification of the user's natural-language goal into one of the 10 categories above |
| Success predicate | Exact shell command + expected output that defines "done" for Orchestration loop goals |
| Units remaining | Scalar measure of open gaps (failing tests, errors, metric delta); lower-is-better; computed by `scripts/orchestrate.sh units` |
| Plateau | Units remaining flat or worse for N consecutive computed cycles (default 5); oscillation that nets zero also qualifies |
| Requirements drift | Mechanical progress continuing while the predicate backing it has gone unvalidated for 8+ cycles |
| Orchestration loop | The cycle-bounded assess→route→run→record loop used for predicate-bearing archetypes |
| Single-pass dispatch | One-shot routing to a self-terminating subcommand; no loop, Plateau, ceiling, or ship gate |
| Independent verify hop | A `verify` routing step (reason/predict) that checks an accepted high-impact change against a fresh signal before DONE/ship; gated by `pending_verify` |
| Holdout-verify | Acceptance check run on a held-out set, separate from the `units` signal used to choose the change, to prevent overfitting the metric |
| Terminal state (`DONE` == `CONVERGED`) | The "predicate satisfied, loop finished" state. `scripts/orchestrate.sh next-hop` prints it as `DONE`; SKILL.md and the run reports call the same state `CONVERGED`. They are identical — do not treat them as two states. |
