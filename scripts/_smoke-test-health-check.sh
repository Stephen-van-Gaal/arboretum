#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-health-check.sh — Fixture round-trip for the
# generate-register.sh ↔ health-check.sh schema contract.
#
# Builds a minimal arboretum-shaped project in a tempdir, generates
# REGISTER.md from fixture specs, then runs health-check.sh against
# it and asserts a healthy result. Exists to catch producer/consumer
# schema drift between the two scripts — the failure mode behind #124.
#
# Usage: bash scripts/_smoke-test-health-check.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"
CHECK="$SCRIPT_DIR/health-check.sh"

# Both scripts are invoked via `bash <path>`, so the executable bit is
# not required — readability is what we actually need.
[ -f "$GEN" ]   || { echo "FAIL: $GEN not found"   >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }

FIXTURE_PARENT=$(mktemp -d)
FIXTURE="$FIXTURE_PARENT/project[portable]"
trap 'rm -rf "$FIXTURE_PARENT"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Build fixture project ────────────────────────────────────────────

mkdir -p "$FIXTURE/workflows" \
         "$FIXTURE/docs/specs" \
         "$FIXTURE/docs/definitions" \
         "$FIXTURE/.arboretum" \
         "$FIXTURE/scripts" \
         "$FIXTURE/src" \
         "$FIXTURE/tests"

# Minimal scaffolding so health-check Check 1 (governed docs) passes.
echo "# fixture" > "$FIXTURE/workflows/README.md"
echo "# fixture" > "$FIXTURE/CLAUDE.md"
echo "# fixture" > "$FIXTURE/docs/ARCHITECTURE.md"
cat > "$FIXTURE/contracts.yaml" <<'EOF'
specs:
  foo:
    definitions/pubmed-record: v2
EOF

# foo.spec.md — active, owns two files. Exercises the standard
# Check 2 path-resolution and Check 3 ownership-coverage paths.
cat > "$FIXTURE/docs/specs/foo.spec.md" <<'EOF'
---
name: foo
status: active
owner: alice
owns:
  - src/foo.py
  - tests/test_foo.py
---

# foo

Fixture spec.
EOF

# bar.spec.md — active, single owned file.
cat > "$FIXTURE/docs/specs/bar.spec.md" <<'EOF'
---
name: bar
status: active
owner: bob
owns:
  - src/bar.py
---

# bar

Fixture spec.
EOF

# baz.spec.md — draft, no owns. Generates the em-dash (—) sentinel
# in REGISTER.md's Owns column. health-check.sh must skip it
# rather than treating "—" as a missing file path. (Regression
# bait for the em-dash class of bug from #124.)
cat > "$FIXTURE/docs/specs/baz.spec.md" <<'EOF'
---
name: baz
status: draft
owner: carol
---

# baz

Fixture spec.
EOF

echo "# owner: foo" > "$FIXTURE/src/foo.py"
echo "# owner: bar" > "$FIXTURE/src/bar.py"
echo "# owner: foo" > "$FIXTURE/tests/test_foo.py"

cat > "$FIXTURE/docs/definitions/pubmed-record.md" <<'EOF'
# PubMed Record

## Version
v2
EOF

# Consumer-upgrade fixture: a framework-managed script may carry an
# Arboretum owner spec that is not installed in the consumer project.
# health-check Check 3 must not report that vendored file as unowned
# when .arboretum/install-manifest.json identifies it as framework
# material.
cat > "$FIXTURE/scripts/ci-checks.sh" <<'EOF'
#!/usr/bin/env bash
# owner: git-workflow-tooling
EOF
cat > "$FIXTURE/.arboretum/install-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "framework_version": "fixture",
  "files": {
    "scripts/ci-checks.sh": {
      "version": "fixture",
      "sha256": "fixture"
    }
  }
}
EOF

# health-check Check 7 (drift detection) calls `git log` on owned
# files. A non-git fixture causes git to exit 128, which propagates
# through set -euo pipefail and kills the script. Initialize a real
# repo and commit everything in one go so there is no drift —
# Check 7 will report a clean "no drift" rather than mis-firing.
git -C "$FIXTURE" init -q
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture init"

# ── Run generate-register.sh ─────────────────────────────────────────

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero"

[ -f "$FIXTURE/docs/REGISTER.md" ] \
  || fail "REGISTER.md was not generated"

REGISTER_CONTENT=$(cat "$FIXTURE/docs/REGISTER.md")

# Producer must emit the current schema header — column names in
# order. The consumer trims cells with xargs, so whitespace within
# a row isn't part of the contract; assert the column tokens
# directly without locking down exact spacing.
echo "$REGISTER_CONTENT" | grep -Eq '^\|.*Spec.*Status.*Owner.*Owns' \
  || fail "generated REGISTER.md missing current schema header" "$REGISTER_CONTENT"

# Producer must emit the em-dash sentinel for empty owns. Locks
# down the cross-script convention that the consumer relies on.
echo "$REGISTER_CONTENT" | grep -Eq '^\|.*baz\.spec\.md.*draft.*carol.*—' \
  || fail "REGISTER.md did not emit em-dash sentinel for empty owns" "$REGISTER_CONTENT"

