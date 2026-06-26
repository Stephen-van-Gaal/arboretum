#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-roadmap-maintain-apply.sh — Contract test for
# docs/contracts/roadmap-maintain-apply.cli-contract.md. Asserts CLI-1..CLI-5
# against scripts/roadmap/maintain-apply.sh.
#
# All cases are offline: CLI-1 feeds an all-empty-buckets scan JSON so the
# script has nothing to apply and never reaches the gh guard; CLI-2 uses
# --dry-run with populated buckets so gh is also never called; CLI-3..CLI-5
# are argument-error and pre-flight paths that exit before gh. No GitHub
# mutations occur. Picked up automatically by ci-checks.sh's === Smoke
# tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$SCRIPT_DIR/roadmap/maintain-apply.sh"
[ -f "$APPLY" ] || { echo "FAIL: $APPLY not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# ---------------------------------------------------------------------------
# CLI-1 — empty actionable buckets → exit 0, no output
# Feeds a scan JSON whose actionable arrays are all empty. The script iterates
# over bucket_rows() for each bucket, finds nothing, and exits cleanly without
# ever reaching the `gh auth status` guard (the dry_run=false path checks gh
# only once, before the loops). Because every bucket_rows() call returns empty
# output, no apply_* function is called — this test never touches gh.
# ---------------------------------------------------------------------------
EMPTY_SCAN="$TMP/empty.json"
cat > "$EMPTY_SCAN" <<'JSON'
{
  "buckets": {
    "auto_close":             [],
    "soft_resolved":          [],
    "orphan":                 [],
    "agent_ready_invalidated": [],
    "agent_ready_stale":      [],
    "untriaged":              [],
    "unshaped_next":          []
  },
  "counts": {
    "auto_close": 0,
    "soft_resolved": 0,
    "orphan": 0,
    "agent_ready_invalidated": 0,
    "agent_ready_stale": 0,
    "untriaged": 0,
    "unshaped_next": 0,
    "healthy": 3
  }
}
JSON

# Note: live mode guards on `gh auth status` BEFORE the bucket loops, so an
# unauthenticated CI environment would exit 1 here. We use --dry-run for the
# empty-buckets case too, which bypasses the gh guard entirely while still
# exercising the --scan-file ingestion path.
out=$(bash "$APPLY" --scan-file "$EMPTY_SCAN" --dry-run 2>&1); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then
  pass CLI-1
else
  fail_case CLI-1 "rc=$rc out=[$out]"
fi

# ---------------------------------------------------------------------------
# CLI-2 — dry-run with populated buckets → [dry-run] lines, exit 0, no gh
# Feeds one entry in each of the five actionable buckets. --dry-run makes the
# script print "[dry-run] ..." lines and return 0 without calling gh.
# ---------------------------------------------------------------------------
POPULATED_SCAN="$TMP/populated.json"
cat > "$POPULATED_SCAN" <<'JSON'
{
  "buckets": {
    "auto_close":             [{"number":10,"title":"Old closed issue","evidence":"PR #42 closes #10"}],
    "soft_resolved":          [{"number":11,"title":"Maybe resolved","evidence":"PR #43 mentions #11"}],
    "orphan":                 [{"number":12,"title":"Stale orphan","evidence":"No activity in 180 days"}],
    "agent_ready_invalidated":[{"number":13,"title":"Invalidated agent-ready","evidence":"Body SHA changed"}],
    "agent_ready_stale":      [{"number":14,"title":"Stale agent-ready","evidence":"Verified 95 days ago"}],
    "untriaged":              [{"number":15,"title":"Untriaged","evidence":""}],
    "unshaped_next":          [{"number":16,"title":"Unshaped next","evidence":""}]
  },
  "counts": {
    "auto_close": 1,
    "soft_resolved": 1,
    "orphan": 1,
    "agent_ready_invalidated": 1,
    "agent_ready_stale": 1,
    "untriaged": 1,
    "unshaped_next": 1,
    "healthy": 0
  }
}
JSON

dry_out=$(bash "$APPLY" --scan-file "$POPULATED_SCAN" --dry-run 2>&1); rc2=$?
# Expect: one [dry-run] line each for issues 10,11,12,13,14 (5 actionable
# buckets). 15 and 16 (untriaged/unshaped_next) are NOT acted on.
dry_lines=$(printf '%s\n' "$dry_out" | grep -c '^\[dry-run\]' || true)
if [ "$rc2" = 0 ] && [ "$dry_lines" -eq 5 ]; then
  pass CLI-2
else
  fail_case CLI-2 "rc=$rc2 dry_lines=$dry_lines out=[$dry_out]"
fi

# Confirm no gh call happened (dry-run output must not contain "gh " or
# "could not" error strings, which only appear in the live path).
if printf '%s\n' "$dry_out" | grep -qE '(^⚠|^✓)'; then
  fail_case "CLI-2-no-gh" "live-path output leaked into dry-run: [$dry_out]"
fi

# ---------------------------------------------------------------------------
# CLI-3 — missing --scan-file → exit 2 + "Missing --scan-file" on stderr
# ---------------------------------------------------------------------------
err3=$(bash "$APPLY" 2>&1 >/dev/null); rc3=$?
if [ "$rc3" = 2 ] && printf '%s' "$err3" | grep -q "Missing --scan-file"; then
  pass CLI-3
else
  fail_case CLI-3 "rc=$rc3 stderr=[$err3]"
fi

# ---------------------------------------------------------------------------
# CLI-4 — invalid JSON → exit 1 + "Invalid scan JSON" on stderr
# ---------------------------------------------------------------------------
BAD_JSON="$TMP/bad.json"
printf 'not json at all\n' > "$BAD_JSON"
err4=$(bash "$APPLY" --scan-file "$BAD_JSON" --dry-run 2>&1 >/dev/null); rc4=$?
if [ "$rc4" = 1 ] && printf '%s' "$err4" | grep -q "Invalid scan JSON"; then
  pass CLI-4
else
  fail_case CLI-4 "rc=$rc4 stderr=[$err4]"
fi

# ---------------------------------------------------------------------------
# CLI-5 — unknown flag → exit 2 + "Unknown arg:" on stderr
# ---------------------------------------------------------------------------
err5=$(bash "$APPLY" --bogus 2>&1 >/dev/null); rc5=$?
if [ "$rc5" = 2 ] && printf '%s' "$err5" | grep -q "Unknown arg:"; then
  pass CLI-5
else
  fail_case CLI-5 "rc=$rc5 stderr=[$err5]"
fi

# ---------------------------------------------------------------------------
[ "$fail" = 0 ] && { echo "roadmap-maintain-apply contract: SMOKE TEST PASSED"; exit 0; } \
                || { echo "roadmap-maintain-apply contract: SMOKE TEST FAILED" >&2; exit 1; }
