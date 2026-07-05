---
name: smartautoresearch:plan
description: "Convert a goal into validated Scope, Metric, Direction, Verify config"
argument-hint: "[Goal: <text>] [--chain <targets>] [--from-drift]"
---

EXECUTE IMMEDIATELY.

## Parse Arguments

Extract from $ARGUMENTS:
- `Goal:` — text after keyword, or full $ARGUMENTS if no keyword
- `--chain <targets>` — comma-separated downstream commands
- `--<subcommand>` — chain shorthand
- `--from-drift` — this invocation was triggered by the orchestrator's requirements-drift signal (see SKILL.md Orchestrator section) rather than a fresh user request. When set, Phase 0 must explicitly diff the newly-derived config against the pinned `orchestrator-state.json` predicate/config and surface the delta to the user before replacing anything.

Remaining text = goal description.

## Setup (if Goal missing)

request_user_input (single batch):
  Q1 (Goal): "What do you want to achieve?" — open text
  Q2 (Type): "What kind of goal?" — improve a metric, fix errors, audit security, explore edge cases, document code, ship something, research something
If Goal provided → skip.

## Phase 0: Drift Diff (only if --from-drift)

1. Read the pinned `predicate` and `config` from `orchestrator-state.json`.
2. Derive the new config per Phases 1-4 below as normal.
3. Diff old vs new: Scope, Metric, Verify, Direction.
4. Present the diff to the user via `request_user_input`: "Requirements may have drifted. Old predicate: `{old}`. Proposed new predicate: `{new}`. Keep old / adopt new / adjust?"
5. Only write the new predicate into `orchestrator-state.json` if the user explicitly adopts it — this mirrors the "predicate pinned, not re-derived" safety invariant in SKILL.md. Drift detection proposes; it never silently overwrites.

## Phase 1: Analyze Goal

Parse the goal to determine:
- Is it measurable? (metric-driven vs subjective)
- What's the natural scope? (files, modules, entire codebase)
- What subcommand fits best? (core loop, fix, debug, security, research, etc.)

## Phase 2: Derive Scope

1. Scan project structure
2. Identify files relevant to the goal
3. Propose file globs
4. If ambiguous → ask user to confirm

## Phase 3: Derive Metric + Direction

For metric-driven goals:
- Identify what to measure (test coverage, error count, bundle size, latency, etc.)
- Determine direction: higher_is_better or lower_is_better
- Propose metric name and description

For subjective goals:
- Suggest proxy metrics where possible
- Or recommend `$smartautoresearch reason` for non-measurable goals, or `$smartautoresearch research` if the goal is actually "find out X" rather than "change X"

## Phase 4: Derive Verify Command

1. Identify how to extract the metric as a number from a shell command
2. Propose Verify command (e.g., `npm test -- --coverage | grep "All files" | awk '{print $10}'`)
3. **Safety screen:** `scripts/orchestrate.sh screen-cmd "<proposed command>"` — refuse and re-derive if it returns `refuse`
4. Dry-run the Verify command → confirm it outputs a valid number
5. If dry-run fails → adjust command and retry

## Phase 5: Derive Guard (optional)

Propose a Guard command if applicable:
- Test suite: `npm test` / `pytest` / `go test ./...`
- Type check: `tsc --noEmit` / `mypy`
- Build: `npm run build`
- None if not applicable

## Phase 6: Suggest Iterations

Based on goal complexity:
- Simple metric improvement → 10-15
- Moderate refactoring → 20-25
- Complex multi-file changes → 30+
- Recommend bounded default, mention `Iterations: unlimited` option

## Phase 7: Present Config

Output a ready-to-run config block:

```
$smartautoresearch
Goal: {derived goal}
Scope: {derived globs}
Metric: {derived metric}
Direction: {higher_is_better|lower_is_better}
Verify: {derived command}
Guard: {derived guard or omit}
Iterations: {suggested count}
```

Ask user: "Run this config now, or adjust?"

## Chain Handoff

If `--chain` set:
- Write `handoff.json`: version "1.0.0", source "plan", timestamp, status COMPLETE, config = derived config block
- Invoke next target with the derived config
