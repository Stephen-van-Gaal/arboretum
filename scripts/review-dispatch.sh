#!/usr/bin/env bash
# owner: review-stage
# review-dispatch.sh — print the B4 lane plan (or per-lane relevance verdicts) for a change set.
#   review-dispatch.sh [--verdicts] <base-ref>
#   review-dispatch.sh [--verdicts] --files-from <file|->
# Lane-list mode (default) — run order: ai-surface (if AI-facing surface changed),
#   general-security (always), correctness (if the diff contains code).
# Verdict mode (--verdicts, #854) — per-lane relevance JSON for the B4 gate; the
#   general-security lane is a skip-candidate only when EVERY changed path is
#   provably-safe prose (is_safe_prose allowlist), otherwise it stays relevant.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_ai_facing() { # reads paths on stdin; 0 if any match AI-facing globs
  while IFS= read -r f; do
    case "$f" in
      skills/*|.claude/skills/*|.claude/hooks/*|.githooks/*|scripts/*) return 0 ;;
      CLAUDE.md|AGENTS.md|GEMINI.md) return 0 ;;
    esac
  done
  return 1
}

is_safe_prose() { # reads paths on stdin; 0 if EVERY path is provably-safe prose (ALLOWLIST), 1 otherwise.
  # Allowlist (not blocklist): in an instruction-dense repo almost every *.md is agent-facing,
  # so the gate skips general-security ONLY for paths that cannot carry code, config, or agent
  # behaviour — and runs it for everything else (fail toward reviewing). #854 / Codex P2 rounds 2-4.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      *.txt) ;;                                  # plain-text notes, any path
      README.md|CHANGELOG.md) ;;                 # root readme / changelog
      docs/*.md)                                 # DIRECT children of docs/ only (not docs/templates/, docs/specs/, …)
        case "${f#docs/}" in */*) return 1 ;; esac ;;
      *) return 1 ;;                             # anything else (code, config, .github, skills, nested docs, workflows, ARBORETUM.md, *.rst) keeps security
    esac
  done
  return 0   # every path allowlisted, or empty change set
}

plan() { # reads paths on stdin
  local files; files="$(cat)"
  if printf '%s\n' "$files" | is_ai_facing; then echo "ai-surface"; fi
  echo "general-security"   # always — safe default
  # correctness lane only when the change set contains code
  if [ "$(printf '%s\n' "$files" | bash "$SCRIPT_DIR/classify-pr-change.sh" --files-from -)" = "code" ]; then
    echo "correctness"
  fi
}

verdicts() { # reads paths on stdin; prints per-lane relevance JSON (zero model tokens)
  local files; files="$(cat)"
  local ai code sec
  if printf '%s\n' "$files" | is_ai_facing; then ai=true; else ai=false; fi
  if [ "$(printf '%s\n' "$files" | bash "$SCRIPT_DIR/classify-pr-change.sh" --files-from -)" = "code" ]; then
    code=true; else code=false; fi
  # general-security is a skip-candidate ONLY when every path is provably-safe prose
  # (is_safe_prose ALLOWLIST). Everything else — code, config, .github, skill/instruction
  # markdown, workflow/framework docs — keeps the security pass (#854, D1).
  if printf '%s\n' "$files" | is_safe_prose; then sec=false; else sec=true; fi

  local ai_r sec_r code_r
  $ai   && ai_r="AI-facing surface changed"     || ai_r="no AI-facing surface in change set"
  $sec  && sec_r="change set is not prose-only" || sec_r="change set is prose-only"
  $code && code_r="change set contains code"    || code_r="no code files in change set"

  jq -nc \
    --argjson ai "$ai" --arg ai_r "$ai_r" \
    --argjson sec "$sec" --arg sec_r "$sec_r" \
    --argjson code "$code" --arg code_r "$code_r" \
    '{
       lanes: {
         "ai-surface":       {relevant: $ai,   reason: $ai_r},
         "general-security": {relevant: $sec,  reason: $sec_r},
         "correctness":      {relevant: $code, reason: $code_r}
       },
       any_relevant: ($ai or $sec or $code)
     }'
}

MODE=plan
if [ "${1:-}" = "--verdicts" ]; then MODE=verdicts; shift; fi
run() { if [ "$MODE" = verdicts ]; then verdicts; else plan; fi; }

case "${1:-}" in
  --files-from)
    if [ "${2:-}" = "-" ]; then run; else run < "$2"; fi ;;
  "")
    echo "usage: review-dispatch.sh [--verdicts] <base-ref> | [--verdicts] --files-from <file|->" >&2; exit 1 ;;
  *)
    git diff "$1...HEAD" --name-only | run ;;
esac
