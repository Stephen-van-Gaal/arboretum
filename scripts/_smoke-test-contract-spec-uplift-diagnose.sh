#!/usr/bin/env bash
# owner: spec-uplift
# scope: plugin-only
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIAG="$ROOT/scripts/spec-uplift-diagnose.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
pass()       { printf 'PASS %s\n' "$1"; }
fail_case()  { printf 'FAIL %s: %s\n' "$1" "$2"; fail=1; }

# Fixture A — reduced/pointer spec
cat > "$TMP/reduced.spec.md" <<'SPEC'
---
version: 1
name: fixture-reduced
status: active
owner: architecture
document-shape: governed-spec
owns: []
---
# Fixture Reduced
<!-- HUMAN -->
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour
See the design spec `docs/superpowers/specs/2026-06-08-review-stage-design.md` for the full design.
## Requires
| Dependency | Source | Definition |
|------------|--------|------------|
## Provides
| Export | Type | Definition |
|--------|------|------------|
## Tests
x
## Implementation Notes
x
## Decisions
| ID | Decision | Source |
|----|----------|--------|
| D1 | a | s |
| D2 | b | s |
SPEC

# Fixture B — clean/full spec, with areas + design record + two behaviour facets
cat > "$TMP/full.spec.md" <<'SPEC'
---
version: 1
name: fixture-full
status: active
owner: architecture
document-shape: governed-spec
owns: []
areas:
  - key: alpha
---
# Fixture Full
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour
### Alpha
self-contained prose
### Beta
self-contained prose
## Requires
| Dependency | Source | Definition |
|------------|--------|------------|
## Provides
| Export | Type | Definition |
|--------|------|------------|
## Tests
x
## Implementation Notes
### Design record
| Date | Artifact | Sections changed | Summary |
|------|----------|------------------|---------|
## Decisions
| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
| D1 | a | b | c | 2026-06-15 | s |
SPEC

A="$(bash "$DIAG" "$TMP/reduced.spec.md")"
B="$(bash "$DIAG" "$TMP/full.spec.md")"

# SUD-1
[ "$(printf '%s' "$A" | jq -r '.behaviour_pointer')" = "true" ]  && pass SUD-1 || fail_case SUD-1 "pointer not detected"
[ "$(printf '%s' "$B" | jq -r '.behaviour_pointer')" = "false" ] && pass SUD-1b || fail_case SUD-1b "false positive pointer"
# SUD-2
[ "$(printf '%s' "$A" | jq -r '.decisions_schema')" = "reduced" ] && pass SUD-2a || fail_case SUD-2a "reduced misclassified"
[ "$(printf '%s' "$B" | jq -r '.decisions_schema')" = "full" ]    && pass SUD-2b || fail_case SUD-2b "full misclassified"
# SUD-3
[ "$(printf '%s' "$A" | jq -r '.decisions_rows')" = "2" ] && pass SUD-3 || fail_case SUD-3 "row count wrong"
# SUD-4
[ "$(printf '%s' "$A" | jq -r '.missing_core | length')" = "0" ] && pass SUD-4 || fail_case SUD-4 "missing_core not empty"
# SUD-5
[ "$(printf '%s' "$B" | jq -r '.behaviour_facets')" = "2" ]   && pass SUD-5a || fail_case SUD-5a "facet count wrong"
[ "$(printf '%s' "$B" | jq -r '.areas_declared')" = "true" ]  && pass SUD-5b || fail_case SUD-5b "areas not detected"
[ "$(printf '%s' "$A" | jq -r '.areas_declared')" = "false" ] && pass SUD-5c || fail_case SUD-5c "false areas"
# SUD-6
[ "$(printf '%s' "$B" | jq -r '.design_record_present')" = "true" ]  && pass SUD-6a || fail_case SUD-6a "design record missed"
[ "$(printf '%s' "$A" | jq -r '.design_record_present')" = "false" ] && pass SUD-6b || fail_case SUD-6b "false design record"
# SUD-7
[ "$(printf '%s' "$A" | jq -r '.design_specs[0]')" = "docs/superpowers/specs/2026-06-08-review-stage-design.md" ] && pass SUD-7 || fail_case SUD-7 "provenance path missed"
# SUD-8
printf '%s' "$A" | jq -e 'keys_unsorted == ["spec","behaviour_pointer","decisions_schema","decisions_rows","missing_core","behaviour_facets","areas_declared","design_record_present","design_record_is_changelog","legacy_markers_present","design_specs"]' >/dev/null \
  && pass SUD-8 || fail_case SUD-8 "key set/order wrong"

