#!/usr/bin/env bash
# owner: framework-scope-marker
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-adopter-scope-boundary.sh — end-to-end boundary assertion (#836):
# a simulated adopter root (vendored framework files, NO dev specs) produces zero
# framework-attributable health-check findings, in BOTH manifest-present and
# manifest-absent states. The manifest-absent case is the regression that the
# in-file marker fixes — manifest membership alone would mass-flag every file.
set -euo pipefail
if [ -z "${BASH_VERSION:-}" ]; then echo "Error: requires bash. Run: bash $0" >&2; exit 1; fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/health-check.sh"
RESOLVE="$SCRIPT_DIR/lib/scope-resolve.sh"

FIXP=$(mktemp -d); trap 'rm -rf "$FIXP"' EXIT
FIX="$FIXP/adopter"
mkdir -p "$FIX/workflows" "$FIX/docs/specs" "$FIX/scripts/lib" "$FIX/.arboretum"

# Minimal adopter scaffolding so Check 1 (governed docs) is satisfied. Crucially,
# this is NOT a plugin root (no skills/hooks/contracts/fixtures), so the `# scope:`
# marker IS consulted — markers only relax enforcement in consumer roots.
echo "# adopter" > "$FIX/workflows/README.md"
echo "# adopter" > "$FIX/CLAUDE.md"
echo "# adopter" > "$FIX/docs/ARCHITECTURE.md"

# A REGISTER.md with a current-schema Spec Index is required, or health-check
# exits at Check 1 ("Register not found — skipping checks 2-5") and never
# reaches the Check 3 owner/scope logic this test exists to guard.
cat > "$FIX/docs/REGISTER.md" <<'EOF'
# Register

## Spec Index

| Spec | Status | Owner | Owns |
|---|---|---|---|
| example.spec.md | active | architecture | `src/nothing.py` |
EOF

# Vendor a framework helper + a framework script, both carrying the real marker
# and dev-only owners whose specs are absent from this adopter root.
cp "$RESOLVE" "$FIX/scripts/lib/scope-resolve.sh"
cat > "$FIX/scripts/framework-tool.sh" <<'EOF'
#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
echo hi
EOF

git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIX" -c user.email=t@t -c user.name=t commit -q -m "adopter init"

run_case() {
  local label="$1" out
  set +e
  out=$(bash "$CHECK" "$FIX" 2>&1)
  set -e
  # Guard against the vacuous-pass trap: assert the run actually reached Check 3
  # (the scope logic) instead of early-exiting at Check 1. Without this, the
  # absence of `Unowned:` lines proves nothing.
  if ! echo "$out" | grep -q 'Check 3: Unowned source files'; then
    echo "FAIL: health-check never reached Check 3 ($label) — fixture scaffolding insufficient" >&2
    echo "$out" | grep -iE 'skipping checks|Register not found' >&2 || true
    exit 1
  fi
  if echo "$out" | grep -qE 'Unowned: scripts/(framework-tool\.sh|lib/scope-resolve\.sh)'; then
    echo "FAIL: framework file flagged ($label)" >&2
    echo "$out" | grep 'Unowned: scripts/' >&2
    exit 1
  fi
  echo "PASS: clean ($label)"
}

# Manifest present but empty — marker, not manifest membership, must do the work.
printf '{"schema_version":1,"framework_version":"0.0.0","updated_at":null,"files":{}}' \
  > "$FIX/.arboretum/install-manifest.json"
run_case "manifest present (empty)"

# Manifest absent — the regression case. Without the marker this mass-flags.
rm -f "$FIX/.arboretum/install-manifest.json"
run_case "manifest absent"

echo "ALL PASS"
