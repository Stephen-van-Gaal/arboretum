#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# _smoke-test-check7-content-aware.sh — Unit-tier test for Check 7's
# content-aware drift classifier (issue #238, epic #640). Builds a
# git fixture with one active spec owning one file, then commits the
# spec, then commits a series of single-class changes to the owned
# file and asserts whether Check 7 emits a ✗ drift line for that spec.
#
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC="$ROOT/scripts/health-check.sh"
FAILED=0
pass() { echo "  PASS: $1"; }
fail_case() { echo "  FAIL: $1"; FAILED=1; }

# Build a minimal git fixture: active spec `omega` owning src/omega.py.
make_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/docs/specs" "$d/docs/definitions" "$d/src" "$d/workflows" "$d/config" "$d/owned-docs"
  touch "$d/CLAUDE.md" "$d/contracts.yaml" "$d/workflows/README.md" "$d/docs/ARCHITECTURE.md"
  (cd "$d" && git init -q && git config user.email t@t && git config user.name t)
  cat > "$d/docs/specs/omega.spec.md" <<'INNER'
---
name: omega
status: active
owner: architecture
owns:
  - src/omega.py
  - src/omega.sql
  - owned-docs/omega.md
  - config/omega.yaml
---

# omega
INNER
  cat > "$d/src/omega.py" <<'INNER'
# owner: omega
def run():
    return 1
INNER
  cat > "$d/src/omega.sql" <<'INNER'
-- owner: omega
SELECT 1;
INNER
  cat > "$d/owned-docs/omega.md" <<'INNER'
---
owner: omega
title: original
---

# Heading One

Body prose.
INNER
  cat > "$d/config/omega.yaml" <<'INNER'
---
setting: old
INNER
  cat > "$d/docs/REGISTER.md" <<'INNER'
# Project Register

## Definitions Index

(none)

## Spec Index

| Spec | Status | Owner | Owns (files/directories) |
|------|--------|-------|--------------------------|
| omega.spec.md | active | architecture | src/omega.py, src/omega.sql, owned-docs/omega.md, config/omega.yaml |

## Status Summary

| Status | Count |
|--------|-------|
| active | 1 |

## Unowned Code

## Dependency Resolution Order
INNER
  (cd "$d" && git add docs/specs/omega.spec.md src/omega.py src/omega.sql owned-docs/omega.md config/omega.yaml docs/REGISTER.md \
              CLAUDE.md contracts.yaml workflows/README.md docs/ARCHITECTURE.md \
   && git commit -q -m "spec+code baseline")
  echo "$d"
}

# Returns 0 if Check 7 reports drift for omega, 1 otherwise.
# Capture first, then grep: health-check exits 1 on drift, and under
# `set -o pipefail` a `… | grep -q` pipeline would propagate that exit
# code instead of grep's match result.
omega_drifts() {
  local out; out="$(bash "$HC" "$1" 2>&1)"
  printf '%s\n' "$out" | grep -q 'omega.spec.md: drift detected'
}

# --- benign: comment-only change → NO drift ---
D="$(make_fixture)"
(cd "$D" && printf '# owner: omega\n# touched\ndef run():\n    return 1\n' > src/omega.py \
   && git add src/omega.py && git commit -q -m "comment only")
if omega_drifts "$D"; then fail_case "comment-only change flagged as drift"; else pass "comment-only → benign"; fi
rm -rf "$D"

# --- benign: SQL (-- prefix) comment-only change → NO drift (#859) ---
# Exercises the broadened _comment_prefix map: a `--` comment edit on an
# owned .sql file must be recognized as benign, not unknown→drift.
D="$(make_fixture)"
(cd "$D" && printf -- '-- owner: omega\n-- a new explanatory comment\nSELECT 1;\n' > src/omega.sql \
   && git add src/omega.sql && git commit -q -m "sql comment only")
if omega_drifts "$D"; then fail_case "sql comment-only change flagged as drift"; else pass "sql comment-only → benign"; fi
rm -rf "$D"

