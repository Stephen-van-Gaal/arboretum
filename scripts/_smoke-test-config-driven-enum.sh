#!/usr/bin/env bash
# owner: project-infrastructure
# _smoke-test-config-driven-enum.sh — Verify health-check honours a
# `status_enum:` block in .arboretum.yml: validates against the
# project-declared vocabulary, warns on truly-unknown statuses, and
# auto-flips configured active_states → configured stale_state.
#
# Issue stvangaal/arboretum#12, Option C: graceful no-op (PR #196) was
# better than nothing but lost two signals — Check 6 stopped catching
# typos, and Check 7 stopped flipping drift. With `status_enum:` the
# plugin defers to the project's vocabulary and restores both.
#
# Companion to _smoke-test-extended-enum.sh, which covers the unconfigured
# path (no .arboretum.yml status_enum → canonical draft/active/stale
# fallback with extended-enum no-op acknowledgement).
#
# Usage: bash scripts/_smoke-test-config-driven-enum.sh
# Exit 0 if all assertions pass, 1 otherwise.

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/generate-register.sh"
CHECK="$SCRIPT_DIR/health-check.sh"

[ -f "$GEN" ]   || { echo "FAIL: $GEN not found"   >&2; exit 1; }
[ -f "$CHECK" ] || { echo "FAIL: $CHECK not found" >&2; exit 1; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && { echo "----- detail -----" >&2; echo "$2" >&2; }
  exit 1
}

# ── Build fixture project with config-driven four-state enum ─────────

mkdir -p "$FIXTURE/workflows" \
         "$FIXTURE/docs/specs" \
         "$FIXTURE/docs/definitions" \
         "$FIXTURE/src" \
         "$FIXTURE/tests"

echo "# fixture" > "$FIXTURE/workflows/README.md"
echo "# fixture" > "$FIXTURE/CLAUDE.md"
echo "# fixture" > "$FIXTURE/docs/ARCHITECTURE.md"
echo "# fixture" > "$FIXTURE/contracts.yaml"

# .arboretum.yml declares the project's status vocabulary. `stale` is
# included in states so post-flip values from Check 7 remain valid.
# active_states names the subset eligible for drift auto-flip.
cat > "$FIXTURE/.arboretum.yml" <<'EOF'
layer: 2

status_enum:
  states: [draft, ready, in-progress, implemented, stale]
  active_states: [implemented]
  stale_state: stale
EOF

# alpha — valid configured state, no drift. Must not warn.
cat > "$FIXTURE/docs/specs/alpha.spec.md" <<'EOF'
---
name: alpha
status: ready
owner: alice
owns:
  - src/alpha.py
---

# alpha
EOF

# beta — TYPO. 'in-progres' (missing trailing 's'). Must warn in Check 6
# naming the offending value AND the configured allowlist so the adopter
# can correct it. This is the typo signal Option A's graceful no-op
# dropped — restoring it is the headline win of Option C.
cat > "$FIXTURE/docs/specs/beta.spec.md" <<'EOF'
---
name: beta
status: in-progres
owner: bob
owns:
  - src/beta.py
---

# beta
EOF

# gamma — valid configured active_state. Owned file will be modified
# after commit to trigger Check 7 drift; must auto-flip to the
# configured stale_state (`stale`), not silently no-op.
cat > "$FIXTURE/docs/specs/gamma.spec.md" <<'EOF'
---
name: gamma
status: implemented
owner: carol
owns:
  - src/gamma.py
---

# gamma
EOF

echo "# owner: alpha" > "$FIXTURE/src/alpha.py"
echo "# owner: beta"  > "$FIXTURE/src/beta.py"
echo "# owner: gamma" > "$FIXTURE/src/gamma.py"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture init"

# Trigger drift on gamma: a SECOND commit touching only src/gamma.py.
# Check 7 compares `git log -1` of the spec vs each owned file — drift
# means the owned file has a strictly newer commit than the spec.
# Modifying the file without committing isn't enough (same commit hash).
echo "# owner: gamma (modified)" > "$FIXTURE/src/gamma.py"
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add src/gamma.py >/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "edit gamma owned file"

bash "$GEN" "$FIXTURE" >/dev/null \
  || fail "generate-register.sh exited non-zero"

# ── Run health-check and inspect Check 6/7 behaviour ─────────────────

set +e
HEALTH_OUT=$(bash "$CHECK" "$FIXTURE" 2>&1)
HEALTH_RC=$?
set -e

# Exit code: must be non-zero. The fixture has both a typo (Check 6 warn)
# and a real drift event (Check 7 flip). Either alone would already set
# `drift_found=true` and propagate to exit 1. If exit becomes 0, the
# script suppressed either the typo warning or the drift detection.
[ "$HEALTH_RC" -ne 0 ] \
  || fail "health-check exit 0, expected non-zero (fixture has both a typo and a drift event)" "$HEALTH_OUT"

