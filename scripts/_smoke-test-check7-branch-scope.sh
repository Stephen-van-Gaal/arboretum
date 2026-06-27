#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-check7-branch-scope.sh — Check 7 --reconcile branch-scoping (#750).
#
# Fixture: a local 'main' with TWO active specs, both drifted (each owns a file
# changed after the spec's last commit). A feature branch changes ONLY spec-A's
# owned file. Under default --reconcile, only spec-A may flip; spec-B (drift on
# main, untouched by the branch) must stay active. Under --reconcile --all, both
# flip. On main itself (HEAD == base), nothing flips.
#
# Usage: bash scripts/_smoke-test-check7-branch-scope.sh
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
echo "# fixture" > "$FIXTURE/workflows/README.md"
echo "# fixture" > "$FIXTURE/CLAUDE.md"
echo "# fixture" > "$FIXTURE/docs/ARCHITECTURE.md"
echo "# fixture" > "$FIXTURE/contracts.yaml"

for s in a b; do
  cat > "$FIXTURE/docs/specs/$s.spec.md" <<EOF
---
name: $s
status: active
owner: alice
owns:
  - src/$s.py
---

# $s
Fixture spec.
EOF
  printf '# owner: %s\ndef %s():\n    return 1\n' "$s" "$s" > "$FIXTURE/src/$s.py"
done

G init -q
G branch -M main
G add . >/dev/null
bash "$GEN" "$FIXTURE" >/dev/null || fail "generate-register.sh failed"
G add . >/dev/null
G commit -q -m "fixture init (specs a,b active)"

# Drift BOTH owned files on main, in a commit AFTER the specs' commit.
printf '# owner: a\ndef a():\n    return 2\n' > "$FIXTURE/src/a.py"
printf '# owner: b\ndef b():\n    return 2\n' > "$FIXTURE/src/b.py"
G add src/a.py src/b.py >/dev/null
G commit -q -m "drift a and b on main"

# Feature branch: change ONLY a.py further (b stays main-only drift).
G checkout -q -b feat/scope-test
printf '# owner: a\ndef a():\n    return 3\n' > "$FIXTURE/src/a.py"
G add src/a.py >/dev/null
G commit -q -m "feature: touch a only"

status_of() { grep '^status:' "$FIXTURE/docs/specs/$1.spec.md"; }
# Restore the committed (active) state of BOTH surfaces Check 7 mutates — the
# spec frontmatter AND the REGISTER.md row. Check 7 reads status from REGISTER,
# so resetting only the spec file would leave a stale REGISTER row that makes
# the next sub-case skip the spec. git checkout HEAD restores exactly the
# committed active state on whichever branch is current.
reset_active() {
  G checkout HEAD -- docs/specs/a.spec.md docs/specs/b.spec.md docs/REGISTER.md
}

# ── Test 1: default --reconcile on feature branch → only A flips ─────
B_BEFORE=$(status_of b)
set +e; OUT=$(bash "$CHECK" --reconcile "$FIXTURE" 2>&1); set -e
[ "$(status_of a)" = "status: stale" ] \
  || fail "scoped --reconcile did not flip in-scope spec A" "$OUT"
[ "$(status_of b)" = "$B_BEFORE" ] \
  || fail "scoped --reconcile flipped OUT-OF-SCOPE spec B (the #750 bug)" "$OUT"
echo "$OUT" | grep -qiE 'outside .*scope|out-of-scope|not flipped' \
  || fail "no out-of-scope advisory roll-up emitted" "$OUT"
# Both surfaces must move together on the scoped path (split-surface drift, #124):
# assert A's REGISTER row flipped to stale and B's row stayed active.
grep 'a\.spec\.md' "$FIXTURE/docs/REGISTER.md" | grep -q 'stale' \
  || fail "scoped --reconcile left spec A's REGISTER row unflipped (split-surface)" "$(grep '\.spec\.md' "$FIXTURE/docs/REGISTER.md")"
grep 'b\.spec\.md' "$FIXTURE/docs/REGISTER.md" | grep -q 'active' \
  || fail "scoped --reconcile flipped spec B's REGISTER row (out-of-scope)" "$(grep '\.spec\.md' "$FIXTURE/docs/REGISTER.md")"
echo "PASS (test 1): scoped reconcile flips A (both surfaces) only, B surfaced not flipped"

# ── Test 2: --reconcile --all → both flip ────────────────────────────
reset_active
set +e; OUT=$(bash "$CHECK" --reconcile --all "$FIXTURE" 2>&1); set -e
{ [ "$(status_of a)" = "status: stale" ] && [ "$(status_of b)" = "status: stale" ]; } \
  || fail "--reconcile --all did not flip both specs" "$OUT"
