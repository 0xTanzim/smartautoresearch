#!/usr/bin/env bash
# orchestrate.sh — deterministic routing seam for the smartautoresearch orchestrator loop.
#
# This is the ONLY place goal-classification, next-hop routing, plateau detection,
# and command-safety-screening logic lives. Command markdown files call this script
# instead of re-implementing routing/safety logic in prose — keeps the orchestrator's
# decision-making testable and auditable outside the LLM's own reasoning.
#
# Usage:
#   orchestrate.sh classify "<goal text>"
#   orchestrate.sh next-hop <orchestrator-state.json>
#   orchestrate.sh units <orchestrator-state.json>
#   orchestrate.sh plateau <orchestrator-state.json> [window]
#   orchestrate.sh screen-cmd "<candidate shell command>"
#   orchestrate.sh verdict <results.tsv>              # delegates to score-regression.sh
#   orchestrate.sh validate-state <orchestrator-state.json>
#   orchestrate.sh screen-state-predicate <orchestrator-state.json>
#
# Exit codes: 0 = success/pass, 1 = usage or validation failure, 2 = refused (unsafe).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

err() { printf 'orchestrate.sh: %s\n' "$1" >&2; }

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is required but not installed. Install jq (e.g. apt-get install jq / brew install jq)."
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    err "file not found: $path"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# classify — map a free-form goal string to a Goal Archetype (see
# references/orchestrator-routing.md for the authoritative keyword table).
# Fuzzy keyword matching; first matching archetype wins in priority order
# below (more specific archetypes are checked first, per routing.md).
# ---------------------------------------------------------------------------
cmd_classify() {
  local goal="${1:-}"
  if [[ -z "$goal" ]]; then
    err "classify requires a goal string"
    exit 1
  fi
  local g
  g="$(printf '%s' "$goal" | tr '[:upper:]' '[:lower:]')"

  # Priority order matters: ship-ready before fix-broken before explore, etc.
  # This mirrors references/orchestrator-routing.md "prefer more specific" rule.
  local archetype="" mode=""

  # NOTE: no apostrophes inside these ERE literals — an unescaped single quote
  # inside an unquoted [[ =~ ]] regex breaks bash's own parsing of this file
  # (it gets treated as a quote-open and swallows subsequent lines). Use
  # "cannot run" / "whats new" style phrasing instead of "can't run" / "what's new".
  if [[ "$g" =~ (ship|release|deploy|publish|production-ready|merge) ]]; then
    archetype="ship-ready"; mode="loop"
  elif [[ "$g" =~ (security|vulnerabilit|owasp|cve|harden|lock down) ]]; then
    archetype="harden"; mode="loop"
  elif [[ "$g" =~ (fix|broken|failing|error|crash|bug|cannot run|tests fail) ]]; then
    archetype="fix-broken"; mode="loop"
  elif [[ "$g" =~ (improve|optimize|increase|reduce|raise|boost|iterate|maximize|minimize|tune|refine|lift|faster|smaller|coverage|score|pass.?rate|hit.?rate|update|revise|enhance|polish|rework|upgrade) ]]; then
    archetype="optimize-metric"; mode="loop"
  elif [[ "$g" =~ (what should i build|ideas|improvements|prd|roadmap) ]]; then
    # Must be checked before build-feature: "what should I build" contains
    # "build" and would otherwise be swallowed by the broader pattern below.
    archetype="what-to-build"; mode="dispatch"
  elif [[ "$g" =~ (build|add|implement|create|new feature|acceptance test) ]]; then
    archetype="build-feature"; mode="loop"
  elif [[ "$g" =~ (document|wiki|generate docs|explain codebase|write guide) ]]; then
    archetype="document"; mode="dispatch"
  elif [[ "$g" =~ (which approach|compare options|design decision|architecture choice) ]]; then
    archetype="decide-design"; mode="dispatch"
  elif [[ "$g" =~ (research|latest|current|news|find out|look up|whats new) ]]; then
    archetype="research"; mode="dispatch"
  elif [[ "$g" =~ (understand|explore|investigate|what does|how does|edge case) ]]; then
    archetype="explore"; mode="loop"
  else
    archetype="explore"; mode="loop"
  fi

  require_jq
  jq -n --arg a "$archetype" --arg m "$mode" --arg g "$goal" \
    '{archetype: $a, mode: $m, goal: $g}'
}