# Filter to Check 6 block so substring asserts don't match output
# elsewhere (e.g. a `status: ready` line in spec content).
CHECK6_BLOCK=$(echo "$HEALTH_OUT" | sed -n '/Check 6:/,/━━━ Check [0-9]/p')

# Assertion 1 — typo gets per-spec warning. Must name the bad value
# AND beta's spec name so the adopter knows which file to fix.
echo "$CHECK6_BLOCK" | grep -qF "beta" \
  || fail "Check 6 did not name beta in warning" "$HEALTH_OUT"
echo "$CHECK6_BLOCK" | grep -qF "in-progres" \
  || fail "Check 6 did not echo the typo value 'in-progres'" "$HEALTH_OUT"

# Assertion 2 — valid configured states do NOT warn. If we see
# "alpha" or "gamma" inside any WARN line in Check 6, that's a
# false positive against the configured vocabulary.
if echo "$CHECK6_BLOCK" | grep -E '^[[:space:]]*WARN' | grep -qE 'alpha|gamma'; then
  fail "Check 6 warned on valid configured state for alpha or gamma" "$CHECK6_BLOCK"
fi

# Assertion 3 — Check 6 must NOT emit the generic "extended status enum"
# info line when the project has explicitly configured its vocabulary.
# That info line is for the unconfigured fallback path only.
echo "$CHECK6_BLOCK" | grep -qF "Project uses extended status enum" \
  && fail "Check 6 emitted generic extended-enum info line despite explicit status_enum: config" "$HEALTH_OUT"

# Assertion 4 — Check 7 must auto-flip gamma to the configured
# stale_state, not no-op silently. Read the resulting frontmatter.
if ! grep -qE '^status: stale[[:space:]]*$' "$FIXTURE/docs/specs/gamma.spec.md"; then
  fail "Check 7 did not flip gamma's status to configured stale_state" \
       "$(cat "$FIXTURE/docs/specs/gamma.spec.md")"
fi

# Assertion 5 — alpha (ready, no drift) must remain at its configured
# state. A buggy implementation might flip every non-stale spec.
if ! grep -qE '^status: ready[[:space:]]*$' "$FIXTURE/docs/specs/alpha.spec.md"; then
  fail "alpha was mutated (should remain 'ready')" \
       "$(cat "$FIXTURE/docs/specs/alpha.spec.md")"
fi

# Assertion 6 — REGISTER.md Status Summary table must include rows for
# extended states observed at generate-register time. Pre-fix the loop
# iterated only `draft active stale` and silently dropped ready / in-
# progress / implemented from the summary, leaving an empty table for
# extended-enum projects. Status Summary is generated once at register
# time (pre-flip), so we expect the three originally-declared statuses
# AND the typo value (generate-register reports, it does not validate).
SUMMARY=$(sed -n '/## Status Summary/,/^## /p' "$FIXTURE/docs/REGISTER.md")
for expect in 'ready' 'in-progres' 'implemented'; do
  echo "$SUMMARY" | grep -qE "^\| ${expect} \| [0-9]+ \|" \
    || fail "Status Summary missing row for state '$expect'" "$SUMMARY"
done

echo "PASS [happy-path]: typo warns, valid states don't, drift flips, Status Summary reflects observed states"

# ── Adversarial sub-cases ────────────────────────────────────────────
#
# Each sub-case builds a tiny fresh fixture rooted at $FIXTURE2, swaps in
# a malformed (or partially-formed) .arboretum.yml, then asserts that
# health-check fails closed onto canonical defaults instead of running
# the project's enum in a half-applied state. The shared helper keeps the
# boilerplate (mkdir, init commit, gen) consistent across cases.

make_minimal_fixture() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/workflows" "$dir/docs/specs" "$dir/docs/definitions" "$dir/src"
  echo "# fixture" > "$dir/workflows/README.md"
  echo "# fixture" > "$dir/CLAUDE.md"
  echo "# fixture" > "$dir/docs/ARCHITECTURE.md"
  echo "# fixture" > "$dir/contracts.yaml"
  cat > "$dir/docs/specs/widget.spec.md" <<'EOF'
---
name: widget
status: active
owner: alice
owns:
  - src/widget.py
---

# widget
EOF
  echo "# owner: widget" > "$dir/src/widget.py"
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t add . >/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m "init"
  # Trigger drift on widget so Check 7 has something to act on.
  echo "# owner: widget (modified)" > "$dir/src/widget.py"
  git -C "$dir" -c user.email=t@t -c user.name=t add src/widget.py >/dev/null
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q -m "edit"
  bash "$GEN" "$dir" >/dev/null
}

