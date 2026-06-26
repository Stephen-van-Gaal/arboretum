#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# audit-test-metadata.sh — classify scripts/_smoke-test-*.sh for parallel-safety;
# report / --check / --apply the `# ci-parallel:` declaration.
#
# Operates on `scripts/_smoke-test-*.sh` relative to the current working
# directory (run from the repo root). The static classifier only *proposes* a
# verdict — the acceptance bar for `# ci-parallel: safe` is an empirical
# `ARBORETUM_CI_JOBS=8` run that stays deterministically green across two runs.
set -uo pipefail

MODE="report"
# Fail closed on extra arguments (Codex P3): `--check --bogus` / `--apply file`
# must be a usage error, not a silently-ignored arg.
if [ "$#" -gt 1 ]; then
  echo "usage: audit-test-metadata.sh [--check|--apply]  (no extra arguments)" >&2
  exit 2
fi
case "${1:-}" in
  "")      MODE="report" ;;
  --check) MODE="check" ;;
  --apply) MODE="apply" ;;
  *) echo "usage: audit-test-metadata.sh [--check|--apply]" >&2; exit 2 ;;
esac

# classify <file> -> safe-candidate | serial-required | needs-review
classify() {
  local f="$1" uses_mktemp=0 mutates=0 scoped_git=0 ambiguous=0
  grep -qE 'mktemp' "$f" && uses_mktemp=1
  # Bare mutating git operates on the ambient repo (the shared working tree) →
  # never parallel-safe.
  grep -qE 'git[[:space:]]+(add|commit|checkout|stash|reset|rm)([[:space:]]|$)' "$f" && mutates=1
  # `git -C <path>` / `git -c k=v <verb>` is path-dependent: it may target a
  # mktemp sandbox (safe) OR the shared tree (unsafe — Codex P2). A regex can't
  # tell which, so route it to needs-review rather than auto-tagging it safe.
  grep -qE 'git[[:space:]]+(-C|-c)[[:space:]].*(add|commit|checkout|stash|reset|rm)' "$f" && scoped_git=1
  # ambiguity = a real network bind (shared port) — NOT a bare ":NNNN", which
  # false-matches JSON token-count numbers like "output_tokens":1000.
  grep -qE '((localhost|127\.0\.0\.1|0\.0\.0\.0):[0-9]+|nc[[:space:]]+-l|--port[[:space:]=])' "$f" && ambiguous=1
  if [ "$mutates" = 1 ]; then echo "serial-required"; return; fi
  if [ "$scoped_git" = 1 ] || { [ "$uses_mktemp" = 1 ] && [ "$ambiguous" = 1 ]; }; then echo "needs-review"; return; fi
  if [ "$uses_mktemp" = 1 ]; then echo "safe-candidate"; return; fi
  echo "serial-required"
}

# current_tag <file> -> safe | serial | untagged
current_tag() {
  local line; line="$(sed -n '1,12{/^# ci-parallel: /p;}' "$1" | head -1)"
  if [ -n "$line" ]; then echo "${line#"# ci-parallel: "}"; else echo "untagged"; fi
}

shopt -s nullglob
files=(scripts/_smoke-test-*.sh)

case "$MODE" in
  report)
    printf '%-10s %-16s %s\n' "TAG" "VERDICT" "FILE"
    for f in "${files[@]}"; do
      printf '%-10s %-16s %s\n' "$(current_tag "$f")" "$(classify "$f")" "$f"
    done
    ;;
  check)
    if [ "${#files[@]}" -eq 0 ]; then
      echo "FAIL: no scripts/_smoke-test-*.sh found (run from the repo root)" >&2
      exit 1
    fi
    rc=0
    for f in "${files[@]}"; do
      case "$(current_tag "$f")" in
        safe|serial) ;;
        untagged) echo "FAIL: $f missing '# ci-parallel: safe|serial' declaration" >&2; rc=1 ;;
        *) echo "FAIL: $f has invalid '# ci-parallel: $(current_tag "$f")' (must be safe|serial)" >&2; rc=1 ;;
      esac
    done
    [ "$rc" = 0 ] && echo "ok: all smoke tests declare # ci-parallel"
    exit "$rc"
    ;;
  apply)
    rc=0
    for f in "${files[@]}"; do
      [ "$(current_tag "$f")" = "untagged" ] || continue
      case "$(classify "$f")" in
        safe-candidate)  tag="safe" ;;
        serial-required) tag="serial" ;;
        *) echo "skip (needs-review): $f" >&2; continue ;;
      esac
      # Insert after the header comment block (# owner: must stay on line 2,
      # # scope: on line 3 when present) — never above # owner:. Anchor on the
      # last of owner/scope in the first 6 lines; fall back to the shebang.
      ins=1
      owner_ln="$(grep -nE '^# owner:' "$f" | head -1 | cut -d: -f1)"
      if [ -n "$owner_ln" ]; then
        ins="$owner_ln"
        nxt=$((owner_ln + 1))
        if sed -n "${nxt}p" "$f" | grep -qE '^# scope:'; then ins="$nxt"; fi
      fi
      # portable BSD/GNU sed in-place append after line $ins; propagate failure
      # (Codex P3) so a non-writable file never reports a false 'tagged'.
      if sed -i.bak "${ins}a\\
# ci-parallel: $tag
" "$f"; then
        rm -f "$f.bak"
        echo "tagged $tag: $f"
      else
        rm -f "$f.bak" 2>/dev/null || true
        echo "FAIL: could not tag $f" >&2
        rc=1
      fi
    done
    exit "$rc"
    ;;
esac