# ---------------------------------------------------------------------------
# next-hop — read orchestrator-state.json, apply the router decision table
# (references/orchestrator-routing.md) in strict first-match-wins order.
# ---------------------------------------------------------------------------
cmd_next_hop() {
  local state_file="${1:-}"
  require_file "$state_file"
  require_jq

  cmd_validate_state "$state_file" >/dev/null || {
    err "next-hop refused: orchestrator-state.json failed validation"
    exit 1
  }

  local errors regression_verdict untested_gaps pending_verify predicate_met \
        requirements_drift hop_outcome preset_remaining plateau_flag

  errors=$(jq -r '.last_handoff.findings // [] | map(select(.severity=="critical" or .severity=="high" or .type=="error")) | length' "$state_file" 2>/dev/null || echo 0)
  regression_verdict=$(jq -r '.last_handoff.verdict // "none"' "$state_file")
  untested_gaps=$(jq -r '.untested_gaps // false' "$state_file")
  pending_verify=$(jq -r '.pending_verify // false' "$state_file")
  requirements_drift=$(jq -r '.requirements_drift // false' "$state_file")
  predicate_met=$(jq -r '.predicate_met // false' "$state_file")
  hop_outcome=$(jq -r '.last_hop_outcome // "none"' "$state_file")
  preset_remaining=$(jq -r '.preset_pipeline_remaining // [] | length' "$state_file")
  plateau_flag=$(cmd_plateau "$state_file" 2>/dev/null || echo "false")

  # First match wins — same order as orchestrator-routing.md's decision table.
  if [[ "$errors" -gt 0 ]]; then
    echo "fix"; return 0
  fi
  if [[ "$regression_verdict" == "UNSTABLE" ]]; then
    echo "regression"; return 0
  fi
  if [[ "$regression_verdict" == "BASELINE_UNAVAILABLE" ]]; then
    # The regression gate could not establish a baseline, so stability is
    # UNVERIFIED. Never treat that as "not unstable" and proceed on an unverified
    # gate — route to debug to establish the baseline/tests first (GAP D6).
    echo "debug"; return 0
  fi
  if [[ "$untested_gaps" == "true" ]]; then
    echo "debug"; return 0
  fi
  if [[ "$pending_verify" == "true" ]]; then
    echo "verify"; return 0
  fi
  if [[ "$requirements_drift" == "true" ]]; then
    # A drifted predicate must be re-validated before "done" can be trusted, so
    # this is checked BEFORE predicate_met. But it must also CLEAR, or the loop
    # re-probes forever: key off the drift_resolution a `probe --from-drift` hop
    # folds into last_handoff (commands/probe.md Chain Handoff).
    #   (unresolved)                  -> probe --from-drift once
    #   obsolete                      -> plan (re-derive the predicate from scratch)
    #   confirmed_no_change | revised -> resolved: fall through to normal routing
    local drift_res
    drift_res=$(jq -r '.last_handoff.drift_resolution // "none"' "$state_file")
    case "$drift_res" in
      none)     echo "probe --from-drift"; return 0 ;;
      obsolete) echo "plan"; return 0 ;;
      *)        : ;;
    esac
  fi
  if [[ "$predicate_met" == "true" ]]; then
    echo "DONE"; return 0
  fi
  if [[ "$hop_outcome" == "blocked" || "$hop_outcome" == "failed" ]]; then
    local has_retry
    has_retry=$(jq -r '.retry_route_available // false' "$state_file")
    if [[ "$has_retry" != "true" ]]; then
      echo "BLOCKED"; return 0
    fi
  fi
  if [[ "$plateau_flag" == "true" ]]; then
    echo "PLATEAU"; return 0
  fi
  if [[ "$preset_remaining" -gt 0 ]]; then
    jq -r '.preset_pipeline_remaining[0]' "$state_file"
    return 0
  fi
  # All preset steps exhausted, predicate not met — convergence re-check.
  echo "regression"
}

