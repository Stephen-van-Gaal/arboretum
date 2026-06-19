#!/usr/bin/env bash
# owner: spec-uplift
set -euo pipefail

spec="${1:?usage: spec-uplift-diagnose.sh <spec-path>}"
[ -f "$spec" ] || { echo "spec-uplift-diagnose: not found: $spec" >&2; exit 2; }

# --- Behaviour section (between '## Behaviour' and the next '## ') ---
behaviour="$(awk '/^## Behaviour[[:space:]]*$/{f=1;next} /^## /{f=0} f' "$spec")"
# Pointer-shaped reference (here-string avoids a producer pipeline + SIGPIPE under
# pipefail). Requires "design spec|doc" phrasing so prose like "see the design
# team" is not a false positive.
behaviour_pointer=false
grep -qiE 'see (the )?design[ -](spec|doc)' <<<"$behaviour" && behaviour_pointer=true
behaviour_facets="$(grep -cE '^### ' <<<"$behaviour" || true)"

# --- Decisions table ---
dec_header="$(awk '/^## Decisions[[:space:]]*$/{f=1;next} /^## /{f=0} /^### /{f=0} f && /^\|/{print; exit}' "$spec")"
if [ -z "$dec_header" ]; then
  decisions_schema=absent
else
  cols="$(printf '%s' "$dec_header" | awk -F'|' '{print NF-2}')"  # strip leading/trailing empties
  # full = the >=6-column model schema (ID·Decision·Alternatives·Rationale·Date·Source);
  # anything below that is reduced/transitional and needs uplift (contract semantics).
  if [ "$cols" -ge 6 ]; then decisions_schema=full; else decisions_schema=reduced; fi
fi
# data rows = pipe-lines in the Decisions section that are neither the header
# nor a separator row (only dashes/colons/pipes/spaces), minus the header.
dec_data="$(awk '
  /^## Decisions[[:space:]]*$/{f=1;next}
  /^## /{f=0}
  /^### /{f=0}
  f && /^\|/ {
    if ($0 ~ /^\|[-:| ]+\|?[[:space:]]*$/) next   # skip separator/alignment rows
    c++
  }
  END{print c+0}' "$spec")"
decisions_rows=0
[ "$dec_data" -ge 1 ] && decisions_rows=$((dec_data - 1))

# --- mandatory headings ---
# Match each heading EXACTLY on its own line so '## Behaviour Notes' does not
# satisfy the '## Behaviour' requirement (a prefix match reported a false-clean
# missing_core:[]). 'Boundaries' carries the documented '(non-goals)' suffix in
# the model, so it alone tolerates that parenthetical.
missing_core="[]"
mc=()
for h in "Purpose" "Boundaries" "Behaviour" "Requires" "Provides" "Tests" "Implementation Notes" "Decisions"; do
  case "$h" in
    "Boundaries") pat="^## Boundaries([[:space:]]+\(non-goals\))?[[:space:]]*$" ;;
    *)            pat="^## ${h}[[:space:]]*$" ;;
  esac
  grep -qE "$pat" "$spec" || mc+=("$h")
done
if [ "${#mc[@]}" -gt 0 ]; then
  missing_core="$(printf '%s\n' "${mc[@]}" | jq -R . | jq -s -c .)"
fi

# --- frontmatter areas: ---
areas_declared=false
awk 'NR>1 && /^---[[:space:]]*$/{exit} /^areas:/{print; exit}' "$spec" | grep -q 'areas:' && areas_declared=true

# --- design record ---
# Anchor the heading to its own line so a prose suffix ('### Design record
# rationale') is not mistaken for the model's '### Design record' subsection.
design_record_present=false
grep -qE '^### Design record[[:space:]]*$' "$spec" && design_record_present=true

# Is the Design record the model's dated changelog TABLE, or a legacy bullet list?
# Scan the '### Design record' subsection — bounded at the NEXT heading of any
# depth (so a table under a #### sub-note does not leak in) — for a pipe-table
# line, skipping a lone separator/alignment row (which is not a real table).
# A bullet-list design record is present-but-not-conformant — the gap
# validation #1 surfaced that design_record_present alone cannot see.
design_record_is_changelog=false
dr_table="$(awk '
  /^### Design record[[:space:]]*$/{f=1;next}
  /^#+ /{f=0}
  f && /^\|/ {
    if ($0 ~ /^\|[-:| ]+\|?[[:space:]]*$/) next   # skip separator/alignment rows
    print; exit
  }' "$spec")"
[ -n "$dr_table" ] && design_record_is_changelog=true

# --- legacy authorship markers ---
# Bare '<!-- HUMAN -->' / '<!-- AUTO -->' markers are the pre-#671-D11 authorship
# scheme (#671 D11 made authorship schema-driven, so they must be stripped on
# uplift). The legitimate regen directives '<!-- [AUTO] regenerated ... -->' carry
# brackets + trailing text, so this exact-content match does not flag them.
# Anchor to a marker ALONE on its line (modulo surrounding whitespace) so a
# prose/backtick mention ("strip the `<!-- HUMAN -->` markers") is not a false
# positive — a live authorship marker always occupies its own line. All three
# bare authorship words (HUMAN / AUTO / APPEND-AUTO) are the pre-#671-D11 scheme;
# the bracketed regen directives '<!-- [AUTO] … -->'/'<!-- [APPEND-AUTO] … -->'
# are not matched (the leading '[' fails the alternation).
legacy_markers_present=false
grep -qE '^[[:space:]]*<!--[[:space:]]*(HUMAN|AUTO|APPEND-AUTO)[[:space:]]*-->[[:space:]]*$' "$spec" && legacy_markers_present=true

# --- provenance design specs (grep may match nothing; tolerate under pipefail) ---
# Reject path traversal: a reference like docs/superpowers/specs/../../etc/x.md
# carries the safe prefix but escapes the tree, so drop any path containing '..'
# (the report is consumed to *read* these paths — see the contract trust note).
design_specs="$({ grep -oE 'docs/superpowers/specs/[A-Za-z0-9._/-]+\.md' "$spec" || true; } | { grep -vF '..' || true; } | sort -u | jq -R . | jq -s -c 'map(select(length > 0))')"

jq -n -c \
  --arg spec "$spec" \
  --argjson behaviour_pointer "$behaviour_pointer" \
  --arg decisions_schema "$decisions_schema" \
  --argjson decisions_rows "$decisions_rows" \
  --argjson missing_core "$missing_core" \
  --argjson behaviour_facets "$behaviour_facets" \
  --argjson areas_declared "$areas_declared" \
  --argjson design_record_present "$design_record_present" \
  --argjson design_record_is_changelog "$design_record_is_changelog" \
  --argjson legacy_markers_present "$legacy_markers_present" \
  --argjson design_specs "$design_specs" \
  '{spec:$spec, behaviour_pointer:$behaviour_pointer, decisions_schema:$decisions_schema, decisions_rows:$decisions_rows, missing_core:$missing_core, behaviour_facets:$behaviour_facets, areas_declared:$areas_declared, design_record_present:$design_record_present, design_record_is_changelog:$design_record_is_changelog, legacy_markers_present:$legacy_markers_present, design_specs:$design_specs}'
