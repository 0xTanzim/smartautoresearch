# Platform Compatibility Matrix

SmartAutoResearch targets every mainstream agent tool through the two conventions the ecosystem
converged on in 2026: **`SKILL.md`** (on-demand Agent Skills) for skill-native tools, and
**`AGENTS.md`** (universal instruction file, Linux Foundation / Agentic AI Foundation standard,
read by 30+ tools) for everything else. `scripts/transform.sh` emits a correct per-platform tree;
`scripts/install.sh` places it.

## Two support tiers (be honest about the difference)

- **Tier 1 — native skill:** the tool has an Agent-Skills mechanism and loads `SKILL.md` on demand, including the sub-agents, references, and the deterministic scripts. Full capability.
- **Tier 2 — instructions file:** the tool has no "skill" concept but reads `AGENTS.md` on every task. It gets the core loop + safety invariants + a pointer to the `commands/*.md` specs, which the agent follows directly. The workflow runs; the on-demand-loading ergonomics don't.

Both tiers enforce the same safety invariants (they live in both `SKILL.md` and `AGENTS.md`).

## Matrix

| Tool | Tier | Loads | Skill path (project / global) | Invoke |
|---|---|---|---|---|
| Claude Code | 1 | SKILL.md + plugin | `.claude/skills/smartautoresearch/` / `~/.claude/skills/…` | `/smartautoresearch`, `/smartautoresearch:fix` |
| OpenCode | 1 | SKILL.md (also reads `.claude/` + `.agents/`) | `.opencode/skills/smartautoresearch/` / `~/.config/opencode/skills/…` | `skill` tool / ask to run it |
| OpenAI Codex | 1 | SKILL.md + AGENTS.md | `.agents/skills/smartautoresearch/` / `~/.codex/skills/…` | `$smartautoresearch`, `$smartautoresearch fix` |
| Google Antigravity | 1 | SKILL.md + AGENTS.md | `skills/smartautoresearch/` (workspace) / global skills dir | `/`-command / ask; rules via AGENTS.md |
| Cursor (3.9+) | 1 | SKILL.md (plugin) + rules | `.cursor/skills/smartautoresearch/` + `.cursor/rules/*.mdc` / `~/.cursor/…` | `/smartautoresearch` command |
| Kiro | 1 | SKILL.md + steering | `.kiro/skills/smartautoresearch/` / `~/.kiro/skills/…` (+ `.kiro/steering/` pointer) | auto-activate by description, or `/` to pick |
| Gemini CLI | 1 | SKILL.md (Skills framework) + AGENTS.md/GEMINI.md | `.gemini/skills/smartautoresearch/` / `~/.gemini/skills/…` | auto-activate; `/` custom commands too |
| Windsurf (Cascade) | 1 | Workflows + rules (SKILL.md tree bundled) | `.windsurf/skills/…` + `.windsurf/workflows/smartautoresearch.md` + `.windsurf/rules/` | `/smartautoresearch` workflow |
| VS Code / Roo Code / Cline | 1* | agentskills.io SKILL.md (open standard) | tool's skills dir (agentskills-compatible) | tool's skill/command UI |
| Zed | 2 | AGENTS.md (+ MCP for tools) | — (no skill mechanism yet; tracking zed#57890) | follow `commands/*.md` |
| GitHub Copilot | 2 | AGENTS.md | — | follow `commands/*.md` |
| Aider | 2 | AGENTS.md | — | follow `commands/*.md` |
| JetBrains Junie | 2 | AGENTS.md | — | follow `commands/*.md` |
| Amazon Q / Amp / Devin / Jules / Factory | 2 | AGENTS.md | — | follow `commands/*.md` |

`transform.sh` emits native trees for the 8 concrete Tier-1 targets — **claude-code, opencode, codex, antigravity, cursor, kiro, gemini, windsurf** — plus a **universal** tree (AGENTS.md + the skill) for every Tier-2 (and agentskills.io-compatible Tier-1*) tool.

Notes:
- **The `SKILL.md` tree is the Agent Skills Open Standard (agentskills.io, Anthropic Dec-2025; adopted by GitHub, Microsoft, Cursor, Roo Code, VS Code, Gemini, Codex, Kiro, OpenCode, 20-40+ tools).** So the same tree drops into most Tier-1 tools **unchanged** — only the install *path* differs, which is exactly what `transform.sh` handles. `1*` = agentskills-compatible but with a tool-specific skills dir; use the `universal` tree or the nearest native target and adjust the path per `references/platforms.md`.
- **OpenCode reads `.claude/skills/` and `.agents/skills/` too**, so the claude-code or codex tree also works there unchanged — the `.opencode/` tree is the native-first install.
- **Kiro** (skill-native): auto-activates a skill by its `description`, or the user types `/` to pick it; the emitted `.kiro/steering/smartautoresearch.md` is a **manual-inclusion** pointer so it never bloats every turn.
- **Windsurf** has no skills dir — it uses Cascade **Workflows** (`/`-invocable) + rules; the transform bundles the full tree under `.windsurf/skills/` and wires a `/smartautoresearch` workflow + a rule pointer to it.
- **Zed** has no Agent-Skills mechanism as of mid-2026 (open request `zed-industries/zed#57890`); Tier 2 via `AGENTS.md`, and the deterministic scripts can be wrapped as MCP tools if desired.
- The skill `name` (`smartautoresearch`) satisfies the shared naming rule (`^[a-z0-9]+(-[a-z0-9]+)*$`, ≤64 chars, matches its directory), so it validates everywhere without renaming.

## Build & install

```bash
# Emit per-platform trees into ./build/<platform>/
scripts/transform.sh                 # all 9 platform trees
scripts/transform.sh kiro gemini     # just the named ones
scripts/transform.sh --list          # claude-code opencode codex antigravity cursor kiro gemini windsurf universal

# Install into a target tool's config (project or global scope)
scripts/install.sh --platform kiro --project .
scripts/install.sh --platform gemini --global
scripts/install.sh --platform windsurf --project .
scripts/install.sh --platform universal --project .   # AGENTS.md + tree for Zed / Copilot / Aider / etc.
```

`install.sh` copies only (never destructive), does a project install as-is, and for a global (`~`) install merges each tool's config dir correctly (e.g. codex → `~/.codex/skills/`, opencode → `~/.config/opencode/skills/`, windsurf → `~/.codeium/windsurf/`) after an explicit confirmation.

## Sub-agents: registration & the portable spawn fallback

The loop and orchestrator delegate to four sub-agents — `smartautoresearch-eval-agent`, `-test-runner`, `-judge`, `-research-agent` (defined in `agents/*.md`). For the loop to actually run its four-way separation, the host must be able to **spawn** them:

- **Claude Code** — `scripts/transform.sh` places the four `agents/*.md` at `.claude/agents/`, where Claude Code auto-registers them, so spawning by name (`smartautoresearch-eval-agent`) resolves natively. Installed as a plugin, the `agents/` dir at the plugin root registers the same way.
- **OpenCode** — `transform.sh` generates native subagents at `.opencode/agent/smartautoresearch-<role>.md` (OpenCode frontmatter: `description` + `mode: subagent`; the invoke name comes from the filename), so they resolve by name and via the Task tool.
- **Codex** — custom agents are TOML and Codex steers via AGENTS.md, so the skill uses the **portable fallback** through Codex's child-thread subagents; AGENTS.md carries the spawn rule.
- **Every other host (Kiro, Cursor, Gemini, Windsurf, …)** — the **portable fallback** (see SKILL.md "Sub-Agents"): launch a fresh sub-agent and pass the contents of `agents/<role>.md` as its instructions. Same isolated, fresh-context result — no host-specific registration required.

The hard rule either way: a role that cannot be spawned is a **stop-and-tell-the-user** condition. The main agent must never run the eval, generate outputs, or score itself — that silently collapses the separation that makes the metric trustworthy.