# ---------------------------------------------------------------------------
# units — scalar "units remaining" signal (lower is better). Pulled from the
# most recent handoff.json fields the caller folded into orchestrator-state.json.
# Returns "unknown" (not 0) when no usable signal exists, so plateau logic
# can distinguish "no progress" from "no signal" per the safety invariant
# "unknown-units cycles excluded from plateau counter".
# ---------------------------------------------------------------------------
cmd_units() {
  local state_file="${1:-}"
  require_file "$state_file"
  require_jq

  local crit metric_gap has_findings
  # 1. Active critical/high findings dominate the signal (fix-broken / harden).
  #    A jq error (no parseable handoff) -> unknown, never a spurious 0.
  crit=$(jq -r '.last_handoff.findings // [] | map(select(.severity=="critical" or .severity=="high")) | length' "$state_file" 2>/dev/null || echo "unknown")
  if [[ "$crit" == "unknown" ]]; then echo "unknown"; return 0; fi
  if [[ "$crit" -gt 0 ]]; then echo "$crit"; return 0; fi

  # 2. optimize-metric signal: the explicit metric gap (lower is better). This
  #    MUST be preferred over a zero findings-count, or an optimize handoff (which
  #    carries no findings) reads as units=0 every cycle and triggers a FALSE
  #    plateau that stops a genuinely-improving run. See references/orchestrator-state.md.
  metric_gap=$(jq -r '.last_handoff.config.metric_gap // "null"' "$state_file")
  if [[ "$metric_gap" != "null" && "$metric_gap" != "" ]]; then echo "$metric_gap"; return 0; fi

  # 3. No metric gap: fall back to total open findings. A present-but-empty
  #    findings array is genuine convergence (0); a wholly absent handoff is
  #    "no signal" -> unknown (excluded from the plateau window, never counted as 0).
  has_findings=$(jq -r 'if (.last_handoff | type == "object") and (.last_handoff | has("findings")) then "yes" else "no" end' "$state_file" 2>/dev/null || echo "no")
  if [[ "$has_findings" == "yes" ]]; then
    jq -r '.last_handoff.findings | length' "$state_file"
    return 0
  fi
  echo "unknown"
}

# ---------------------------------------------------------------------------
# plateau — true if units-remaining has been flat or worse for N consecutive
# *known* cycles (default 5). Unknown-units cycles are excluded from the
# window entirely (neither count toward nor reset the streak on their own).
# ---------------------------------------------------------------------------
cmd_plateau() {
  local state_file="${1:-}"
  local window="${2:-5}"
  require_file "$state_file"
  require_jq

  local history_len known_tail
  history_len=$(jq -r '.units_remaining_history // [] | length' "$state_file")
  if [[ "$history_len" -lt 2 ]]; then
    echo "false"
    return 0
  fi

  # Coerce every entry to a JSON number (tonumber?): numeric strings normalize,
  # non-numeric entries such as "unknown" error out and are dropped from the
  # window entirely. This guarantees the `>=` comparison below is numeric, never
  # lexicographic (otherwise "9" >= "10" would be true and a 10->9 improvement
  # would falsely register as a plateau). See references/orchestrator-state.md
  # "units_remaining_history" for the type contract.
  known_tail=$(jq -c --argjson w "$window" \
    '[ .units_remaining_history // [] | .[] | tonumber? ] | .[-($w+1):]' \
    "$state_file")

  local count
  count=$(echo "$known_tail" | jq 'length')
  if [[ "$count" -lt "$((window + 1))" ]]; then
    echo "false"
    return 0
  fi

  # Plateau if no strict improvement across the whole window (non-increasing
  # is fine, i.e. never got lower than the earliest value in this window).
  echo "$known_tail" | jq -e --argjson w "$window" '
    (.[0] as $first | .[1:] | all(. >= $first))
  ' >/dev/null 2>&1 && echo "true" || echo "false"
}