FIXTURE2="${FIXTURE}/sub"

# Sub-case A — partial config: active_states without states.
# Pre-fix: STATUS_ENUM_CONFIGURED stayed false (Check 6 treated as
# unconfigured) but STATUS_ACTIVE_STATES was overridden — Check 7 would
# flip `implemented → stale` despite Check 6 emitting the "extended enum
# no-op" line. Two-mode contradiction. Post-fix: the block is ignored
# entirely because `states:` is absent; canonical active → stale runs.
make_minimal_fixture "$FIXTURE2"
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  active_states: [implemented]
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
# Widget is at canonical 'active' and has drift → must flip to 'stale'
# (canonical default), proving active_states alone did NOT override.
grep -qE '^status: stale[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
  || fail "[partial-config] widget did not flip to canonical 'stale' (partial config should be ignored)" "$SUB_OUT"
echo "PASS [partial-config]: active_states without states is ignored; canonical defaults retained"

# Sub-case B — scalar states value (user typo: forgot the list syntax).
# Pre-fix (PyYAML path): `[str(x) for x in 'draft']` iterates the chars
# → STATUS_STATES becomes (d r a f t) and Check 6 warns on every spec.
# Post-fix: the parser emits ERROR:, defaults retained, stderr explains.
make_minimal_fixture "$FIXTURE2"
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: draft
  active_states: [active]
  stale_state: stale
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
echo "$SUB_OUT" | grep -qF "status_enum config rejected" \
  || fail "[scalar-states] did not surface rejection message" "$SUB_OUT"
# Widget should still get the canonical active → stale flip because
# defaults are preserved when the block is rejected.
grep -qE '^status: stale[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
  || fail "[scalar-states] canonical defaults not preserved (widget did not flip)" "$SUB_OUT"
echo "PASS [scalar-states]: scalar list value rejected, canonical defaults retained"

# Sub-case C — stale_state omitted: spec says "warn-only, do not flip".
# Pre-fix: STATUS_STALE_STATE defaulted to "stale" and was never reset
# when only states/active_states were declared, so omission silently
# became "flip to stale" anyway — directly contradicting docs.
# Post-fix: states: present triggers reset of STATUS_STALE_STATE to ""
# before applying, so omission keeps it empty and Check 7 warn-only.
make_minimal_fixture "$FIXTURE2"
# Replace widget's status to match the configured active_states value
# so Check 7 actually picks it up under the new vocabulary.
sed -i.bak 's/^status: active$/status: implemented/' "$FIXTURE2/docs/specs/widget.spec.md"
rm -f "$FIXTURE2/docs/specs/widget.spec.md.bak"
# Regenerate REGISTER so the new status flows through.
bash "$GEN" "$FIXTURE2" >/dev/null
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: [draft, ready, implemented]
  active_states: [implemented]
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
# Widget must remain 'implemented' — no stale_state means no flip.
grep -qE '^status: implemented[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
  || fail "[stale-omitted] widget was flipped despite stale_state omission" \
          "$(cat "$FIXTURE2/docs/specs/widget.spec.md")"
# But the drift must still be surfaced as a warning (warn-only mode).
echo "$SUB_OUT" | grep -qF "no stale_state configured" \
  || fail "[stale-omitted] drift was not surfaced as warn-only" "$SUB_OUT"
echo "PASS [stale-omitted]: drift warned but spec not mutated when stale_state absent"

# Sub-case D — invalid token (regex metachar).
# Pre-fix: a value like `stale_state: qa/review` would be interpolated
# unescaped into the Check 7 sed call, breaking under `set -e`. Worse,
# any metachar in STATUS_STATES values could survive to one sed site
# but not another (REGISTER's `${spec_name} | ${status}` pattern vs the
# spec-file frontmatter pattern), creating partial flips that desync
# the two files. Post-fix: the validator rejects the whole block when
# any token contains chars outside [A-Za-z0-9_-].
make_minimal_fixture "$FIXTURE2"
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: [draft, ready, "qa/review", stale]
  active_states: [ready]
  stale_state: "qa/review"
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
echo "$SUB_OUT" | grep -qF "status_enum config rejected" \
  || fail "[invalid-token] did not surface rejection message for 'qa/review'" "$SUB_OUT"
# REGISTER row for widget must still be flippable under canonical
# defaults, proving the bad block was ignored cleanly.
grep -qE '^\| widget\.spec\.md \| stale \|' "$FIXTURE2/docs/REGISTER.md" \
  || fail "[invalid-token] REGISTER not flipped to canonical 'stale' after block rejected" \
          "$(cat "$FIXTURE2/docs/REGISTER.md")"
