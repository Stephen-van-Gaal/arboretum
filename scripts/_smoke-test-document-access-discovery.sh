#!/usr/bin/env bash
# owner: document-access
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-document-access-discovery.sh -- Verify profile-agnostic document discovery and retrieval.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

[ -f scripts/explore-doc.sh ] || fail "explore-doc.sh missing"
[ -f scripts/read-doc-sections.sh ] || fail "read-doc-sections.sh missing"

explore="$(bash scripts/explore-doc.sh docs/templates/spec.md)" \
  || fail "spec template should be explorable"

printf '%s\n' "$explore" | grep -q '^document-shape=governed-spec$' \
  || fail "spec template discovery missing document shape" "$explore"
printf '%s\n' "$explore" | grep -q 'section\[[0-9][0-9]*\]\.key=purpose' \
  || fail "spec template discovery missing purpose key" "$explore"
printf '%s\n' "$explore" | grep -q 'section\[[0-9][0-9]*\]\.key=behaviour' \
  || fail "spec template discovery missing behaviour key" "$explore"
ok "spec template is discoverable by semantic key"

sections="$(bash scripts/read-doc-sections.sh docs/templates/spec.md purpose behaviour)" \
  || fail "spec template purpose/behaviour retrieval should succeed"
printf '%s\n' "$sections" | grep -q '^## Purpose$' \
  || fail "retrieval omitted Purpose" "$sections"
printf '%s\n' "$sections" | grep -q '^## Behaviour$' \
  || fail "retrieval omitted Behaviour" "$sections"
if printf '%s\n' "$sections" | grep -q '^## Decisions$'; then
  fail "retrieval leaked unrequested Decisions" "$sections"
fi
ok "semantic section retrieval returns requested sections only"

out_file="$FIX/arboretum-doc-sections.out"
err_file="$FIX/arboretum-doc-sections.err"
if bash scripts/read-doc-sections.sh docs/templates/spec.md purpose missing-key >"$out_file" 2>"$err_file"; then
  fail "missing key retrieval should fail"
fi
[ ! -s "$out_file" ] \
  || fail "missing key retrieval emitted partial output" "$(cat "$out_file")"
grep -q "missing-key" "$err_file" \
  || fail "missing key error should name requested key" "$(cat "$err_file")"
ok "semantic section retrieval fails closed"

grep -q 'scripts/explore-doc.sh' skills/consolidate/SKILL.md \
  || fail "/consolidate does not document discovery-first reading"
grep -q 'scripts/read-doc-sections.sh' skills/consolidate/SKILL.md \
  || fail "/consolidate does not document semantic section retrieval"
ok "public consolidate skill path is discovery/retrieval aware"

echo "document-access discovery smoke: ALL PASS"