# ---------------------------------------------------------------------------
# screen-cmd — refuse dangerous shell commands before they are ever executed
# by a downstream subcommand. This is the ONLY safety gate for derived
# commands — every command read from a persisted state file on resume MUST
# be re-screened here, never trusted from the file alone.
# ---------------------------------------------------------------------------
cmd_screen_cmd() {
  local candidate="${1:-}"
  if [[ -z "$candidate" ]]; then
    err "screen-cmd requires a command string"
    exit 1
  fi

  local -a deny_patterns=(
    'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f'   # rm -rf, rm -fr, rm -Rf, etc.
    'rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r'
    'rm[[:space:]]+.*--recursive'            # rm --recursive (long form of -r)
    'rm[[:space:]]+.*--force'                # rm --force (long form of -f)
    ':\(\)\{[^}]*:\|:&?[^}]*\};?:'           # classic fork bomb :(){ :|:& };:
    'curl[^|]*\|[[:space:]]*sh'
    'curl[^|]*\|[[:space:]]*bash'
    'wget[^|]*\|[[:space:]]*sh'
    'wget[^|]*\|[[:space:]]*bash'
    '>[[:space:]]*/dev/sd[a-z]'
    'mkfs\.'
    'dd[[:space:]]+if=.*of=/dev/'
    'chmod[[:space:]]+-R[[:space:]]+777'
    'AKIA[0-9A-Z]{16}'                       # embedded AWS key literal
    'sk-[a-zA-Z0-9]{20,}'                    # embedded API key literal
    'ghp_[a-zA-Z0-9]{36}'                    # embedded GitHub token literal
    '--force[[:space:]]+push'
    'git[[:space:]]+push[[:space:]]+.*--force'
    'git[[:space:]]+push[[:space:]].*-[a-zA-Z]*f'   # git push -f / -fu short-form force
    'DROP[[:space:]]+DATABASE'
    'DROP[[:space:]]+TABLE'
    'TRUNCATE[[:space:]]+TABLE'
  )

  local pattern
  for pattern in "${deny_patterns[@]}"; do
    if [[ "$candidate" =~ $pattern ]]; then
      err "refused: command matches unsafe pattern ($pattern)"
      printf 'refuse\n'
      exit 2
    fi
  done

  printf 'allow\n'
}

# ---------------------------------------------------------------------------
# screen-path — refuse reading files that commonly hold secrets into context
# (the privacy-block hook, see references/hooks.md). Screens a PATH, not a
# command. Fail-closed: an unusual benign path that matches is refused and
# surfaced for explicit human re-authorization, never auto-read.
# ---------------------------------------------------------------------------
cmd_screen_path() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    err "screen-path requires a path"
    exit 1
  fi

  local -a deny_patterns=(
    '(^|/)\.env($|\.|/)'                     # .env, .env.local, .env.prod, .env/
    '(^|/)\.envrc$'
    '\.pem$'
    '\.key$'
    '(^|/)id_rsa($|\.)'
    '(^|/)id_ed25519($|\.)'
    '(^|/)id_ecdsa($|\.)'
    '(^|/)\.ssh/'
    '(^|/)\.aws/credentials'
    '(^|/)\.git-credentials$'
    '(^|/)\.npmrc$'
    '(^|/)\.pypirc$'
    '(^|/)credentials\.json$'
    '(^|/)secrets?\.(json|ya?ml|toml|env)$'
    '\.p12$'
    '\.pfx$'
    '\.keystore$'
    '(^|/)\.netrc$'
    '(^|/)\.htpasswd$'
  )

  local pattern
  for pattern in "${deny_patterns[@]}"; do
    if [[ "$path" =~ $pattern ]]; then
      err "refused: path looks like a secrets-bearing file ($pattern) — do not read into context without explicit user re-authorization"
      printf 'refuse\n'
      exit 2
    fi
  done

  printf 'allow\n'
}

# ---------------------------------------------------------------------------
# validate-state — coarse structural validation of orchestrator-state.json.
# Required top-level fields + coarse type checks. A malformed ledger must
# never be trusted to route from.
# ---------------------------------------------------------------------------
cmd_validate_state() {
  local state_file="${1:-}"
  require_file "$state_file"
  require_jq

  if ! jq -e . "$state_file" >/dev/null 2>&1; then
    err "invalid JSON: $state_file"
    exit 1
  fi

  local -a required_fields=(goal archetype predicate cycle_count)
  local field missing=0
  for field in "${required_fields[@]}"; do
    if ! jq -e "has(\"$field\")" "$state_file" >/dev/null 2>&1; then
      err "missing required field: $field"
      missing=1
    fi
  done

  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi

  # Coarse type checks.
  jq -e '.cycle_count | type == "number"' "$state_file" >/dev/null 2>&1 || {
    err "cycle_count must be a number"
    exit 1
  }
  jq -e '.predicate | type == "string"' "$state_file" >/dev/null 2>&1 || {
    err "predicate must be a string"
    exit 1
  }

  echo "valid"
}

# ---------------------------------------------------------------------------
# screen-state-predicate — re-screen the pinned Success predicate command
# from a resumed state file before reusing it. Persisted commands are never
# trusted; this refuses on any unsafe match exactly like screen-cmd.
# ---------------------------------------------------------------------------
cmd_screen_state_predicate() {
  local state_file="${1:-}"
  require_file "$state_file"
  require_jq

  local predicate_cmd
  predicate_cmd=$(jq -r '.predicate // ""' "$state_file")
  if [[ -z "$predicate_cmd" ]]; then
    err "no predicate found in state file"
    exit 1
  fi

  cmd_screen_cmd "$predicate_cmd"
}