echo "PASS [invalid-token]: regex/sed metachar in token rejected before any sed runs"

# Sub-case E — active_states contains a token not in states.
# Pre-fix (round 1): each field was validated only for shape, not for
# internal consistency. Result: a spec at status `implemented` would
# trigger Check 6 to warn "unknown status" (because 'implemented' isn't
# in [draft, ready, stale]) AND simultaneously trigger Check 7 to flip
# it (because 'implemented' IS in active_states). Same split-brain class
# as the original A/C bug, just at a different layer (membership rather
# than presence). Post-fix: parser rejects the whole block; defaults
# kept; widget gets canonical active → stale flip.
make_minimal_fixture "$FIXTURE2"
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: [draft, ready, stale]
  active_states: [implemented]
  stale_state: stale
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
echo "$SUB_OUT" | grep -qF "status_enum config rejected" \
  || fail "[active-not-in-states] did not surface rejection message" "$SUB_OUT"
echo "$SUB_OUT" | grep -qF "active_states contains tokens not in states" \
  || fail "[active-not-in-states] rejection didn't name the cause" "$SUB_OUT"
grep -qE '^status: stale[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
  || fail "[active-not-in-states] canonical defaults not preserved (widget didn't flip)" "$SUB_OUT"
echo "PASS [active-not-in-states]: active_states ⊄ states rejected at parse time"

# Sub-case F — stale_state not declared in states.
# Pre-fix: parser only checked stale_state token shape, not membership.
# A config like `stale_state: archived` with `states: [draft, ready,
# stale]` would have Check 7 write `archived` into specs and REGISTER —
# then Check 6 on the next run would warn on every flipped spec as
# "unknown status". Post-fix: the membership invariant is enforced at
# parse time, so Check 7 can't ever write a status outside the user's
# declared vocabulary.
make_minimal_fixture "$FIXTURE2"
cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: [draft, ready, stale]
  active_states: [ready]
  stale_state: archived
EOF
set +e
SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
set -e
echo "$SUB_OUT" | grep -qF "status_enum config rejected" \
  || fail "[stale-not-in-states] did not surface rejection message" "$SUB_OUT"
echo "$SUB_OUT" | grep -qF "stale_state 'archived' is not in states" \
  || fail "[stale-not-in-states] rejection didn't name the bad value" "$SUB_OUT"
grep -qE '^status: stale[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
  || fail "[stale-not-in-states] canonical defaults not preserved" "$SUB_OUT"
echo "PASS [stale-not-in-states]: stale_state ∉ states rejected at parse time"

# Sub-case G — malformed YAML.
# Pre-fix: `except Exception` caught both ImportError (PyYAML absent →
# legitimate fallback) and yaml.YAMLError (PyYAML present but file is
# broken → should be a hard reject). A file with unclosed flow lists or
# bad indentation under `status_enum:` would silently fall through to
# the regex parser and could partially accept. Post-fix: YAMLError emits
# ERROR: explicitly; the regex fallback only runs when PyYAML is absent.
#
# Skip this assertion if PyYAML isn't installed in the test environment
# (the malformed-YAML rejection only applies on the PyYAML-present path;
# without PyYAML the regex parser legitimately handles whatever it can).
if python3 -c 'import yaml' 2>/dev/null; then
  make_minimal_fixture "$FIXTURE2"
  # Unclosed flow list — PyYAML throws ScannerError before reaching the
  # status_enum mapping. This is what `except Exception` used to swallow.
  cat > "$FIXTURE2/.arboretum.yml" <<'EOF'
status_enum:
  states: [draft, ready
  active_states: [ready]
  stale_state: stale
EOF
  set +e
  SUB_OUT=$(bash "$CHECK" "$FIXTURE2" 2>&1)
  set -e
  echo "$SUB_OUT" | grep -qF "status_enum config rejected" \
    || fail "[malformed-yaml] did not surface rejection message" "$SUB_OUT"
  echo "$SUB_OUT" | grep -qF "is not valid YAML" \
    || fail "[malformed-yaml] rejection didn't identify YAML parse failure" "$SUB_OUT"
  grep -qE '^status: stale[[:space:]]*$' "$FIXTURE2/docs/specs/widget.spec.md" \
    || fail "[malformed-yaml] canonical defaults not preserved" "$SUB_OUT"
  echo "PASS [malformed-yaml]: YAMLError rejected; no fall-through to permissive regex parser"
else
  echo "SKIP [malformed-yaml]: PyYAML not installed (fallback parser is the only path)"
fi

echo "PASS: all config-driven enum sub-cases — happy-path + partial-config + scalar-states + stale-omitted + invalid-token + active-not-in-states + stale-not-in-states + malformed-yaml"
