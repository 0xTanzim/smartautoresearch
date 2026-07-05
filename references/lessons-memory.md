# Loop 4 — Persistent Cross-Run Learning ("auto-improvement power")

## Why this exists

The core loop (`commands/loop.md`) and the orchestrator loop both **reset every run** — plan, iterate, keep/discard, report, and the next run starts cold. That is the gap 2026 loop-engineering practice calls the missing **fourth loop**: the three inner loops (iterate → verify → orchestrate) all live inside a single session, and a system that only has those three never gets better *across* sessions. Loop 4 is the outer loop that persists what was learned so the *system* compounds over time, not just the current run.

This is deliberately **not** model fine-tuning and **not** a training pipeline — it needs no gradient, no dataset, no GPU. It is disciplined structured note-taking with a hard read/write contract around it. The leverage is real precisely because it is cheap: a lesson learned on run 7 ("this repo's coverage tool prints two numbers, grep the second") is exactly the context run 8 would otherwise have to rediscover from scratch.

The four loops, for reference:

| Loop | Scope | Where it lives |
|---|---|---|
| 1 — Iterate | one change → verify → keep/discard | `commands/loop.md` Phase 3 |
| 2 — Verify | independent acceptance check on a held-out signal | orchestrator `verify` hop, `reason`/`predict` |
| 3 — Orchestrate | route across subcommands until predicate met | `SKILL.md` orchestrator + `scripts/orchestrate.sh` |
| **4 — Learn** | **persist lessons across runs so the system improves** | **this file's protocol** |

## The file

`smartautoresearch-lessons.md` in the **working project directory** (not the skill directory) — it is knowledge about *that project's* optimization surface, so it lives with the project and persists across every run there. One shared file per project, read by the main loop and every sub-agent it spawns, because a lesson the judge learned ("outputs over ~180 words started gaming the length proxy") is exactly as useful to the next test-runner and the next optimizer as to the next judge.

For the **self-improvement mode** (optimizing this skill itself — see below), the lessons file lives at the skill root: `smartautoresearch-lessons.md` alongside `SKILL.md`.

## Read (start of every run)

Before planning, read the lessons file if it exists. Treat every entry as **advisory input, not ground truth**:
- A past lesson can be stale, wrong for the current state, or no longer applicable.
- **Never let a lesson override a hard gate's actual output.** If a lesson says "the guard always passes here," you still run the guard.
- **Never skip re-verifying something just because a lesson says it already works.** Re-run the real check; the lesson only tells you where to look first.
- If the file does not exist yet, that is a fresh start, not an error.

Weigh lessons as priors that bias *where you look first* and *what you try first* — not as substitutes for measurement.

## Write (on notable outcome, NOT every iteration)

Append an entry — never overwrite, never delete another run's entry — when one of these happens:
- A change **kept** for a non-obvious reason worth repeating (an angle that worked after several failures; a simplification that also improved the metric).
- A change **discarded** or **crashed** for a non-obvious reason that would plausibly recur (a proxy the eval could be gamed on; a guard that fired for a surprising reason; a dependency gotcha specific to this project).
- A **plateau** was broken by a specific strategy (which escalation-ladder rung actually worked).
- An **escalation / block** occurred (`commands/loop.md` Stopping, orchestrator `BLOCKED`) — the root blocker and how it was ultimately resolved, or that it is still open.

Do **not** log routine keeps, trivial discards, or anything containing secrets, credentials, tenant-specific data, PII, or values that only make sense for one input. A lesson is a **generalizable rule**, not a transcript. If you catch yourself about to write an API key, a customer name, or a one-off literal into a lesson, generalize it out or don't write the entry.

```markdown
## [ISO-8601 timestamp] — [loop | orchestrator | judge | eval-agent | research | ...]
**Trigger**: [what happened — kept-after-struggle, discard-reason, plateau-break, escalation]
**Lesson**: [one generalizable sentence — a rule for next time, not a story]
**Scope**: [this project only | this stack/language generally | this metric type generally]
```

## Staleness handling

