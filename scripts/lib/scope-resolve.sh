#!/usr/bin/env bash
# owner: framework-scope-marker
# scope: plugin-only
# scope-resolve.sh — single source of `# scope:` governance-scope reading.
#
# Sourced library. Bash 3.2 compatible (no declare -A, no GNU-only flags).
# Defines file_scope and governed_by_framework_in_consumer_root. The only place
# the `# scope:` marker grammar is parsed; ci-checks.sh and health-check.sh
# consume these rather than re-inlining the regex (the parallel-drift class of
# #124). See docs/contracts/scope-resolve.contract.md and
# docs/definitions/scope-marker-schema.md.

# file_scope <path>
#   Echoes plugin-only | consumer | any | none. Never fails: an unreadable or
#   unmarked file resolves to `none`. Reads `# scope:` from the first 8 lines of
#   .sh/bin files and the `scope:` frontmatter key of SKILL.md.
file_scope() {
  local f="$1" val
  case "$f" in
    *SKILL.md)
      # `|| true`: an unreadable file must resolve to `none`, never abort a
      # `set -e`/`pipefail` caller — file_scope's contract promises never-fails.
      val="$(awk '
        /^---[[:space:]]*$/ { n++; next }
        n >= 2 { exit }
        n == 1 && /^scope:/ { sub(/^scope:[[:space:]]*/, ""); print; exit }
      ' "$f" 2>/dev/null)" || true
      ;;
    *)
      val="$(sed -n '1,8{s/^# scope:[[:space:]]*//p;}' "$f" 2>/dev/null | head -1)" || true
      ;;
  esac
  case "$val" in
    plugin-only|consumer|any) printf '%s\n' "$val" ;;
    *)                        printf 'none\n' ;;
  esac
}

# governed_by_framework_in_consumer_root <path>
#   Returns 0 when the file is framework-governed (scope plugin-only), 1 otherwise
#   (consumer | any | none). Callers gate this behind is_plugin_root so the marker
#   is ignored in a plugin root.
governed_by_framework_in_consumer_root() {
  [ "$(file_scope "$1")" = plugin-only ]
}
