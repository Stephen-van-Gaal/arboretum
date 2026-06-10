#!/usr/bin/env bash
# owner: pipeline-contracts-template
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/read-decisions.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

# 8-column fixture: active (blank), moot, superseded link
EIGHT="$FIX/eight.md"
cat > "$EIGHT" <<'EOF'
# Fixture

## Decisions

| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|------------------------|-----------|------|--------|
| D1 | Use a single table | | seam | two tables | one source of truth | 2026-06-09 | design |
| D2 | Delete render-run.sh | moot | scope | keep a shim | cleanup | 2026-06-09 | design |
| D3 | Replace D1 approach | superseded→D4 | seam | n/a | early take | 2026-06-09 | design |
| D4 | Final approach | | seam | n/a | settled | 2026-06-09 | design |
EOF

# 6-column #671 fixture (no Status/Tags)
SIX="$FIX/six.md"
cat > "$SIX" <<'EOF'
# Fixture

## Decisions

| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
| D1 | Core decision | alt | because | 2026-06-09 | design |
EOF

# No-decisions fixture
NONE="$FIX/none.md"
printf '# Fixture\n\n## Purpose\n\nBody.\n' > "$NONE"

# RD-1 summary: blank Status -> active
out="$("$PROBE" "$EIGHT" --summary 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "D1 · Use a single table · active · seam" <<<"$out" \
   && grep -q "D2 · Delete render-run.sh · moot · scope" <<<"$out"; then
  pass "RD-1 summary projection"; else fail_case "RD-1 summary projection" "$out"; fi

# RD-2 detail by ID, requested order D3 then D1
out="$("$PROBE" "$EIGHT" --detail D3,D1 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^| D' <<<"$out")" -eq 2 ] \
   && [ "$(grep -n '^| D3' <<<"$out" | cut -d: -f1)" -lt "$(grep -n '^| D1' <<<"$out" | cut -d: -f1)" ]; then
  pass "RD-2 detail by ID in order"; else fail_case "RD-2 detail by ID in order" "$out"; fi

# RD-3 unknown ID -> exit 1, names it, no stdout
out="$("$PROBE" "$EIGHT" --detail D999 2>"$FIX/err")"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q "D999" "$FIX/err"; then
  pass "RD-3 unknown ID fails closed"; else fail_case "RD-3 unknown ID fails closed" "rc=$rc out=$out"; fi

# RD-4 missing section -> exit 1, no stdout
out="$("$PROBE" "$NONE" --summary 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
  pass "RD-4 missing section fails closed"; else fail_case "RD-4 missing section fails closed" "rc=$rc out=$out"; fi

# RD-5 six-column tolerance -> Status active, Tags blank
out="$("$PROBE" "$SIX" --summary 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qE "D1 · Core decision · active · *$" <<<"$out"; then
  pass "RD-5 six-column tolerance"; else fail_case "RD-5 six-column tolerance" "$out"; fi

# RD-6 invocation errors -> exit 2
"$PROBE" "$EIGHT" --summary --detail D1 >/dev/null 2>&1; r1=$?
"$PROBE" "$EIGHT" --detail >/dev/null 2>&1; r2=$?
"$PROBE" "$EIGHT" --bogus >/dev/null 2>&1; r3=$?
if [ "$r1" -eq 2 ] && [ "$r2" -eq 2 ] && [ "$r3" -eq 2 ]; then
  pass "RD-6 invocation errors"; else fail_case "RD-6 invocation errors" "r1=$r1 r2=$r2 r3=$r3"; fi

# RD-7 duplicate table ID -> detail fails closed (no silent last-wins)
DUP="$FIX/dup.md"
cat > "$DUP" <<'EOF'
# Fixture

## Decisions

| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|------------------------|-----------|------|--------|
| D1 | first | | seam | a | b | 2026-06-09 | design |
| D1 | second | | seam | a | b | 2026-06-09 | design |
EOF
out="$("$PROBE" "$DUP" --detail D1 2>"$FIX/err")"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ] && grep -qi "duplicate decision id" "$FIX/err"; then
  pass "RD-7 duplicate table ID fails closed"; else fail_case "RD-7 duplicate table ID fails closed" "rc=$rc out=$out"; fi

# RD-8 escaped pipe in a cell -> not split as a column (Status/Tags stay aligned)
ESC="$FIX/esc.md"
cat > "$ESC" <<'EOF'
# Fixture

## Decisions

| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
|----|----------|--------|------|------------------------|-----------|------|--------|
| D1 | run `a \| b \|\| c` pipe | moot | seam | alt | why | 2026-06-09 | design |
EOF
out="$("$PROBE" "$ESC" --summary 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "D1 · run \`a \\\\| b \\\\|\\\\| c\` pipe · moot · seam" <<<"$out"; then
  pass "RD-8 escaped pipe not split"; else fail_case "RD-8 escaped pipe not split" "$out"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS: read-decisions contract" || exit 1