# Fixture C — path traversal in a design-spec reference (HIGH-1)
cat > "$TMP/traversal.spec.md" <<'SPEC'
---
name: fixture-traversal
---
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour
See the design spec `docs/superpowers/specs/ok-design.md` and also `docs/superpowers/specs/../../../etc/passwd.md`.
## Requires
a
## Provides
a
## Tests
x
## Implementation Notes
x
## Decisions
| ID | Decision | Source |
|----|----------|--------|
| D1 | a | s |
SPEC

# Fixture D — large Behaviour with an EARLY pointer match (SIGPIPE/pipefail regression)
{
  echo "---"; echo "name: fixture-big"; echo "---"
  echo "## Purpose"; echo x
  echo "## Boundaries (non-goals)"; echo x
  echo "## Behaviour"
  echo "See the design spec \`docs/superpowers/specs/big-design.md\`."
  for i in $(seq 1 500); do echo "filler line $i lorem ipsum dolor sit amet"; done
  echo "## Requires"; echo a
  echo "## Provides"; echo a
  echo "## Tests"; echo x
  echo "## Implementation Notes"; echo x
  echo "## Decisions"; echo "| ID | Decision | Source |"; echo "|----|----------|--------|"; echo "| D1 | a | s |"
} > "$TMP/big.spec.md"

# Fixture E — pointer false positive ("see the design team") + 5-column schema
cat > "$TMP/edge.spec.md" <<'SPEC'
---
name: fixture-edge
---
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour
For ownership questions, see the design team. This Behaviour is otherwise self-contained.
## Requires
a
## Provides
a
## Tests
x
## Implementation Notes
x
## Decisions
| ID | Decision | Alternatives | Rationale | Source |
|----|----------|--------------|-----------|--------|
| D1 | a | b | c | s |
| D2 | d | e | f | s |
| D3 | g | h | i | s |
SPEC

# Fixture F — Design record as a BULLET LIST (not the model's changelog table),
# plus a legitimate [AUTO] regen marker that must NOT be read as a legacy marker.
cat > "$TMP/bullets.spec.md" <<'SPEC'
---
name: fixture-bullets
---
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour
self-contained prose
## Requires
a
## Provides
a
## Tests
<!-- [AUTO] regenerated by /consolidate -->
x
## Implementation Notes
### Design record
- 2026-06-15: initial design
- 2026-06-16: revised
## Decisions
| ID | Decision | Source |
|----|----------|--------|
| D1 | a | s |
SPEC

# Fixture G — bullet Design record, then a pipe-table under a #### sub-note.
# The #### table must NOT be read as the changelog (boundary at any heading).
cat > "$TMP/g_h4.spec.md" <<'SPEC'
---
name: fixture-g
---
## Implementation Notes
### Design record
- 2026-01-01: a bullet, not a changelog table
#### Migration notes
| old | new |
|-----|-----|
| a | b |
## Decisions
SPEC

# Fixture H — bullet Design record + a stray separator-only row (no header).
# A lone alignment row is not a changelog table.
cat > "$TMP/h_sep.spec.md" <<'SPEC'
---
name: fixture-h
---
## Implementation Notes
### Design record
- 2026-01-01: a bullet
|---|---|
## Decisions
SPEC

# Fixture I — heading is '### Design record rationale' (a prose suffix), not the
# model's '### Design record' subsection. Must NOT register as present.
cat > "$TMP/i_suffix.spec.md" <<'SPEC'
---
name: fixture-i
---
## Implementation Notes
### Design record rationale
prose about why; not a changelog.
## Decisions
SPEC

# Fixture J — legacy markers mentioned mid-line in prose / backticks, no live
# own-line marker. Must NOT flag legacy_markers_present.
cat > "$TMP/j_prose.spec.md" <<'SPEC'
---
name: fixture-j
---
## Behaviour
On uplift, strip the legacy `<!-- HUMAN -->` and `<!-- AUTO -->` markers.
## Decisions
SPEC

