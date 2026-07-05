# Reason Judge Protocol

## Adversarial Refinement Loop

```
Round N:
  1. Author-A generates candidate (or incumbent from previous round)
  2. Critic attacks candidate — MUST find weaknesses (forced adversarial)
  3. Author-B reads task + candidate-A + critique → produces candidate-B
  4. Synthesizer reads A + B → produces hybrid candidate-AB
  5. Judge panel receives 3 candidates with randomized labels → picks winner
  6. Winner becomes incumbent for round N+1
```

## Agent Isolation Rules

- Each agent (Author-A, Critic, Author-B, Synthesizer, Judges) runs COLD START
- No shared session state between agents — prevents sycophancy
- Agents receive ONLY: task description + relevant candidate(s) + critique
- Judges receive candidates with randomized labels (Label-X, Label-Y, Label-Z)
- Judges MUST compare and rank — "all are good" is not a valid verdict

## Critic Protocol

The critic MUST:
1. Identify at least 3 specific weaknesses in the candidate
2. Provide concrete evidence for each weakness
3. Suggest what a superior candidate would do differently
4. Rate candidate on domain-specific criteria (1-10 scale)
5. Never compliment the candidate — role is purely adversarial

## Judge Protocol

Each judge receives:
- Task description (identical for all judges)
- 3 candidates with randomized labels (Label-X, Label-Y, Label-Z)
- Evaluation criteria relevant to the domain

Each judge MUST:
1. Evaluate each candidate independently on all criteria
2. Produce a ranking (1st, 2nd, 3rd) with reasoning
3. Select a winner with one-paragraph justification
4. Label randomization prevents position bias

Verdict: majority vote. Tie → synthesized candidate (Label-Z) wins.

## Judge Bias Guards (all judges, every round)

Label randomization above handles **position bias**. Judges must also actively counter the other documented biases — as of 2026 research, style bias is empirically the *largest* judge bias, exceeding position bias, so randomized labels alone are not enough:

- **Verbosity / length** — the longest candidate is not the best candidate. Do not let length stand in for substance; a candidate does not win for covering more ground more wordily.
- **Style / format** — do not let polish, confident tone, or richer formatting decide the ranking. Judge the argument's substance against the domain criteria; a plainly-worded stronger argument beats a slickly-worded weaker one.
- **Self-preference** — do not favor the candidate that most resembles how you would have written it. Resemblance to your own defaults is not a criterion.
- **Measure, don't assume** — the anti-herd rule (a judge may not simply echo the others) and the forced-ranking rule (no "all are good") exist precisely because these biases are invisible unless the protocol forces them into the open. A judge that cannot articulate *why* one candidate beats another on the criteria has not judged, only reacted.

Each judge's one-paragraph justification must reference the domain criteria explicitly, so a reader can audit whether length/style/self-preference — rather than substance — drove the verdict.

## Convergence Detection

| Mode | Stop Condition |
|---|---|
| Convergent (default) | Same incumbent wins N consecutive rounds (default N=3) |
| Creative | Never auto-stops; runs until iteration limit |
| Debate | Same as convergent but no synthesis step |

## Oscillation Guard

If the incumbent changes more than 5 times in the last 8 rounds → recommend early stop. The candidates are not converging — further rounds waste context.

## Domain-Specific Judge Criteria

| Domain | Criteria |
|---|---|
| Software architecture | Scalability, maintainability, performance, security, simplicity |
| Product strategy | Market fit, feasibility, differentiation, risk, timeline |
| Business decision | ROI, risk, alignment, resource requirements, reversibility |
| Security approach | Coverage, false positive rate, practicality, compliance |
| Research hypothesis | Testability, novelty, evidence support, explanatory power |
| Content/writing | Clarity, accuracy, engagement, completeness, actionability |

## Use as an Independent Verify Hop

When the orchestrator routes a `verify` hop (see `references/orchestrator-routing.md` — "Independent Verify & Overfit Guard"), it dispatches here with the accepted change as candidate-A and no incumbent — the round runs as a one-shot adversarial check rather than a multi-round convergence search. The Critic's 3-weaknesses-minimum rule still applies in full; this is what prevents a loop from rubber-stamping its own accepted change.

## Output Files

| File | Content |
|---|---|
| `reason-results.tsv` | Per-round: round, candidate_label, judge_verdict, convergence_count, description |
| `lineage.md` | Full history of all candidates + critiques + judge reasoning |
| `summary.md` | Final winner, convergence trajectory, key insights |
| `handoff.json` | Chain handoff with winner as primary finding |

## TSV Schema

```
round	timestamp	candidate_label	judge_verdict	convergence_count	description
1	2026-07-04T00:00:00Z	Candidate-A	winner	1	Event sourcing with CQRS
2	2026-07-04T00:05:00Z	Candidate-AB	winner	1	Hybrid: event sourcing for writes, read projections
3	2026-07-04T00:10:00Z	Candidate-AB	winner	2	Refined hybrid with materialized views
4	2026-07-04T00:15:00Z	Candidate-AB	winner	3	CONVERGED — same approach refined
```

## Judge isolation: prose-enforced here, by design

`commands/loop.md` binds the eval / test-runner / judge to *registered* sub-agents (a hard structural boundary). The `reason` panel and `predict` personas are deliberately different: they are inline debate roles, not registered agents, so their blind-judge isolation — a judge scoring without seeing the optimizer's intent or the other side's identity — is enforced by **cold-start context discipline in prose**, not by a separate agent process.

This is an intentional trade, not an oversight: spinning up a registered agent per persona per round would cost far more than the isolation is worth, and the Critic's minimum-weaknesses rule plus fresh-context-per-score already deliver the guarantee. When you genuinely need the stronger structural boundary — e.g. a high-stakes independent verify hop — bind the judge to the registered `smartautoresearch-judge` agent instead of an inline role.