On write, if the file has grown past ~150 entries, or contains entries clearly superseded by a newer one on the same topic, prune the oldest/superseded entries in the same write rather than letting it grow unbounded — a lessons file nobody can read in full stops being useful context and becomes pure token overhead. Superseding a lesson is itself worth a one-line note ("superseded: <old lesson> — no longer applies because <reason>"), not a silent deletion.

## Tamper / trust posture

This is a plain-text advisory log, not a scored artifact — there is no scoring function here for a bad entry to quietly inflate. The real risk is a stale or wrong lesson steering a future run, which is exactly why the Read rule above treats every entry as advisory and re-verified against real tool output, never as a substitute for one. No checksum is warranted for what this file actually is.

## Self-improvement mode (the skill optimizing itself)

The sharpest form of "auto-improvement power": point SmartAutoResearch at **its own command files** and let its own loop improve them. This is the same trick ResearcherSkill used to tune itself — research → skill → use the skill to improve the skill — made explicit here.

```
$smartautoresearch
Goal: improve the clarity and instruction-adherence of commands/loop.md
Scope: commands/loop.md
--mode ai_judge
```

**This is still the classic loop — it does not skip Phase 1-3.** A self-improvement invocation is dispatched exactly like any other `Metric:`/`Scope:`-bearing goal (`SKILL.md`'s dispatch table routes it to the classic loop). Concretely, right now, before doing anything else:

1. **Read `commands/loop.md` in full** if you have not already loaded it this session — this file only adds self-optimization-specific criteria and guardrails on top of that protocol; it is never a substitute for it.
2. **Actually spawn `smartautoresearch-eval-agent`** (Phase 1 of `commands/loop.md`) to write the eval/rubric for the criteria below — do not write the eval yourself, and do not skip to editing the target file directly.
3. **Actually spawn `smartautoresearch-test-runner`** for the baseline (Phase 2) and every iteration (Phase 3) — do not generate the "after" version of the target file yourself and call it done.
4. **Actually run the Guard** (`scripts/smoke-test.sh`, see below) and **actually decide keep/discard** per Phase 3 Step 7 — a self-improvement run that never runs the guard, never computes a real before/after metric, and never produces a `loop-results.tsv` did not run the loop; it ran an unverified edit with a narrated process description. Treat a summary that claims "auto-heal loop," "independent score," or "3 attempts" with no corresponding TSV row, no eval artifact, and no sub-agent invocation as **not having happened** — this is exactly the failure this section exists to prevent.
5. If you cannot spawn an isolated sub-agent/session at all in your current host, this is a **stop-and-tell-the-user** condition (per `commands/loop.md` and `SKILL.md` Sub-Agents) — never silently fall back to "read the files, edit them, write a prose summary of a process that didn't run."

Criteria for skill-self-optimization (all must pass The Three Rules, `references/three-rules.md`):
- Instruction adherence: a fresh agent given the command file produces the documented output shape without extra prompting.
- No contradiction with `SKILL.md` or the four-way-separation contract.
- Token cost per invocation does not increase without a capability gain (mirror uditgoenka's "95% token reduction" discipline — leaner is better when behavior is equal).

Guardrails specific to self-optimization:
- The **eval/judge for a skill-file run must be a different context** from the file being optimized — the four-way separation (`references/four-way-separation.md`) matters even more here, because the optimizer editing `loop.md` must not also be scoring whether `loop.md` is good.
- Run the full smoke suite (`scripts/smoke-test.sh`) as the **Guard** on any self-optimization run that touches `scripts/` or anything a script depends on — a skill change that breaks its own deterministic seam is an automatic discard regardless of the judge score.
- Never let a self-optimization run loosen a safety invariant to "improve" a metric. Safety invariants are additions-only; a change that weakens `screen-cmd`, `screen-path`, or the no-auto-ship rule is an automatic discard even if every other signal improved.
- **This applies identically when the target is a *different* skill's files** (e.g. `Goal: improve <other-skill>/SKILL.md`), not just SmartAutoResearch's own — the target file's own Guard (its test/lint/build suite if it has one) substitutes for `smoke-test.sh`, and if the target has no Guard command, say so explicitly rather than silently skipping Phase 3's guard-check step.