# ---------------------------------------------------------------------------
# verdict — delegate to score-regression.sh, kept as a pass-through so
# command markdown files only need to know about orchestrate.sh.
# ---------------------------------------------------------------------------
cmd_verdict() {
  if [[ $# -lt 1 ]]; then
    err "verdict requires a results TSV path"
    exit 1
  fi
  local score_script="$SCRIPT_DIR/score-regression.sh"
  if [[ ! -x "$score_script" ]]; then
    err "score-regression.sh not found or not executable at $score_script"
    exit 1
  fi
  # Forward ALL args (results.tsv + any --threshold N / future flags) so callers
  # can override the regression threshold through the orchestrate.sh seam without
  # bypassing it. Previously only $1 was passed and --threshold was silently dropped.
  "$score_script" verdict "$@"
}

# ---------------------------------------------------------------------------
# seed — emit the preset pipeline (JSON array of subcommand hops) for a goal
# archetype, so orchestrator init can seed preset_pipeline_remaining
# deterministically instead of the LLM transcribing it from routing.md prose.
# This is the mirror of the "Preset Pipelines" table in
# references/orchestrator-routing.md — keep the two in sync (smoke-test pins it).
# ---------------------------------------------------------------------------
cmd_seed() {
  local archetype="${1:-}"
  if [[ -z "$archetype" ]]; then
    err "seed requires an archetype (one of the labels emitted by 'classify')"
    exit 1
  fi
  require_jq
  local pipeline
  case "$archetype" in
    ship-ready)      pipeline='["probe","debug","fix","regression","ship"]' ;;
    optimize-metric) pipeline='["plan","evals"]' ;;
    fix-broken)      pipeline='["debug","fix","regression"]' ;;
    harden)          pipeline='["security","fix","security"]' ;;
    build-feature)   pipeline='["debug","fix","regression"]' ;;
    explore)         pipeline='["probe","scenario","plan"]' ;;
    document)        pipeline='["learn"]' ;;
    what-to-build)   pipeline='["improve"]' ;;
    decide-design)   pipeline='["reason"]' ;;
    research)        pipeline='["research"]' ;;
    *)
      err "unknown archetype: '$archetype'"
      exit 1
      ;;
  esac
  printf '%s' "$pipeline" | jq -c '.'
}

# ---------------------------------------------------------------------------
# fold — merge a hop's handoff.json into orchestrator-state.json's last_handoff,
# validating the handoff envelope first (fail-closed). This is the WRITE half of
# the routing seam: next-hop/units route entirely off .last_handoff, so folding
# must be scripted + validated, not a prose copy that can silently drop a field
# (GAP D4). Prints the merged state to stdout; caller redirects to the state file.
# ---------------------------------------------------------------------------
cmd_fold() {
  local state_file="${1:-}" handoff_file="${2:-}"
  require_file "$state_file"
  require_file "$handoff_file"
  require_jq
  if ! jq -e 'type == "object" and has("source") and has("status")' "$handoff_file" >/dev/null 2>&1; then
    err "fold refused: handoff is not a valid envelope (needs at least source + status)"
    exit 1
  fi
  jq --slurpfile h "$handoff_file" '.last_handoff = $h[0]' "$state_file"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    classify)                  cmd_classify "$@" ;;
    seed)                      cmd_seed "$@" ;;
    fold)                      cmd_fold "$@" ;;
    next-hop)                  cmd_next_hop "$@" ;;
    units)                     cmd_units "$@" ;;
    plateau)                   cmd_plateau "$@" ;;
    screen-cmd)                cmd_screen_cmd "$@" ;;
    screen-path)               cmd_screen_path "$@" ;;
    verdict)                   cmd_verdict "$@" ;;
    validate-state)            cmd_validate_state "$@" ;;
    screen-state-predicate)    cmd_screen_state_predicate "$@" ;;
    *)
      err "unknown subcommand: '$subcmd'"
      err "usage: orchestrate.sh {classify|seed|fold|next-hop|units|plateau|screen-cmd|screen-path|verdict|validate-state|screen-state-predicate} [args...]"
      exit 1
      ;;
  esac
}

main "$@"
