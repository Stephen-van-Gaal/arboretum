#!/usr/bin/env bash
# owner: review-stage
# review-registry-filter.sh — the dispatcher's deterministic selection step (#791 D3):
# registry.filter(altitude, artifact) + gate evaluation (section-dispatch element 2).
#
#   review-registry-filter.sh <registry-file> --altitude <a> --artifact <art> \
#                             [--base <ref>] [--files-from <file|->]
#
# Reads reviewers.yml, keeps each worker whose altitudes[] contains <a> AND artifact[]
# contains <art>, then for any worker carrying a `gate:` field defers to
# review-dispatch.sh's lane set (the gate AUTHORITY — DRY, never a second copy of the
# AI-facing/code gates) computed over the changed files. Emits one JSONL record per
# surviving worker, in registry (= dispatch) order: {id, type, invoke, gate, normalizer}.
# With --base, the runtime row's {base} placeholder is substituted so invoke is runnable.
#
# Adding/swapping a reviewer = one registry row; this dispatcher does not change. (A row
# with a NEW gate kind is the sole exception — gates resolve to lanes here, and an
# unknown gate fails loud rather than silently passing.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REG=""; ALT=""; ART=""; BASE=""; FILES_SRC=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --altitude) ALT="${2:-}"; shift 2 ;;
    --artifact) ART="${2:-}"; shift 2 ;;
    --base)     BASE="${2:-}"; shift 2 ;;
    --files-from) FILES_SRC="${2:-}"; shift 2 ;;
    -*) echo "review-registry-filter: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$REG" ] && REG="$1"; shift ;;
  esac
done
[ -n "$REG" ] || { echo "usage: review-registry-filter.sh <registry-file> --altitude <a> --artifact <art> [--base <ref>] [--files-from <f|->]" >&2; exit 2; }
[ -f "$REG" ] || { echo "review-registry-filter: registry not found: $REG" >&2; exit 2; }
[ -n "$ALT" ] || { echo "review-registry-filter: --altitude is required" >&2; exit 2; }
[ -n "$ART" ] || { echo "review-registry-filter: --artifact is required" >&2; exit 2; }

# Capture the changed-file list once (gate evaluation reads it; empty is fine).
FILES=""
if [ -n "$FILES_SRC" ]; then
  if [ "$FILES_SRC" = "-" ]; then FILES="$(cat)"; else
    [ -f "$FILES_SRC" ] || { echo "review-registry-filter: files list not found: $FILES_SRC" >&2; exit 2; }
    FILES="$(cat "$FILES_SRC")"
  fi
fi

# Gate authority: the lane set review-dispatch.sh produces for these files. Computed lazily
# (only when a gated candidate row is actually encountered).
LANESET=""; LANESET_DONE=0
gate_authority() {
  [ "$LANESET_DONE" = 1 ] && return 0
  LANESET="$(printf '%s\n' "$FILES" | bash "$SCRIPT_DIR/review-dispatch.sh" --files-from -)"
  LANESET_DONE=1
}
gate_satisfied() { # $1 = gate value; 0 if the gate passes for the change set
  gate_authority
  local lane
  case "$1" in
    ai-surface) lane="ai-surface" ;;
    code)       lane="correctness" ;;
    *) echo "review-registry-filter: unknown gate '$1' (extend the gate→lane map)" >&2; exit 2 ;;
  esac
  printf '%s\n' "$LANESET" | grep -qx "$lane"
}

# Parse the canonical reviewers.yml block list into TAB-separated worker records.
# Fields: id, type, invoke, gate, normalizer, altitudes(csv), artifact(csv).
records="$(awk '
  function norm(v) {
    sub(/^[[:space:]]+/, "", v)
    if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v); return v }
    sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]+$/, "", v); return v
  }
  function list(v) {  # "[a, b]  # note" -> "a,b" (content between the first [ and ]; trailing comment dropped)
    sub(/^[^[]*\[/, "", v); sub(/\].*$/, "", v); gsub(/[[:space:]]/, "", v); return v
  }
  function emit() { if (id != "") print id "\037" type "\037" invoke "\037" gate "\037" normalizer "\037" alts "\037" arts }
  /^workers:[[:space:]]*$/ { inw=1; next }
  inw && /^[^[:space:]#]/ { inw=0 }
  inw && /^[[:space:]]*-[[:space:]]*id:/ {
    emit(); v=$0; sub(/.*id:[[:space:]]*/,"",v); id=norm(v); type=""; invoke=""; gate=""; normalizer=""; alts=""; arts=""; next
  }
  inw && /^[[:space:]]*type:/       { v=$0; sub(/.*type:[[:space:]]*/,"",v);       type=norm(v) }
  inw && /^[[:space:]]*invoke:/     { v=$0; sub(/.*invoke:[[:space:]]*/,"",v);     invoke=norm(v) }
  inw && /^[[:space:]]*gate:/       { v=$0; sub(/.*gate:[[:space:]]*/,"",v);       gate=norm(v) }
  inw && /^[[:space:]]*normalizer:/ { v=$0; sub(/.*normalizer:[[:space:]]*/,"",v); normalizer=norm(v) }
  inw && /^[[:space:]]*altitudes:/  { v=$0; sub(/.*altitudes:[[:space:]]*/,"",v);  alts=list(v) }
  inw && /^[[:space:]]*artifact:/   { v=$0; sub(/.*artifact:[[:space:]]*/,"",v);   arts=list(v) }
  END { emit() }
' "$REG")"

[ -n "$records" ] || { echo "review-registry-filter: no workers in $REG" >&2; exit 2; }

while IFS=$'\037' read -r id type invoke gate normalizer alts arts; do
  [ -n "$id" ] || continue
  # altitude + artifact membership (csv contains-test).
  case ",$alts," in *",$ALT,"*) ;; *) continue ;; esac
  case ",$arts," in *",$ART,"*) ;; *) continue ;; esac
  # gate (if any) must pass for this change set.
  if [ -n "$gate" ] && ! gate_satisfied "$gate"; then continue; fi
  # fail loud on a selected-but-malformed row, rather than emitting a record the fan-out
  # would choke on later (no-silent-drop; mirrors check-section-dispatch.sh's row checks).
  case "$type" in
    skill|runtime) ;;
    *) echo "review-registry-filter: worker '$id' has missing/invalid type (got '$type'; need skill|runtime)" >&2; exit 2 ;;
  esac
  [ -n "$invoke" ] || { echo "review-registry-filter: worker '$id' is missing invoke" >&2; exit 2; }
  # substitute {base} in invoke when a base was supplied. Shell-quote the value: /finish
  # runs the emitted invoke via Bash, and a base carrying shell metacharacters (git permits
  # branch names like `main$(...)`) would otherwise execute a command substitution. %q emits
  # safe values verbatim and escapes dangerous ones.
  if [ -n "$BASE" ]; then
    printf -v base_q '%q' "$BASE"
    invoke="${invoke//\{base\}/$base_q}"
  fi
  jq -nc \
    --arg id "$id" --arg type "$type" --arg invoke "$invoke" \
    --arg gate "$gate" --arg normalizer "$normalizer" \
    '{id:$id, type:$type, invoke:$invoke, gate:(if $gate=="" then null else $gate end), normalizer:(if $normalizer=="" then null else $normalizer end)}'
done <<< "$records"
