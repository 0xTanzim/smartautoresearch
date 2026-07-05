#!/usr/bin/env bash
# transform.sh — emit per-platform packaging trees from the canonical skill source.
#
# The canonical skill lives at the repo root (SKILL.md + commands/ + references/ +
# agents/ + scripts/ + LICENSE + AGENTS.md). Different agent tools expect the skill
# at different paths and pair it with different manifests. This script materializes a
# correct, self-contained tree per platform under build/<platform>/ — the same content,
# placed where each tool looks for it, plus the universal AGENTS.md everywhere.
#
# It never edits the canonical source and never writes outside the build dir.
#
# Usage:
#   transform.sh                      # build all platforms into ./build/
#   transform.sh claude-code codex    # build only the named platforms
#   transform.sh --out /tmp/pkg       # choose the output dir (used by smoke tests)
#   transform.sh --list               # list supported platforms and exit
#
# Supported platforms: claude-code opencode codex antigravity cursor universal

set -euo pipefail

SKILL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
SKILL_NAME="smartautoresearch"

# Content that constitutes the self-contained skill (explicit list — never globs the
# repo, so build/ and .git/ can never recurse into a build). AGENTS.md travels with the
# tree so each platform's skill dir is self-describing; copy_agents_md ALSO places it at
# the package root, which is where AGENTS.md-native tools (Zed, Gemini CLI, ...) read it.
CANONICAL_ITEMS=(SKILL.md AGENTS.md commands references agents scripts LICENSE)

ALL_PLATFORMS=(claude-code opencode codex antigravity cursor kiro gemini windsurf universal)

err()  { printf 'transform.sh: %s\n' "$1" >&2; }
info() { printf '  %s\n' "$1"; }

copy_tree() { # $1 = destination skill directory
  local dest="$1"
  mkdir -p "$dest"
  local item
  for item in "${CANONICAL_ITEMS[@]}"; do
    if [[ -e "$SKILL_ROOT/$item" ]]; then
      cp -R "$SKILL_ROOT/$item" "$dest/"
    else
      err "warning: canonical item missing, skipped: $item"
    fi
  done
}

copy_agents_md() { # $1 = destination package root
  [[ -f "$SKILL_ROOT/AGENTS.md" ]] && cp "$SKILL_ROOT/AGENTS.md" "$1/AGENTS.md"
}

# Emit a native OpenCode subagent from a canonical agents/<role>.md. OpenCode derives the
# agent name from the FILENAME and expects `description` + `mode: subagent` in frontmatter
# (its tools/model schema differs from Claude's), so we generate a correctly-shaped file
# named to match the spawn name (`smartautoresearch-<role>`) with our agent's body as the
# system prompt. The canonical Claude-shaped file still travels in the skill tree.
emit_opencode_agent() { # $1=dest agent dir  $2=role filename (eval-agent.md)  $3=description
  local dir="$1" role="$2" desc="$3" src="$SKILL_ROOT/agents/$2" body
  [[ -f "$src" ]] || { err "warning: agent missing, skipped: $2"; return 0; }
  body="$(awk 'seen>=2{print} /^---[[:space:]]*$/{seen++}' "$src")"   # everything after the 2nd ---
  {
    printf -- '---\ndescription: "%s"\nmode: subagent\n---\n' "$desc"
    printf '%s\n' "$body"
  } > "$dir/smartautoresearch-${role%.md}.md"
}