# Fixture K — '## Decisions' (1 data row) followed by a '### Design record'
# table (2 data rows). decisions_rows must count only the Decisions rows.
cat > "$TMP/k_order.spec.md" <<'SPEC'
---
name: fixture-k
---
## Decisions
| ID | Decision | Source |
|----|----------|--------|
| D1 | a | s |
### Design record
| Date | Artifact | Sections changed | Summary |
|------|----------|------------------|---------|
| 2026-01-01 | x | all | y |
| 2026-01-02 | z | all | w |
SPEC

# Fixture L — a bare '<!-- APPEND-AUTO -->' authorship marker on its own line.
# APPEND-AUTO is part of the pre-#671-D11 scheme and must be flagged.
cat > "$TMP/l_append.spec.md" <<'SPEC'
---
name: fixture-l
---
## Behaviour
x
<!-- APPEND-AUTO -->
## Decisions
SPEC

# Fixture M — '## Behaviour Notes' must NOT satisfy the '## Behaviour'
# requirement, while '## Boundaries (non-goals)' (documented suffix) must.
cat > "$TMP/m_headings.spec.md" <<'SPEC'
---
name: fixture-m
---
## Purpose
x
## Boundaries (non-goals)
x
## Behaviour Notes
x
## Requires
## Provides
## Tests
## Implementation Notes
## Decisions
SPEC

C="$(bash "$DIAG" "$TMP/traversal.spec.md")"
D="$(bash "$DIAG" "$TMP/big.spec.md")"
E="$(bash "$DIAG" "$TMP/edge.spec.md")"
F="$(bash "$DIAG" "$TMP/bullets.spec.md")"
G="$(bash "$DIAG" "$TMP/g_h4.spec.md")"
H="$(bash "$DIAG" "$TMP/h_sep.spec.md")"
I="$(bash "$DIAG" "$TMP/i_suffix.spec.md")"
J="$(bash "$DIAG" "$TMP/j_prose.spec.md")"
K="$(bash "$DIAG" "$TMP/k_order.spec.md")"
# Fixture N — '## Decisions' with prose but NO table, then a '### Design record'
# table. The schema detector must stop at the '### ' and report 'absent', not
# misread the design-record header as the Decisions header.
cat > "$TMP/n_decscope.spec.md" <<'SPEC'
---
name: fixture-n
---
## Decisions
Some prose; no decisions table here yet.
### Design record
| Date | Artifact | Sections changed | Summary |
|------|----------|------------------|---------|
| 2026-01-01 | x | all | y |
SPEC

L="$(bash "$DIAG" "$TMP/l_append.spec.md")"
M="$(bash "$DIAG" "$TMP/m_headings.spec.md")"
N="$(bash "$DIAG" "$TMP/n_decscope.spec.md")"

