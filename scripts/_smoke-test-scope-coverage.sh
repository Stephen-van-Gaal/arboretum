#!/usr/bin/env bash
# owner: framework-scope-marker
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-scope-coverage.sh — every vendored framework shell file carries a
# `# scope:` marker. A class left unmarked re-opens the manifest-absent failure
# mode (#836): in an adopter root such a file would trip Check 3 with no in-file
# governance-scope signal to suppress it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
miss=0
while IFS= read -r f; do
  sed -n '1,8p' "$f" | grep -q '^# scope:' || { echo "MISSING marker: $f" >&2; miss=$((miss+1)); }
done < <(
  find scripts -type d \( -name _archived -o -name _fixtures \) -prune -o -type f -name '*.sh' -print
  find .claude/hooks -type f -name '*.sh' -print 2>/dev/null
)
# bin/* shell executables too.
for f in bin/*; do
  [ -f "$f" ] && head -1 "$f" | grep -q '^#!' || continue
  sed -n '1,8p' "$f" | grep -q '^# scope:' || { echo "MISSING marker: $f" >&2; miss=$((miss+1)); }
done
[ "$miss" -eq 0 ] && echo "ALL PASS" || { echo "FAIL: $miss framework shell file(s) lack a # scope: marker" >&2; exit 1; }
