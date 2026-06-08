#!/usr/bin/env bash
# owner: extract-shared-component
# Tier-1 detector — grep idiom-library pass for single-line clones.
# Catches one-line idioms the multi-line shingle detector structurally misses
# (e.g. an inline-python regex whose shell neighbours differ per file).
#
# Usage: grep-idioms.sh [ROOT ...]
#   ROOT  one or more directories/files to scan. Defaults to the governance roots.
# Output: a fixed-width table "idiom  files  hits", one row per idiom.
set -uo pipefail

if [ "$#" -gt 0 ]; then
  ROOTS=("$@")
else
  ROOTS=(scripts .claude/hooks hooks dev-tools)
fi

# label<TAB>extended-regex — one per line. Add idioms as the library grows.
IDIOMS=$(cat <<'EOF'
scrub control-char regex	\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f
mktemp temp file	\$\(mktemp
trap cleanup on EXIT	trap .*EXIT
command -v gh guard	command -v gh
gh auth token	gh auth token
source roadmap/lib.sh	source .*roadmap/lib\.sh
CLAUDE_PLUGIN_ROOT fallback	CLAUDE_PLUGIN_ROOT
inline python3 heredoc	python3 -
bash-version guard	BASH_VERSION
set -euo pipefail	set -euo pipefail
EOF
)

printf '%-32s %6s %6s\n' "idiom" "files" "hits"
printf '%-32s %6s %6s\n' "--------------------------------" "-----" "-----"
while IFS=$'\t' read -r label pat; do
  [ -z "$label" ] && continue
  files=$(grep -rIlE "$pat" "${ROOTS[@]}" 2>/dev/null | wc -l | tr -d ' ')
  hits=$(grep -rInE "$pat" "${ROOTS[@]}" 2>/dev/null | wc -l | tr -d ' ')
  printf '%-32s %6s %6s\n' "$label" "$files" "$hits"
done <<< "$IDIOMS"
