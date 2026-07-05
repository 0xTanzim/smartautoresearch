# Safety Hooks (optional platform integration)

SmartAutoResearch is safe by default **without** any hooks — every shell command the orchestrator derives is screened through `scripts/orchestrate.sh screen-cmd`, and no command reaches a shell without passing it. This file documents an **optional** hardening layer for host platforms that support event hooks (e.g. Claude Code's `PreToolUse`/`SessionStart`/`UserPromptSubmit` hooks), adapted from the 9-hook system in `uditgoenka/autoresearch`.

Hooks are strictly additive defense-in-depth. If your platform has no hook mechanism, the skill still enforces its safety invariants through the in-loop screens described in `SKILL.md`.

## The three hooks worth porting

| Hook | Fires on | What it does | Backed by |
|---|---|---|---|
| **dangerous-cmd** | before any shell exec | Refuses `rm -rf`, fork bombs, `curl\|sh`, force-push, destructive SQL | `scripts/orchestrate.sh screen-cmd` (already the in-loop default) |
| **privacy-block** | before any file read | Refuses reading `.env`, SSH keys, credential stores, token files into context | `scripts/orchestrate.sh screen-path` (this skill) |
| **simplify-gate** | before ship / on demand | Warns/blocks when a change balloons LOC past a budget — enforces the simplicity criterion | LOC check (see below) |

The other six hooks in the upstream 9-hook system (scout-block for context pollution, iteration-context re-injection after compaction, subagent-context, dev-rules-reminder, session-init, stop-notify) are host-convenience features, not safety invariants — port them if your platform benefits, but they are out of scope for the skill's correctness.

## dangerous-cmd → `screen-cmd`

Already the in-loop default. To wire it as a platform `PreToolUse` hook, call:

```bash
scripts/orchestrate.sh screen-cmd "<the command about to run>"
# exit 0 + "allow"  -> let it run
# exit 2 + "refuse" -> block it
```

## privacy-block → `screen-path`

Blocks the loop (or a hook) from reading files that commonly hold secrets into context. Screens a path, not a command:

```bash
scripts/orchestrate.sh screen-path "/abs/path/being/read"
# exit 0 + "allow"  -> safe to read
# exit 2 + "refuse" -> a secrets-bearing path; do not read into context
```

Refused patterns include `.env` / `.env.*`, `*.pem` / `*.key` / `id_rsa` / `id_ed25519`, `.ssh/`, `.aws/credentials`, `.npmrc` / `.pypirc` with tokens, `credentials.json`, `secrets.*`, `.git-credentials`, and `*.p12` / `*.keystore`. This mirrors the global steering rule "be cautious with files likely to contain secrets" — the test-runner and research agents in particular should screen a path before reading it into their fresh context.

Override for a genuinely-needed read is a human decision, never an autonomous one: the loop refuses and surfaces the path; the user explicitly re-authorizes.

## simplify-gate → LOC budget

Enforces the karpathy/uditgoenka "simplicity wins" rule mechanically. Before a `ship`, or on demand, compare the change's net LOC against a budget:

- **Warn** at +400 net LOC on a single change/unit.
- **Block ship** at +800 net LOC without an explicit justification recorded in the ship checklist.

This is advisory pressure toward the simplicity criterion already in `commands/loop.md` Step 7 — it does not override a genuine, justified large change, it forces the justification to be written down.

## Configuration convention

Following the upstream convention, each hook is on by default and individually disableable via environment variable, so a host integration can opt out without editing the skill:

```bash
export SAR_DISABLE_DANGEROUS_CMD=1   # disable the dangerous-cmd screen in the hook layer
export SAR_DISABLE_PRIVACY_BLOCK=1   # disable the privacy/secrets path screen
export SAR_DISABLE_SIMPLIFY_GATE=1   # disable the LOC budget gate
```

Note: disabling the **hook-layer** screen does not disable the **in-loop** `screen-cmd`, which is not optional — the orchestrator always screens derived commands regardless of hook configuration. The env vars only govern the optional host-hook layer.
