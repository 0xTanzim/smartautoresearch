#!/usr/bin/env bash
# install.sh — place the SmartAutoResearch skill into a target tool's config.
#
# Wraps transform.sh: builds the correct per-platform tree, then copies it to the
# tool's project-local or global config directory. Copies only — never runs anything
# destructive. Global (~) installs require an explicit confirmation.
#
# Usage:
#   install.sh --platform <p> --project [DIR]     # install into DIR (default: cwd)
#   install.sh --platform <p> --global [--yes]    # install into the tool's ~ config
#   install.sh --platform universal --project .   # just AGENTS.md + the tree
#   install.sh --list
#
# --yes / -y: skip the global-install confirmation prompt (for CI/non-interactive use).
#             Project installs never prompt — they're copy-only into a dir you named.
#
# Platforms: claude-code opencode codex antigravity cursor universal

set -euo pipefail

SKILL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
SKILL_NAME="smartautoresearch"
TRANSFORM="$SKILL_ROOT/scripts/transform.sh"

# Staging dir is a GLOBAL (not a main()-local) so the EXIT trap can still see it when the
# shell exits — a main()-local would be out of scope by then and trip `set -u`.
STAGING=""
cleanup() { [[ -n "${STAGING:-}" && -d "$STAGING" ]] && rm -rf "$STAGING"; }
trap cleanup EXIT

err()  { printf 'install.sh: %s\n' "$1" >&2; }
info() { printf '  %s\n' "$1"; }

# Global config base for each platform (project scope uses the same relative subpaths
# under the given project dir — transform.sh already lays those out).
global_base() { # $1 = platform -> prints the ~ base the tree copies into
  case "$1" in
    claude-code) printf '%s/.claude\n'        "$HOME" ;;
    opencode)    printf '%s/.config/opencode\n' "$HOME" ;;
    codex)       printf '%s/.codex\n'         "$HOME" ;;
    antigravity) printf '%s/.antigravity\n'   "$HOME" ;;
    cursor)      printf '%s/.cursor\n'        "$HOME" ;;
    kiro)        printf '%s/.kiro\n'          "$HOME" ;;
    gemini)      printf '%s/.gemini\n'        "$HOME" ;;
    windsurf)    printf '%s/.codeium/windsurf\n' "$HOME" ;;
    universal)   printf '%s\n'                "$HOME" ;;
    *) return 1 ;;
  esac
}

# The subpath WITHIN a built tree whose CONTENTS get merged into the global base.
# (For a project install the whole tree is copied as-is; only global needs this mapping
# because each tool's global config dir differs from the tree's relative dotdir.)
tree_inner() { # $1 = platform
  case "$1" in
    claude-code) printf '.claude\n' ;;
    opencode)    printf '.opencode\n' ;;
    codex)       printf '.agents\n' ;;
    cursor)      printf '.cursor\n' ;;
    kiro)        printf '.kiro\n' ;;
    gemini)      printf '.gemini\n' ;;
    windsurf)    printf '.windsurf\n' ;;
    antigravity) printf '.\n' ;;   # tree root holds skills/ + AGENTS.md
    universal)   printf '.\n' ;;   # tree root holds <name>/ + AGENTS.md
    *) return 1 ;;
  esac
}

usage() {
  err "usage: install.sh --platform <claude-code|opencode|codex|antigravity|cursor|kiro|gemini|windsurf|universal> (--project [DIR] | --global [--yes])"
  exit 2
}

main() {
  local platform="" scope="" project_dir="." assume_yes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list) "$TRANSFORM" --list; exit 0 ;;
      --platform) platform="${2:?}"; shift 2 ;;
      --platform=*) platform="${1#--platform=}"; shift ;;
      --project) scope="project"; shift
                 if [[ $# -gt 0 && "$1" != --* ]]; then project_dir="$1"; shift; fi ;;
      --global) scope="global"; shift ;;
      --yes|-y) assume_yes="1"; shift ;;
      *) err "unknown arg: $1"; usage ;;
    esac
  done

  [[ -z "$platform" || -z "$scope" ]] && usage
  if [[ ! -x "$TRANSFORM" ]]; then err "transform.sh not found/executable at $TRANSFORM"; exit 1; fi

  # Build the platform tree into a temp staging dir (STAGING is global — see trap above).
  STAGING="$(mktemp -d)"
  "$TRANSFORM" --out "$STAGING" "$platform" >/dev/null

  local src="$STAGING/$platform"
  if [[ ! -d "$src" ]]; then err "build produced no tree for '$platform'"; exit 1; fi

  # Resolve destination + copy.
  if [[ "$scope" == "project" ]]; then
    # Project install: copy the whole tree as-is (its relative dotdirs are already correct).
    mkdir -p "$project_dir"
    cp -R "$src"/. "$project_dir"/
    info "installed $platform into project: $project_dir"
  else
    # Global install: merge the tree's inner config dir into the tool's real global base.
    local base inner
    base="$(global_base "$platform")"   || { err "no global base for '$platform'"; exit 1; }
    inner="$(tree_inner "$platform")"    || { err "no tree mapping for '$platform'"; exit 1; }
    printf 'install.sh: about to install the %s skill into your GLOBAL config:\n' "$platform"
    printf '  from: %s/%s\n  into: %s\n' "$src" "$inner" "$base"
    if [[ -n "$assume_yes" ]]; then
      info "proceeding (--yes given)."
    elif [[ ! -t 0 ]]; then
      err "stdin is not a terminal and --yes was not given — refusing to guess on a global install."
      err "re-run with --yes to confirm non-interactively, or run interactively to be prompted."
      exit 1
    else
      printf 'Proceed? [y/N] '
      read -r reply
      [[ "$reply" == "y" || "$reply" == "Y" ]] || { info "aborted."; exit 0; }
    fi
    mkdir -p "$base"
    cp -R "$src/$inner/." "$base"/
    info "installed $platform into $base"
  fi

  info "verify: run 'bash <skill-dir>/scripts/smoke-test.sh' or your tool's skill-list command."
}

main "$@"
