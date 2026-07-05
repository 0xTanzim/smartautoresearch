# SmartAutoResearch vs. Karpathy's autoresearch

## The short version

Karpathy showed that a 630-line script could run ~100 experiments overnight on a single metric, using git as its memory. That's the whole idea, and it works. SmartAutoResearch takes that same loop and points it at anything you can measure — not just ML training — then wraps it in an orchestrator, parallel web research, a cross-run learning file, and a deterministic seam you can actually run. The discipline underneath stays exactly the same.

## The core loop — the part we didn't touch

Break any of these and you've broken the thing that makes autoresearch work. So we left them alone.

| Principle (Karpathy `program.md`) | SmartAutoResearch |
|---|---|
| modify → verify → keep/discard → repeat | `commands/loop.md` Phase 3 (identical shape) |
| baseline first (iteration 0) | `commands/loop.md` Phase 2 |
| one change per iteration | Separation Rule 6 |
| mechanical metric, no vibes | deterministic `eval.py` mode; AI-judge mode is rubric-scored, not vibes |
| auto-rollback on no-improvement | Step 7 keep/discard/crash |
| git as memory | git integration + TSV log |
| simplicity criterion (equal metric + simpler = keep) | Step 7 "Simplicity Criterion" |
| never stop until interrupted | unlimited-mode NEVER-STOP escalation ladder |
| when stuck, think harder (re-read, combine near-misses, radical changes) | Stopping / escalation ladder + `research` dispatch |

All nine hold, and each one is cited above. That's the point — the new stuff is around the loop, never instead of it.

## What we added on top

| Capability | Karpathy | SmartAutoResearch |
|---|---|---|
| Domain | ML training (`train.py`, `val_bpb`, GPU) | anything with a number or a rubric |
| Budget | fixed 5-min wall-clock | iteration count (bounded default) or unlimited |
| Subcommands | one loop | 15 (loop, plan, debug, fix, security, ship, scenario, predict, learn, reason, probe, improve, research, evals, regression) |
| Orchestration | you do it by hand | goal-archetype classifier + router (`scripts/orchestrate.sh`) |
| Eval isolation | a human reads the number | four-way separation — optimizer / eval-agent / test-runner / judge never share context |
| Subjective targets | not covered | AI-judge mode + adversarial `reason` with blind judges |
| Web research | not covered | parallel, date-stamped `research` subcommand |
| Cross-run learning | git log | **Loop 4** persistent lessons memory (`references/lessons-memory.md`) |
| Judge-bias defense | not covered | position + verbosity + self-preference + style mitigations (`references/reason-judge-protocol.md`) |
| Regression safety | not covered | 8-dimension stability gate with a STABLE/UNSTABLE verdict |
| Command safety | disable all permissions and trust it | `screen-cmd` + `screen-path` screens, DB-URL allowlist, no-auto-ship |

## How it relates to uditgoenka/autoresearch

`uditgoenka/autoresearch` is the widely-used Claude Code / OpenCode / Codex skill — itself built on Karpathy — and it's where this skill's 13 orchestrator subcommands come from. SmartAutoResearch keeps that command surface and adds a few things on top:

- **A deterministic seam that actually runs.** `scripts/orchestrate.sh` + `scripts/score-regression.sh` are real, executable, and smoke-tested (119 assertions) — the routing and verdict logic was prose before.
- **The four-way eval separation, made a hard contract** instead of an idea.
- **A parallel `research` subcommand** with its own isolated sub-agent.
- **The Loop-4 lessons file** and a self-improvement mode, so the system compounds across runs.

Where uditgoenka is still ahead, and we borrowed the idea rather than pretend otherwise: the full **9-hook safety system**. We port the three that matter for safety — dangerous-cmd, privacy-block, and simplify-gate (`references/hooks.md`). On packaging we're at parity now: `scripts/transform.sh` + `scripts/install.sh` emit native trees for Claude Code, OpenCode, Codex, Antigravity, Cursor, Kiro, Gemini CLI, and Windsurf, plus a universal `AGENTS.md` tree for everything else that reads one — 9 targets in all. The loop's four sub-agents register natively on Claude Code (`.claude/agents/`), OpenCode (`.opencode/agent/`), and Codex (`.codex/agents/*.toml`), and spawn via a portable fallback (read the agent file, launch a fresh sub-agent) everywhere else, so the four-way separation actually runs on any host (`references/platforms.md`).

## A loading-model gap this skill specifically guards against

Kiro, OpenCode's `skill` tool, and Codex's Skills mechanism all auto-load `SKILL.md` only — they load `commands/*.md`/`agents/*.md`/`references/*.md` only when `SKILL.md`'s own prose imperatively tells the agent to open them ("progressive disclosure," per each host's own docs). A skill that just *mentions* those files in a dispatch table never gets them read on those hosts; the loop degrades into a shallow, unverified imitation instead of running the real four-way-separated protocol. `SKILL.md`'s "MANDATORY FILE-LOADING PROTOCOL" section exists specifically to close that gap — every dispatch branch is an imperative "read this file now," not a passive reference. This is a correctness fix, not a style choice: verified end-to-end against a toy target (real keep/discard, real TSV, real sub-agent isolation) after the fix, where an earlier passive-reference version of this file produced no real loop at all on a progressive-disclosure host.

## Which one should you use?

- **Want Karpathy's overnight ML loop exactly as he shipped it?** Use [karpathy/autoresearch](https://github.com/karpathy/autoresearch). It's purpose-built for that and you don't need anything else.
- **Want that loop for any codebase, in Claude Code or Codex, with the biggest install base?** [uditgoenka/autoresearch](https://github.com/uditgoenka/autoresearch).
- **Want the orchestrator, four-way eval isolation, parallel research, cross-run learning, and a seam that's genuinely tested?** That's this one.