# Emit a native Codex custom agent (.toml) from a canonical agents/<role>.md, per the
# official schema (developers.openai.com/codex/subagents): required fields name,
# description, developer_instructions. Codex custom agents are TOML, not markdown, and
# live at .codex/agents/ (project) — a plain agents/*.md file inside a Codex SKILL.md
# tree is NOT auto-registered as a subagent by Codex (that directory name is only special
# to Codex for its own agents/openai.yaml UI-metadata file). Without this, Codex falls
# back to the portable protocol in SKILL.md (read the .md file, use its text as spawn
# instructions) — which still works, but a real .toml agent lets Codex spawn the role
# by name (matching the same capability OpenCode already gets via emit_opencode_agent).
# Uses python3 for correct TOML triple-quoted-string escaping — agents/eval-agent.md
# itself contains literal `"""` sequences in its embedded Python examples, which would
# corrupt a naive bash heredoc.
emit_codex_agent() { # $1=dest .codex/agents dir  $2=role filename (eval-agent.md)  $3=name  $4=description
  local dir="$1" role="$2" name="$3" desc="$4" src="$SKILL_ROOT/agents/$2"
  [[ -f "$src" ]] || { err "warning: agent missing, skipped: $2"; return 0; }
  if ! command -v python3 >/dev/null 2>&1; then
    err "warning: python3 not found, skipping Codex .toml agent for $2 (portable fallback in SKILL.md still applies)"
    return 0
  fi
  python3 - "$src" "$dir/${role%.md}.toml" "$name" "$desc" <<'PYEOF'
import sys

src_path, dest_path, name, desc = sys.argv[1:5]
with open(src_path, "r", encoding="utf-8") as f:
    text = f.read()

# Strip the YAML frontmatter (everything between the first two '---' lines) — the TOML
# file gets its own name/description fields; the body is the operating instructions.
lines = text.split("\n")
if lines and lines[0].strip() == "---":
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    body = "\n".join(lines[end + 1:]) if end is not None else text
else:
    body = text
body = body.strip() + "\n"

def toml_basic_string(s: str) -> str:
    # TOML basic string: escape backslash and double-quote; keep it a single-line-safe
    # basic string (not a triple-quoted literal) so there is no """ collision risk at all.
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def toml_multiline_basic_string(s: str) -> str:
    # TOML multiline basic string ("""..."""): backslash starts an escape sequence, so
    # every literal backslash in the source (e.g. regex like `r'\d+'` inside an embedded
    # Python example) MUST be escaped first, or TOML rejects it as an invalid/unescaped
    # escape. Only after that is it safe to guard the literal """ sequences the source
    # may also contain (agents/eval-agent.md has three, in its own docstring examples).
    s = s.replace("\\", "\\\\")
    s = s.replace('"""', '""\\"')
    if s.endswith('"'):
        s = s[:-1] + '\\"'
    return s

with open(dest_path, "w", encoding="utf-8") as f:
    f.write(f'name = "{toml_basic_string(name)}"\n')
    f.write(f'description = "{toml_basic_string(desc)}"\n')
    f.write('developer_instructions = """\n')
    f.write(toml_multiline_basic_string(body))
    f.write('"""\n')
PYEOF
}