# --- benign: net-empty (change then revert) → NO drift ---
D="$(make_fixture)"
(cd "$D" && sed -i.bak 's/return 1/return 2/' src/omega.py && rm -f src/omega.py.bak \
   && git add src/omega.py && git commit -q -m "change" \
   && sed -i.bak 's/return 2/return 1/' src/omega.py && rm -f src/omega.py.bak \
   && git add src/omega.py && git commit -q -m "revert")
if omega_drifts "$D"; then fail_case "net-empty change flagged as drift"; else pass "net-empty → benign"; fi
rm -rf "$D"

# --- benign: whitespace-only change → NO drift ---
D="$(make_fixture)"
(cd "$D" && printf '# owner: omega\ndef run():\n        return 1\n' > src/omega.py \
   && git add src/omega.py && git commit -q -m "reindent")
if omega_drifts "$D"; then fail_case "whitespace-only change flagged as drift"; else pass "whitespace-only → benign"; fi
rm -rf "$D"

# --- drift: real behaviour change → MUST flag ---
D="$(make_fixture)"
(cd "$D" && printf '# owner: omega\ndef run():\n    return 999\n' > src/omega.py \
   && git add src/omega.py && git commit -q -m "behaviour change")
if omega_drifts "$D"; then pass "behaviour change → drift"; else fail_case "behaviour change NOT flagged"; fi
rm -rf "$D"

# --- drift: pure deletion of real code → MUST flag (regression guard) ---
D="$(make_fixture)"
(cd "$D" && printf '# owner: omega\n' > src/omega.py \
   && git add src/omega.py && git commit -q -m "delete function body")
if omega_drifts "$D"; then pass "code deletion → drift"; else fail_case "code deletion NOT flagged"; fi
rm -rf "$D"

# --- drift: Markdown heading edit in an owned .md → MUST flag (#238 review:
#     `.md` headings are content, not comments). ---
D="$(make_fixture)"
(cd "$D" && sed -i.bak 's/# Heading One/# Heading Two/' owned-docs/omega.md && rm -f owned-docs/omega.md.bak \
   && git add owned-docs/omega.md && git commit -q -m "edit heading")
if omega_drifts "$D"; then pass "md heading change → drift"; else fail_case "md heading change NOT flagged (treated as comment-only?)"; fi
rm -rf "$D"

# --- benign: Markdown frontmatter-only edit in an owned .md → NO drift ---
D="$(make_fixture)"
(cd "$D" && sed -i.bak 's/title: original/title: changed/' owned-docs/omega.md && rm -f owned-docs/omega.md.bak \
   && git add owned-docs/omega.md && git commit -q -m "frontmatter edit")
if omega_drifts "$D"; then fail_case "md frontmatter-only change flagged as drift"; else pass "md frontmatter-only → benign"; fi
rm -rf "$D"

# --- drift: value change in an owned .yaml that opens with `---` → MUST flag
#     (#238 review: YAML `---` is a document marker, not frontmatter). ---
D="$(make_fixture)"
(cd "$D" && printf '%s\n' '---' 'setting: new' > config/omega.yaml \
   && git add config/omega.yaml && git commit -q -m "yaml value change")
if omega_drifts "$D"; then pass "yaml value change → drift"; else fail_case "yaml value change NOT flagged (frontmatter-stripped?)"; fi
rm -rf "$D"

# --- drift: internal-whitespace change in .md body → MUST flag (#238 review:
#     collapsing internal whitespace can hide meaningful data changes). ---
D="$(make_fixture)"
(cd "$D" && sed -i.bak 's/Body prose./Body  prose./' owned-docs/omega.md && rm -f owned-docs/omega.md.bak \
   && git add owned-docs/omega.md && git commit -q -m "internal whitespace")
if omega_drifts "$D"; then pass "internal-whitespace change → drift"; else fail_case "internal-whitespace change NOT flagged"; fi
rm -rf "$D"

[ "$FAILED" -eq 0 ] && echo "check7-content-aware: ALL PASS" || { echo "check7-content-aware: FAILURES"; exit 1; }