# ── Run health-check.sh ──────────────────────────────────────────────

set +e
HEALTH_OUT=$(bash "$CHECK" "$FIXTURE" 2>&1)
HEALTH_RC=$?
set -e

# Headline assertion: a well-formed fixture must pass health-check.
[ "$HEALTH_RC" -eq 0 ] \
  || fail "health-check.sh exit $HEALTH_RC, expected 0" "$HEALTH_OUT"

# Check 2: no owned file should be reported missing. Catches
# schema-column drift (Owner read as path) and em-dash mishandling
# (treating "—" as a path to look up).
echo "$HEALTH_OUT" | grep -q 'file missing' \
  && fail "health-check reported missing files" "$(echo "$HEALTH_OUT" | grep 'file missing')"

# Check 3: no unowned-file warnings. The fixture's source files are
# fully covered by foo.spec.md and bar.spec.md owns lists; if the
# consumer parses the wrong column for owns, every source file
# would slip through ownership matching and surface here.
echo "$HEALTH_OUT" | grep -q 'Unowned:' \
  && fail "health-check flagged unowned files" "$(echo "$HEALTH_OUT" | grep 'Unowned:')"

# Check 3 Half A: framework-managed files listed in the install manifest
# should not fail just because their Arboretum-internal owner specs are
# absent from a consumer root.
echo "$HEALTH_OUT" | grep -q 'Unowned: scripts/ci-checks.sh' \
  && fail "health-check flagged a manifest-managed framework script" \
          "$(echo "$HEALTH_OUT" | grep 'scripts/ci-checks.sh')"

# But the same missing-owner-spec condition must remain a drift finding
# for local scripts that are not framework-managed.
cat > "$FIXTURE/scripts/local-tool.sh" <<'EOF'
#!/usr/bin/env bash
# owner: local-tooling
EOF
set +e
LOCAL_OUT=$(bash "$CHECK" "$FIXTURE" 2>&1)
LOCAL_RC=$?
set -e
echo "$LOCAL_OUT" | grep -q "Unowned: scripts/local-tool.sh — owner 'local-tooling' has no spec" \
  || fail "Check 3 Half A did not flag a non-managed script with a missing owner spec" "$LOCAL_OUT"
[ "$LOCAL_RC" -ne 0 ] \
  || fail "health-check.sh exit 0 despite a non-managed script with a missing owner spec" "$LOCAL_OUT"
rm -f "$FIXTURE/scripts/local-tool.sh"

# The consumer's defensive skip path ("schema not compatible") must
# not trigger when the fresh producer output is fed straight to it.
# If this fires, the producer and consumer disagree on schema —
# exactly the regression #124 introduced.
echo "$HEALTH_OUT" | grep -q 'schema not compatible' \
  && fail "consumer rejected freshly-generated REGISTER.md as incompatible" \
          "$(echo "$HEALTH_OUT" | grep -A1 'schema not compatible')"

# ── Check 3 Half B: general source-ownership scan ────────────────────
#
# Half A (owner-marker scan of .sh/bin/SKILL.md) is exercised by the
# round-trip above. Half B is the general source-ownership scan: it
# walks the project's source roots (src/, tests/, project dir) for
# *.py files and flags any not covered by a spec's owns: patterns —
# the pre-rewrite behaviour that downstream adopter projects depend on.
#
# Drop an orphan .py file into src/ that no spec owns, regenerate, and
# assert Check 3 flags exactly it — while the owned src/foo.py,
# src/bar.py and tests/test_foo.py are NOT flagged.

echo "# stray file with no owning spec" > "$FIXTURE/src/orphan.py"
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "add orphan"

# Regenerate REGISTER.md so generate-register.sh's view is current
# (orphan.py is owned by no spec, so REGISTER.md is unchanged — but
# regenerating keeps producer/consumer in lockstep).
bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero (Half B case)"

set +e
HALFB_OUT=$(bash "$CHECK" "$FIXTURE" 2>&1)
HALFB_RC=$?
set -e

# The orphan .py must be flagged by Check 3's source-ownership scan.
echo "$HALFB_OUT" | grep -q '✗ Unowned: src/orphan.py' \
  || fail "Check 3 Half B did not flag the unowned src/orphan.py" "$HALFB_OUT"

# An owned source file must NOT be flagged — owns: coverage is honoured.
echo "$HALFB_OUT" | grep -q 'Unowned: src/foo.py' \
  && fail "Check 3 Half B flagged the owned src/foo.py" "$HALFB_OUT"

# An unowned source file means drift — health-check must exit non-zero.
[ "$HALFB_RC" -ne 0 ] \
  || fail "health-check.sh exit 0 despite an unowned source file" "$HALFB_OUT"

echo "PASS: fixture round-trip healthy (rc=$HEALTH_RC; schema OK; no missing/unowned)"
echo "PASS: Check 3 Half B flags unowned src/*.py, leaves owned files clean"
