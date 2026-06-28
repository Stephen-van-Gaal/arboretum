#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-check7-dryrun.sh — Check 7 --reconcile --dry-run report-only mode (#666).
#
# The consolidate driver needs drift decisions WITHOUT writes. `--reconcile
# --dry-run` runs the exact branch-scope resolution + drift classification of
# --reconcile, but emits one `DRYRUN-FLIP <spec> <status> <drift-file>
# <spec-last-commit>` line per would-flip spec and makes NO filesystem writes.
#
# Fixture: a local 'main' with spec alpha (active, owns src/alpha.py), committed
# clean; a feature branch drifts src/alpha.py in scope. Under --reconcile
# --dry-run the spec must be REPORTED but neither REGISTER.md nor the spec
# frontmatter may change.
#
# Usage: bash scripts/_smoke-test-check7-dryrun.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail
[ -z "${BASH_VERSION:-}" ] && { echo "Run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"
CHECK="$SCRIPT_DIR/health-check.sh"
[ -f "$GEN" ]   || { echo "FAIL: $GEN not found"   >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }

FIXTURE=$(mktemp -d); trap 'rm -rf "$FIXTURE"' EXIT
fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; exit 1; }
G() { git -C "$FIXTURE" -c user.email=t@t -c user.name=t "$@"; }

mkdir -p "$FIXTURE/docs/specs" "$FIXTURE/docs/definitions" "$FIXTURE/src" "$FIXTURE/workflows"
for f in workflows/README.md CLAUDE.md docs/ARCHITECTURE.md contracts.yaml; do echo "# fixture" > "$FIXTURE/$f"; done

cat > "$FIXTURE/docs/specs/alpha.spec.md" <<'EOF'
---
name: alpha
status: active
owner: alice
owns:
  - src/alpha.py
---

# alpha
Fixture spec.
EOF
printf '# owner: alpha\ndef alpha():\n    return 1\n' > "$FIXTURE/src/alpha.py"

G init -q
G branch -M main
G add . >/dev/null
bash "$GEN" "$FIXTURE" >/dev/null || fail "generate-register.sh failed"
G add . >/dev/null
G commit -q -m "fixture init (alpha active, no drift)"

# Feature branch: drift the owned file in scope (so scoped --reconcile would flip).
G checkout -q -b feat/dryrun-test
printf '# owner: alpha\ndef alpha():\n    return 2\n' > "$FIXTURE/src/alpha.py"
G add src/alpha.py >/dev/null
G commit -q -m "feature: drift alpha in scope"

# Snapshot the two surfaces --reconcile would mutate.
before_reg=$(cat "$FIXTURE/docs/REGISTER.md")
before_fm=$(cat "$FIXTURE/docs/specs/alpha.spec.md")

# ── Test 1: --reconcile --dry-run reports the would-flip decision ──────
set +e; OUT=$(bash "$CHECK" --reconcile --dry-run "$FIXTURE" 2>&1); set -e
echo "$OUT" | grep -qE '^DRYRUN-FLIP alpha\.spec\.md active src/alpha\.py ' \
  || fail "dry-run did not emit DRYRUN-FLIP for the drifted in-scope spec" "$OUT"
echo "PASS (test 1): dry-run reports DRYRUN-FLIP for drifted in-scope spec"

# ── Test 2: --reconcile --dry-run makes NO writes ─────────────────────
[ "$(cat "$FIXTURE/docs/REGISTER.md")" = "$before_reg" ] \
  || fail "dry-run mutated REGISTER.md (must be report-only)" "$(diff <(echo "$before_reg") "$FIXTURE/docs/REGISTER.md")"
[ "$(cat "$FIXTURE/docs/specs/alpha.spec.md")" = "$before_fm" ] \
  || fail "dry-run mutated spec frontmatter (must be report-only)"
[ "$(grep '^status:' "$FIXTURE/docs/specs/alpha.spec.md")" = "status: active" ] \
  || fail "dry-run left spec non-active"
echo "PASS (test 2): dry-run makes no writes; spec stays active"

# ── Test 3: summary + exit code reflect the reported drift ────────────
# A single in-scope drift under dry-run must NOT print "No drift detected" and
# must exit advisory (2), not clean (0) — the DRYRUN-FLIP and the summary agree.
set +e; OUT3=$(bash "$CHECK" --reconcile --dry-run "$FIXTURE" 2>&1); RC3=$?; set -e
printf '%s\n' "$OUT3" | grep -qi 'No drift detected' \
  && fail "dry-run printed 'No drift detected' while emitting DRYRUN-FLIP (contradictory summary)" "$OUT3"
[ "$RC3" -eq 2 ] \
  || fail "dry-run with in-scope drift should exit 2 (advisory), got $RC3" "$OUT3"
echo "PASS (test 3): dry-run summary + exit code reflect the reported drift"

echo "ALL PASS"
