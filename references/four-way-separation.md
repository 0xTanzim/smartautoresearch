# Four-Way Separation of Roles

The core loop (`commands/loop.md`) and everything that feeds it depend on a strict isolation contract between four roles. This is not bureaucracy — it's the mechanism that keeps an optimizer from (even unintentionally) shaping the target to game its own evaluator. Every violation of this contract invalidates the loop's results, not just its "cleanliness."

## The Four Roles

| Role | Who | Knows Eval Code/Rubric? | Knows Iteration History? | Called |
|---|---|---|---|---|
| **Main Agent** | You (the optimizer) | **NO** — reads metric number + criteria names only | Yes — this is its job | Every iteration |
| **Eval Agent** | `agents/eval-agent.md` | Yes — it writes the eval | No | **Once**, then never again |
| **Test Runner** | `agents/test-runner.md` | **NO** — fresh context every call | **NO** — fresh context every call | Every iteration |
| **Judge** | `eval.py` (script, deterministic) or `agents/judge.md` (AI judge) | IS the eval / follows the rubric exactly | **NO** — fresh context every call | Every iteration |

## Why fresh context matters (not just "no memory")

"Fresh context" is doing real work here, not a formality:

- The **Test Runner** never seeing the eval means it can't unconsciously shape outputs toward what it guesses will score well — it just executes the prompt as written, the same way it would in production.
- The **Judge** never seeing iteration history means it can't grade "iteration 7" more leniently than "iteration 1" out of narrative momentum ("it's gotten so much better, surely this one's good too") — every output is scored cold, on its own merits, every time.
- The **Eval Agent** disappearing after Phase 1 means there's no channel for the optimizer to lobby it mid-loop into loosening a check that keeps failing.

## The Rules, Verbatim

1. **The Main Agent NEVER generates outputs, writes eval code, or scores quality itself.** It edits the target, reads the metric, decides keep/discard. That's the entire job.
2. **The Eval Agent writes the eval system once, then disappears.** Never called again during the loop. The optimizer never sees how its heuristics or scoring examples are implemented — only the aggregate number.
3. **The Test Runner NEVER sees the eval or rubric.** It receives only: the prompt/target file path + test cases path + any reference files the prompt itself depends on. It does not know what's being checked, what iteration this is, or what the goal is.
4. **The Judge is READ-ONLY during the loop.** `eval.py`, `rubric.md`, and `test_cases.json` are never modified once confirmed in Phase 1 — not even to "fix" something that seems wrong; that requires re-invoking the Eval Agent explicitly, with the user's awareness.
5. **The Judge agent NEVER sees iteration history (AI judge mode).** Fresh context every call: no iteration count, no prompt diff, no optimization goal, no other output for comparison. Score each output on its own.

## What Applies This Contract

- `commands/loop.md` — the canonical implementation.
- `commands/regression.md` — its Hunter/root-cause step reuses `debug`'s isolation, and its `--fix` re-gate reuses `fix`'s isolation; neither the regression gate itself nor its re-gate ever peeks at how the verify commands are implemented beyond running them.
- `agents/research-agent.md` — extends the same isolation principle to web research: each parallel query gets fresh context with no visibility into sibling queries' framing, preventing one query's phrasing from biasing another's results (see `commands/research.md` Phase 2).

## Common Violations (reject these on sight)

- Main Agent reading `eval.py` source "just to understand the checks better." No — read the assertion *names* from stdout/breakdown output only.
- Reusing a Test Runner or Judge sub-agent session across iterations instead of spawning fresh each time — even if the platform makes this technically possible, it's a hard violation of the contract, not a convenience.
- Letting the Eval Agent "adjust" an existing eval mid-loop instead of it only running once in Phase 1 — if the eval genuinely needs to change, that's a new Phase 1 pass with the user's explicit awareness that history-so-far is being scored against a moving target.