echo "PASS (test 2): --reconcile --all flips both"

# ── Test 3: on main (HEAD == base) → nothing flips, advises --all ────
reset_active
G checkout -q main
set +e; OUT=$(bash "$CHECK" --reconcile "$FIXTURE" 2>&1); set -e
{ [ "$(status_of a)" = "status: active" ] && [ "$(status_of b)" = "status: active" ]; } \
  || fail "scoped --reconcile on main flipped specs (footgun not closed)" "$OUT"
echo "$OUT" | grep -qiE 'no branch scope|--reconcile --all|repo-wide|integration branch' \
  || fail "on-main run did not advise --all" "$OUT"
echo "PASS (test 3): on-main reconcile flips nothing, advises --all"

# ── Test 4: multi-file spec — drift OUT of scope, in-scope change is benign ──
#
# Scope membership must be decided on the DRIFTED file, not on any owned file
# (#750 review finding 1). Spec C owns c1.py + c2.py. On main, c1.py drifts
# (non-benign, OUT of the branch). The feature branch makes only a BENIGN
# (comment-only) edit to c2.py — in scope, but not itself drift. Default
# --reconcile must NOT flip C (its only drift, c1.py, is out of scope); --all
# must flip it. Guards against regressing to "flip if any owned file in scope".
F4=$(mktemp -d); trap 'rm -rf "$FIXTURE" "$F4"' EXIT
G4() { git -C "$F4" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$F4/docs/specs" "$F4/docs/definitions" "$F4/src" "$F4/workflows"
for f in workflows/README.md CLAUDE.md docs/ARCHITECTURE.md contracts.yaml; do echo "# fixture" > "$F4/$f"; done
cat > "$F4/docs/specs/c.spec.md" <<'EOF'
---
name: c
status: active
owner: alice
owns:
  - src/c1.py
  - src/c2.py
---

# c
Fixture spec.
EOF
printf '# owner: c\ndef c1():\n    return 1\n' > "$F4/src/c1.py"
printf '# owner: c\ndef c2():\n    return 1\n' > "$F4/src/c2.py"
G4 init -q; G4 branch -M main; G4 add . >/dev/null
bash "$GEN" "$F4" >/dev/null || fail "generate-register.sh failed (F4)"
G4 add . >/dev/null; G4 commit -q -m "spec c (c1,c2) active"
# Main: c1.py non-benign drift (OUT of the branch's scope).
printf '# owner: c\ndef c1():\n    return 2\n' > "$F4/src/c1.py"
G4 add src/c1.py >/dev/null; G4 commit -q -m "drift c1 on main"
# Feature branch: BENIGN (comment-only) edit to c2.py — in scope, not drift.
G4 checkout -q -b feat/c-scope
printf '# owner: c\n# benign note\ndef c2():\n    return 1\n' > "$F4/src/c2.py"
G4 add src/c2.py >/dev/null; G4 commit -q -m "feature: benign comment on c2"
c_status() { grep '^status:' "$F4/docs/specs/c.spec.md"; }

set +e; OUT=$(bash "$CHECK" --reconcile "$F4" 2>&1); set -e
[ "$(c_status)" = "status: active" ] \
  || fail "scoped --reconcile flipped C, but its only drift (c1.py) is OUT of branch scope (#750 finding 1)" "$OUT"
G4 checkout HEAD -- docs/specs/c.spec.md docs/REGISTER.md
set +e; OUT=$(bash "$CHECK" --reconcile --all "$F4" 2>&1); set -e
[ "$(c_status)" = "status: stale" ] \
  || fail "--reconcile --all did not flip C despite c1.py drift" "$OUT"
echo "PASS (test 4): scope is decided on the drifted file, not any owned file"

# ── Test 5: clean --reconcile on the integration branch → exit 0, no roll-up ──
#
# Scope resolution must not, by itself, turn a clean run advisory (#750 review
# finding C / HC-2). Fixture: one active spec with NO drift, on main (HEAD ==
# base). --reconcile must flip nothing, emit no scope roll-up, and exit 0.
F5=$(mktemp -d); trap 'rm -rf "$FIXTURE" "$F4" "$F5"' EXIT
G5() { git -C "$F5" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$F5/docs/specs" "$F5/docs/definitions" "$F5/src" "$F5/workflows"
for f in workflows/README.md CLAUDE.md docs/ARCHITECTURE.md contracts.yaml; do echo "# fixture" > "$F5/$f"; done
cat > "$F5/docs/specs/d.spec.md" <<'EOF'
---
name: d
status: active
owner: alice
owns:
  - src/d.py
---

# d
EOF
printf '# owner: d\ndef d():\n    return 1\n' > "$F5/src/d.py"
G5 init -q; G5 branch -M main; G5 add . >/dev/null
bash "$GEN" "$F5" >/dev/null || fail "generate-register.sh failed (F5)"
G5 add . >/dev/null; G5 commit -q -m "spec d + owned file, no drift"   # spec & owned file same commit → no drift
set +e; OUT=$(bash "$CHECK" --reconcile "$F5" 2>&1); RC=$?; set -e
[ "$(grep '^status:' "$F5/docs/specs/d.spec.md")" = "status: active" ] \
  || fail "clean --reconcile on-base flipped a non-drifted spec" "$OUT"
echo "$OUT" | grep -qiE 'not reconciled|outside .*scope|integration branch' \
  && fail "clean --reconcile emitted a scope roll-up despite no drift (finding C)" "$OUT"
[ "$RC" -eq 0 ] \
  || fail "clean --reconcile on-base did not exit 0 (got $RC) — scope resolution alone made it advisory (HC-2)" "$OUT"
echo "PASS (test 5): clean --reconcile on integration branch exits 0, no roll-up"

# ── Test 6: --all without --reconcile → no-op info, no mutation ──────────────
#
# #750 review finding A: --all is meaningful only with --reconcile; report it,
# don't silently ignore it, and never mutate. Reuse F4 (spec C, drift on c1.py).
G4 checkout HEAD -- docs/specs/c.spec.md docs/REGISTER.md 2>/dev/null
set +e; OUT=$(bash "$CHECK" --all "$F4" 2>&1); RC=$?; set -e
[ "$(grep '^status:' "$F4/docs/specs/c.spec.md")" = "status: active" ] \
  || fail "--all without --reconcile mutated a spec (must be read-only)" "$OUT"
echo "$OUT" | grep -qiE 'all .*no effect|no effect without --reconcile' \
  || fail "--all without --reconcile was silently ignored (finding A)" "$OUT"
echo "PASS (test 6): --all without --reconcile is a reported no-op, no mutation"

# ── Test 7: directory owns: — in-scope child drift flips on a feature branch ──
#
# #892 (#865 codex P2 follow-up): with directory owns: (trailing slash, e.g.
# `src/`) now resolving in _owns_map_covers, Check 7's drift loop must resolve
# the owns entry to its concrete child files — not record the directory itself.
# Otherwise scoped --reconcile compares "src/" exactly against git-diff child
# paths ("src/foo.py") and never matches, so a directory-owned spec never
# auto-stales on a feature branch. Fixture: spec E owns the directory src/; a
# child src/foo.py changes in scope → expect flip (both surfaces).
F7=$(mktemp -d); trap 'rm -rf "$FIXTURE" "$F4" "$F5" "$F7"' EXIT
G7() { git -C "$F7" -c user.email=t@t -c user.name=t "$@"; }
mkdir -p "$F7/docs/specs" "$F7/docs/definitions" "$F7/src" "$F7/workflows"
for f in workflows/README.md CLAUDE.md docs/ARCHITECTURE.md contracts.yaml; do echo "# fixture" > "$F7/$f"; done
cat > "$F7/docs/specs/e.spec.md" <<'EOF'
---
name: e
status: active
owner: alice
owns:
  - src/
---

# e
Fixture spec — directory owns.
EOF
printf '# owner: e\ndef foo():\n    return 1\n' > "$F7/src/foo.py"
G7 init -q; G7 branch -M main; G7 add . >/dev/null
bash "$GEN" "$F7" >/dev/null || fail "generate-register.sh failed (F7)"
G7 add . >/dev/null; G7 commit -q -m "spec e (owns src/) + child, no drift"   # spec & child same commit → no drift yet
# Feature branch: change the in-scope child src/foo.py (non-benign).
G7 checkout -q -b feat/dir-owns
printf '# owner: e\ndef foo():\n    return 2\n' > "$F7/src/foo.py"
G7 add src/foo.py >/dev/null; G7 commit -q -m "feature: change in-scope child of src/"
e_status() { grep '^status:' "$F7/docs/specs/e.spec.md"; }
set +e; OUT=$(bash "$CHECK" --reconcile "$F7" 2>&1); set -e
[ "$(e_status)" = "status: stale" ] \
  || fail "scoped --reconcile did not flip directory-owned spec E after in-scope child drift (#892)" "$OUT"
grep 'e\.spec\.md' "$F7/docs/REGISTER.md" | grep -q 'stale' \
  || fail "scoped --reconcile left directory-owned spec E's REGISTER row unflipped (#892 split-surface)" "$(grep '\.spec\.md' "$F7/docs/REGISTER.md")"
echo "PASS (test 7): directory owns flips on in-scope child drift (both surfaces)"

echo "ALL PASS"
