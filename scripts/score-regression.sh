#!/usr/bin/env bash
# score-regression.sh — verdict math for the regression stability gate.
#
# Implements the scoring/verdict rules described in commands/regression.md:
#   - Any HARD-tier row with regressed=true and classification=eligible => UNSTABLE
#     (green→red hard-blocks, no amount of SCORE-tier credit can offset it).
#   - Otherwise: stability_score = sum(weight * dim_subscore) over SCORE-tier
#     dimensions that actually ran, renormalized over the dimensions present.
#     Default weights: flakiness .30 / performance .30 / resource .20 / visual-ui .20.
#   - STABLE iff stability_score >= REG_THRESHOLD (default 95).
#
# Usage:
#   score-regression.sh verdict <results.tsv> [--threshold N]
#
# Input TSV format (see commands/regression.md):
#   # metric_direction: higher_is_better
#   iteration  timestamp  dimension  axis  tier  classification  baseline  candidate  delta  regressed  subscore  severity  status  file_line  description
#
# Exit codes: 0 = STABLE, 1 = UNSTABLE or BASELINE_UNAVAILABLE, 2 = usage/input error.
#   STABLE prints "STABLE" (exit 0); UNSTABLE prints "UNSTABLE" (exit 1);
#   BASELINE_UNAVAILABLE (no SCORE dimensions ran) ALSO exits 1 but prints
#   "BASELINE_UNAVAILABLE" on stdout. Callers MUST disambiguate the two exit-1
#   verdicts by reading stdout, never by the exit code alone.

set -euo pipefail

err() { printf 'score-regression.sh: %s\n' "$1" >&2; }

DEFAULT_THRESHOLD=95

declare -A SCORE_WEIGHTS=(
  [flakiness]="0.30"
  [performance]="0.30"
  [resource]="0.20"
  [visual-ui]="0.20"
)

usage() {
  err "usage: score-regression.sh verdict <results.tsv> [--threshold N]"
  exit 2
}

cmd_verdict() {
  local tsv="${1:-}"
  local threshold="$DEFAULT_THRESHOLD"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --threshold)
        threshold="${2:-$DEFAULT_THRESHOLD}"
        shift 2
        ;;
      *)
        err "unknown flag: $1"
        usage
        ;;
    esac
  done

  if [[ -z "$tsv" || ! -f "$tsv" ]]; then
    err "results TSV not found: $tsv"
    usage
  fi

  if ! command -v awk >/dev/null 2>&1; then
    err "awk is required but not installed"
    exit 2
  fi

  # awk does all the heavy lifting: single pass over the TSV, skip the
  # `# metric_direction:` comment line and the header row, then:
  #   1. Any HARD row with regressed=true + classification=eligible => hard_block=1
  #   2. For SCORE-tier rows, accumulate weight*subscore and weight-present,
  #      per dimension (last row per dimension wins — most recent sample).
  # Weights are passed in as an awk associative array via -v assignments
  # since awk doesn't support bash associative arrays natively.

  awk -F'\t' \
    -v w_flakiness="${SCORE_WEIGHTS[flakiness]}" \
    -v w_performance="${SCORE_WEIGHTS[performance]}" \
    -v w_resource="${SCORE_WEIGHTS[resource]}" \
    -v w_visual="${SCORE_WEIGHTS[visual-ui]}" \
    -v threshold="$threshold" '
    BEGIN {
      hard_block = 0
      weights["flakiness"] = w_flakiness
      weights["performance"] = w_performance
      weights["resource"] = w_resource
      weights["visual-ui"] = w_visual
      header_seen = 0
    }
    /^#/ { next }
    {
      if (header_seen == 0) {
        # Map column names to indices from the header row.
        for (i = 1; i <= NF; i++) { col[$i] = i }
        header_seen = 1
        next
      }

      dim = $(col["dimension"])
      tier = $(col["tier"])
      classification = $(col["classification"])
      regressed = $(col["regressed"])
      subscore = $(col["subscore"])

      if (tier == "HARD") {
        if (regressed == "true" && classification == "eligible") {
          hard_block = 1
        }
        next
      }

      if (tier == "SCORE") {
        # Keep only the most recent (last-seen) subscore per dimension.
        last_subscore[dim] = subscore
        seen_dim[dim] = 1
      }
    }
    END {
      if (hard_block == 1) {
        print "UNSTABLE"
        print "reason=hard_regression" > "/dev/stderr"
        exit 1
      }

      total_weight = 0
      weighted_sum = 0
      for (d in seen_dim) {
        if (d in weights) {
          w = weights[d]
          total_weight += w
          weighted_sum += w * last_subscore[d]
          printf "dim=%s weight=%.2f subscore=%s contribution=%.2f\n", d, w, last_subscore[d], (w * last_subscore[d]) > "/dev/stderr"
        }
      }

      if (total_weight == 0) {
        print "BASELINE_UNAVAILABLE"
        print "reason=no_score_dimensions_ran" > "/dev/stderr"
        exit 1
      }

      stability_score = weighted_sum / total_weight
      printf "stability_score=%.2f threshold=%s\n", stability_score, threshold > "/dev/stderr"

      if (stability_score >= threshold) {
        print "STABLE"
        exit 0
      } else {
        print "UNSTABLE"
        print "reason=score_below_threshold" > "/dev/stderr"
        exit 1
      }
    }
  ' "$tsv"
}

main() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    verdict) cmd_verdict "$@" ;;
    *)
      usage
      ;;
  esac
}

main "$@"