# SUD-9 — path traversal excluded; legit path kept
[ "$(printf '%s' "$C" | jq -r '.design_specs | index("docs/superpowers/specs/ok-design.md") != null')" = "true" ] && pass SUD-9a || fail_case SUD-9a "legit design spec dropped"
[ "$(printf '%s' "$C" | jq -r '[.design_specs[] | select(test("\\.\\."))] | length')" = "0" ] && pass SUD-9b || fail_case SUD-9b "traversal path not filtered"
# SUD-10 — early pointer in a large Behaviour still detected (no SIGPIPE false-negative)
[ "$(printf '%s' "$D" | jq -r '.behaviour_pointer')" = "true" ] && pass SUD-10 || fail_case SUD-10 "early pointer in large behaviour missed"
# SUD-11 — "see the design team" is NOT a pointer
[ "$(printf '%s' "$E" | jq -r '.behaviour_pointer')" = "false" ] && pass SUD-11 || fail_case SUD-11 "false-positive pointer on 'design team'"
# SUD-12 — 5-column Decisions header is reduced (full requires >=6)
[ "$(printf '%s' "$E" | jq -r '.decisions_schema')" = "reduced" ] && pass SUD-12 || fail_case SUD-12 "5-col schema not reduced"
# SUD-13 — row count excludes header + separator (3 data rows in fixture E)
[ "$(printf '%s' "$E" | jq -r '.decisions_rows')" = "3" ] && pass SUD-13 || fail_case SUD-13 "row count wrong with alignment table"
# SUD-14 — legacy authorship markers (bare <!-- HUMAN -->/<!-- AUTO -->) detected; [AUTO] regen markers ignored
[ "$(printf '%s' "$A" | jq -r '.legacy_markers_present')" = "true" ]  && pass SUD-14a || fail_case SUD-14a "bare legacy marker not detected"
[ "$(printf '%s' "$B" | jq -r '.legacy_markers_present')" = "false" ] && pass SUD-14b || fail_case SUD-14b "false-positive legacy marker on clean spec"
[ "$(printf '%s' "$F" | jq -r '.legacy_markers_present')" = "false" ] && pass SUD-14c || fail_case SUD-14c "[AUTO] regen marker misread as legacy authorship marker"
# SUD-15 — Design record changelog (table) distinguished from a bullet list
[ "$(printf '%s' "$B" | jq -r '.design_record_is_changelog')" = "true" ]  && pass SUD-15a || fail_case SUD-15a "changelog table not recognized"
[ "$(printf '%s' "$F" | jq -r '.design_record_is_changelog')" = "false" ] && pass SUD-15b || fail_case SUD-15b "bullet-list design record misread as changelog"
[ "$(printf '%s' "$A" | jq -r '.design_record_is_changelog')" = "false" ] && pass SUD-15c || fail_case SUD-15c "absent design record reported as changelog"
# SUD-16 — a table under a #### sub-note of a bullet Design record is NOT the changelog
[ "$(printf '%s' "$G" | jq -r '.design_record_is_changelog')" = "false" ] && pass SUD-16 || fail_case SUD-16 "#### sub-note table leaked as changelog"
# SUD-17 — a lone separator/alignment row is not a changelog table
[ "$(printf '%s' "$H" | jq -r '.design_record_is_changelog')" = "false" ] && pass SUD-17 || fail_case SUD-17 "separator-only row counted as changelog"
# SUD-18 — '### Design record rationale' (prose suffix) is not the Design record subsection
[ "$(printf '%s' "$I" | jq -r '.design_record_present')" = "false" ]       && pass SUD-18a || fail_case SUD-18a "suffix heading false-registered design record"
[ "$(printf '%s' "$I" | jq -r '.design_record_is_changelog')" = "false" ]  && pass SUD-18b || fail_case SUD-18b "suffix heading false changelog"
# SUD-19 — legacy markers mentioned in prose/backticks (not own-line) are NOT flagged
[ "$(printf '%s' "$J" | jq -r '.legacy_markers_present')" = "false" ]      && pass SUD-19 || fail_case SUD-19 "prose-mention legacy marker false positive"
# SUD-20 — decisions_rows counts only the Decisions table, not a trailing ### Design record table
[ "$(printf '%s' "$K" | jq -r '.decisions_rows')" = "1" ]                  && pass SUD-20 || fail_case SUD-20 "decisions_rows inflated by trailing design-record table"
# SUD-21 — a bare own-line <!-- APPEND-AUTO --> marker is flagged (pre-#671-D11 scheme)
[ "$(printf '%s' "$L" | jq -r '.legacy_markers_present')" = "true" ]       && pass SUD-21 || fail_case SUD-21 "bare APPEND-AUTO marker not flagged"
# SUD-22 — '## Behaviour Notes' does not satisfy '## Behaviour'; '## Boundaries (non-goals)' does
[ "$(printf '%s' "$M" | jq -r '.missing_core | index("Behaviour") != null')" = "true" ]  && pass SUD-22a || fail_case SUD-22a "prefix heading satisfied a mandatory section"
[ "$(printf '%s' "$M" | jq -r '.missing_core | index("Boundaries") == null')" = "true" ] && pass SUD-22b || fail_case SUD-22b "Boundaries (non-goals) wrongly reported missing"
# SUD-23 — schema detector stops at '### '; a trailing design-record table is not the Decisions header
[ "$(printf '%s' "$N" | jq -r '.decisions_schema')" = "absent" ] && pass SUD-23 || fail_case SUD-23 "design-record table misread as Decisions header"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