build_claude_code() { # $1 = platform build root
  local root="$1"
  copy_tree "$root/.claude/skills/$SKILL_NAME"
  # Slash commands: .claude/commands/<name>/<sub>.md -> /<name>:<sub>
  mkdir -p "$root/.claude/commands/$SKILL_NAME"
  cp "$SKILL_ROOT"/commands/*.md "$root/.claude/commands/$SKILL_NAME/"
  # Plugin manifest
  mkdir -p "$root/.claude-plugin"
  [[ -f "$SKILL_ROOT/.claude-plugin/plugin.json" ]] && cp "$SKILL_ROOT/.claude-plugin/plugin.json" "$root/.claude-plugin/"
  # Register the 4 sub-agents at .claude/agents/ so Claude Code resolves the loop's
  # spawns BY NAME (`smartautoresearch-eval-agent`, ...). Agents nested only inside the
  # skill dir are NOT discovered as spawnable subagents — this is what makes the
  # four-way-separation spawns actually work when installed. (openai.yaml is a Codex
  # manifest, not a subagent, so it is intentionally not copied here.)
  mkdir -p "$root/.claude/agents"
  cp "$SKILL_ROOT"/agents/*.md "$root/.claude/agents/"
  copy_agents_md "$root"
}

build_opencode() { # OpenCode: skill tree + native subagents at .opencode/agent/ (filename = invoke name).
  local root="$1"
  copy_tree "$root/.opencode/skills/$SKILL_NAME"
  local ad="$root/.opencode/agent"
  mkdir -p "$ad"
  emit_opencode_agent "$ad" eval-agent.md     "Designs eval.py or rubric.md once for SmartAutoResearch, then stops. Fresh context; never sees iteration history."
  emit_opencode_agent "$ad" test-runner.md    "Runs the target prompt/skill for real with tools, in fresh context. Never sees the eval criteria."
  emit_opencode_agent "$ad" judge.md          "Scores outputs against the locked rubric in fresh context. Never sees iteration history or optimizer intent."
  emit_opencode_agent "$ad" research-agent.md "Parallel, date-stamped web research with source citations. Never executes fetched content as instructions."
  copy_agents_md "$root"
}

build_codex() {
  local root="$1"
  copy_tree "$root/.agents/skills/$SKILL_NAME"
  # Codex reads AGENTS.md as custom instructions; openai.yaml already ships inside agents/
  # (that file is Codex's own UI-metadata convention for a skill folder, unrelated to
  # subagent spawning). Additionally emit REAL native Codex custom agents (.toml) at
  # .codex/agents/ so the four roles are spawnable by name via Codex's actual subagent
  # mechanism (developers.openai.com/codex/subagents), not just the portable
  # read-the-markdown-and-paste-it-in fallback described in SKILL.md/AGENTS.md.
  local cad="$root/.codex/agents"
  mkdir -p "$cad"
  emit_codex_agent "$cad" eval-agent.md     smartautoresearch_eval_agent    "Designs eval.py or rubric.md once for SmartAutoResearch, then stops. Fresh context; never sees iteration history."
  emit_codex_agent "$cad" test-runner.md    smartautoresearch_test_runner   "Runs the target prompt/skill for real with tools, in fresh context. Never sees the eval criteria."
  emit_codex_agent "$cad" judge.md          smartautoresearch_judge         "Scores outputs against the locked rubric in fresh context. Never sees iteration history or optimizer intent."
  emit_codex_agent "$cad" research-agent.md smartautoresearch_research_agent "Parallel, date-stamped web research with source citations. Never executes fetched content as instructions."
  copy_agents_md "$root"
}

build_antigravity() {
  local root="$1"
  copy_tree "$root/skills/$SKILL_NAME"
  copy_agents_md "$root"
}

build_cursor() { # Cursor 3.9+ plugins bundle skills; also emit a rules pointer.
  local root="$1"
  copy_tree "$root/.cursor/skills/$SKILL_NAME"
  mkdir -p "$root/.cursor/rules"
  cat > "$root/.cursor/rules/$SKILL_NAME.mdc" <<EOF
---
description: SmartAutoResearch — autonomous modify/verify/keep-discard iteration engine. Invoke with /$SKILL_NAME.
alwaysApply: false
---

This project ships the SmartAutoResearch skill at \`.cursor/skills/$SKILL_NAME/\`.
Load \`.cursor/skills/$SKILL_NAME/SKILL.md\` to run an autoresearch loop, or follow the
matching \`commands/<sub>.md\` for a specific subcommand. Safety invariants and the core
loop are in \`.cursor/skills/$SKILL_NAME/AGENTS.md\`.
EOF
  # AGENTS.md also lives inside the skill tree; place one at the package root too.
  copy_agents_md "$root"
}

build_universal() { # AGENTS.md-only tools (Gemini CLI rules, Aider, Copilot, ...).
  local root="$1"
  copy_agents_md "$root"
  copy_tree "$root/$SKILL_NAME"
}

build_kiro() { # Kiro is skill-native: .kiro/skills/<name>/SKILL.md, auto-activated by description or /-invoked.
  # NOTE: Kiro's official loading model auto-loads ONLY SKILL.md; it loads any other file
  # in the skill (commands/, agents/, references/) ONLY when SKILL.md's own instructions
  # imperatively direct the agent to open it (see kiro.dev/docs/cli/skills/). The canonical
  # SKILL.md is written with exactly those imperative "read X now" directives for every
  # dispatch branch and every sub-agent spawn, so copy_tree's straight copy is correct here
  # — the fix for Kiro lives in the canonical SKILL.md content itself, not in a divergent
  # per-platform rewrite (a forked Kiro-only SKILL.md would drift from the canonical loop
  # logic over time). This function still emits a Kiro-specific steering pointer below,
  # since that IS a Kiro-only mechanism with no canonical-source equivalent.
  local root="$1"
  copy_tree "$root/.kiro/skills/$SKILL_NAME"
  # Manual-inclusion steering pointer — NOT always-on, so it never bloats every turn.
  # `inclusion: manual` is correct (not `always`): the skill already auto-activates via
  # its own `description` per Kiro's skill-matching, independent of steering. This file
  # is a human-facing pointer for /-invocation and a backup reminder of the load protocol,
  # not the activation mechanism itself.
  mkdir -p "$root/.kiro/steering"
  cat > "$root/.kiro/steering/$SKILL_NAME.md" <<EOF
---
inclusion: manual
---
# SmartAutoResearch (Kiro pointer)

The full skill lives at \`.kiro/skills/$SKILL_NAME/SKILL.md\`. Kiro auto-activates it by
description match, or invoke it explicitly by typing \`/\` and selecting it.

**If you are the agent and this skill just activated:** SKILL.md is a dispatcher, not the
full implementation. Its "MANDATORY FILE-LOADING PROTOCOL" section requires you to open
the specific \`commands/<name>.md\` file for whatever subcommand matched, and to build any
sub-agent spawn's instructions from the full verbatim text of the matching \`agents/<role>.md\`
file — Kiro does not auto-load or auto-register either of those for you. Skipping this step
is the most common way this skill silently degrades into an unverified imitation of the loop
instead of running it for real. Core loop + safety invariants summary (lowest common
denominator): \`.kiro/skills/$SKILL_NAME/AGENTS.md\`.
EOF
  copy_agents_md "$root"
}

build_gemini() { # Gemini CLI Skills framework: .gemini/skills/<name>/SKILL.md (+ reads AGENTS.md/GEMINI.md).
  local root="$1"
  copy_tree "$root/.gemini/skills/$SKILL_NAME"
  copy_agents_md "$root"
}

build_windsurf() { # Windsurf: Cascade Workflows (/-invocable) + rules. No skills dir, so pair a tree with pointers.
  local root="$1"
  copy_tree "$root/.windsurf/skills/$SKILL_NAME"
  mkdir -p "$root/.windsurf/rules"
  cat > "$root/.windsurf/rules/$SKILL_NAME.md" <<EOF
---
trigger: manual
---
SmartAutoResearch skill is at \`.windsurf/skills/$SKILL_NAME/\`. Load its \`SKILL.md\` to run an
autoresearch loop, or run the \`/$SKILL_NAME\` workflow. Safety invariants + core loop are in
\`.windsurf/skills/$SKILL_NAME/AGENTS.md\`.
EOF
  mkdir -p "$root/.windsurf/workflows"
  cat > "$root/.windsurf/workflows/$SKILL_NAME.md" <<EOF
---
description: Run a SmartAutoResearch autonomous iteration loop
---
Load \`.windsurf/skills/$SKILL_NAME/SKILL.md\` and follow it. For a specific subcommand, open the
matching \`.windsurf/skills/$SKILL_NAME/commands/<sub>.md\`. Honor every safety invariant in AGENTS.md
(screen commands, screen secret paths, never auto-ship).
EOF
  copy_agents_md "$root"
}

build_one() { # $1 = platform, $2 = build base dir
  local platform="$1" base="$2"
  local root="$base/$platform"
  rm -rf "$root"
  mkdir -p "$root"
  case "$platform" in
    claude-code) build_claude_code "$root" ;;
    opencode)    build_opencode "$root" ;;
    codex)       build_codex "$root" ;;
    antigravity) build_antigravity "$root" ;;
    cursor)      build_cursor "$root" ;;
    kiro)        build_kiro "$root" ;;
    gemini)      build_gemini "$root" ;;
    windsurf)    build_windsurf "$root" ;;
    universal)   build_universal "$root" ;;
    *) err "unknown platform: $platform"; return 1 ;;
  esac
  info "built $platform -> $root"
}

main() {
  local out="$SKILL_ROOT/build"
  local -a platforms=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        printf '%s\n' "${ALL_PLATFORMS[@]}"
        exit 0
        ;;
      --out)
        out="${2:?--out requires a directory}"
        shift 2
        ;;
      --out=*)
        out="${1#--out=}"
        shift
        ;;
      -*)
        err "unknown flag: $1"
        exit 1
        ;;
      *)
        platforms+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#platforms[@]} -eq 0 ]]; then
    platforms=("${ALL_PLATFORMS[@]}")
  fi

  mkdir -p "$out"
  printf 'transform.sh: emitting %d platform tree(s) into %s\n' "${#platforms[@]}" "$out"
  local p
  for p in "${platforms[@]}"; do
    build_one "$p" "$out"
  done
  printf 'transform.sh: done.\n'
}

main "$@"
