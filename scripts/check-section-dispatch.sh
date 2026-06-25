#!/usr/bin/env bash
# owner: section-dispatch
# scope: plugin-only
# check-section-dispatch.sh — conformance checker for the section-dispatch pattern.
#   check-section-dispatch.sh <registry-file>
# Exit 0 = conformant; 1 = violation (first offender to stderr); 2 = usage/IO error.
# Verifies DECLARED structure, not semantic correctness (the floor; instantiation
# integration tests are the ceiling). See docs/specs/section-dispatch.spec.md (D6).
set -uo pipefail
f="${1:-}"
[ -n "$f" ] || { echo "usage: check-section-dispatch.sh <registry-file>" >&2; exit 2; }
[ -f "$f" ] || { echo "check-section-dispatch: file not found: $f" >&2; exit 2; }
fail() { echo "NONCONFORMANT: $1" >&2; exit 1; }

# top_value <key> — echo a top-level scalar with trailing comment + surrounding
# whitespace stripped, so a comment-only value (key: # TODO) reads as empty.
top_value() {
  grep -E "^$1:" "$f" | head -1 | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]*#.*\$//; s/[[:space:]]*\$//"
}

# Top-level required declarations (a comment-only value counts as absent).
[ -n "$(top_value manifest_contract)" ] \
  || fail "missing normalized-result contract reference (manifest_contract:)"
[ -n "$(top_value degradation)" ] \
  || fail "missing degradation policy (degradation:)"

# Emit one "id<TAB>type<TAB>scrub<TAB>invoke" record per worker under workers:.
# v1 parses the canonical YAML-lite shape: a block list of `- id:`-led mappings
# (id-first). Non-id-first key order and inline-flow rows are not parsed in v1
# (see the contract's Surface note); that robustness is a tracked follow-up.
records="$(awk '
  # norm: resolve a YAML-lite scalar. A double-quoted value is taken literally up
  # to its closing quote (a "#" inside quotes is content, not a comment); an
  # unquoted value has any trailing "# comment" and surrounding whitespace stripped.
  function norm(v) {
    sub(/^[[:space:]]+/, "", v)
    if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v); return v }
    sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v); return v
  }
  /^workers:[[:space:]]*$/ { inw=1; next }
  inw && /^[^[:space:]#]/ { inw=0 }
  inw && /^[[:space:]]*-[[:space:]]*id:/ {
    if (id != "") print id "\037" type "\037" scrub "\037" invoke
    id=$0; sub(/.*id:[[:space:]]*/,"",id); id=norm(id); type=""; scrub=""; invoke=""; next
  }
  inw && /^[[:space:]]*type:/   { t=$0;  sub(/.*type:[[:space:]]*/,"",t);   type=norm(t) }
  inw && /^[[:space:]]*scrub:/  { s=$0;  sub(/.*scrub:[[:space:]]*/,"",s);  scrub=norm(s) }
  inw && /^[[:space:]]*invoke:/ { iv=$0; sub(/.*invoke:[[:space:]]*/,"",iv); invoke=norm(iv) }
  END { if (id != "") print id "\037" type "\037" scrub "\037" invoke }
' "$f")"

[ -n "$records" ] || fail "no workers declared (workers: block empty or absent)"

while IFS=$'\037' read -r id type scrub invoke; do
  case "$type" in
    skill|runtime) ;;
    *) fail "worker $id: adapter type missing or not in {skill,runtime} (got '$type')" ;;
  esac
  [ -n "$invoke" ] || fail "worker $id: missing invoke (every worker row must declare a backend to run)"
  if [ "$type" = "runtime" ] && [ "$scrub" != "true" ]; then
    fail "worker $id: runtime adapter must declare scrub: true"
  fi
done <<< "$records"

exit 0
