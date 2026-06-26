#!/usr/bin/env bash
# owner: roadmap
# scope: plugin-only
# Deterministic cache operations for /roadmap score (read-only w.r.t. the tracker).
#   --validate-record           validate one v3 record (stdin) -> exit 0/3
#   --diff --cache <f>          (Task 2) emit {stale:[...],evict:[...]} from issues (stdin)
#   --merge --cache <f>         (Task 3) merge scored records (stdin) into cache -> stdout
#   --agent-ready-list --cache <f>   (Task 3) print agent_ready_candidate numbers
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

mode=""; cache=""; evict="[]"
while [ $# -gt 0 ]; do
  case "$1" in
    --validate-record) mode="validate"; shift ;;
    --diff) mode="diff"; shift ;;
    --merge) mode="merge"; shift ;;
    --agent-ready-list) mode="arlist"; shift ;;
    --cache) cache="$2"; shift 2 ;;
    --evict) evict="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

validate_record() {
  local rec; rec="$(cat)"
  printf '%s' "$rec" | jq -e '
    def enum($f; $allowed): ($f as $v | $allowed | index($v)) != null;
    (type=="object")
    and enum(.value; ["high","medium","low"])
    and (.value_description|type=="string")
    and enum(.posture; ["live","preventive","mixed"])
    and enum(.hazard; ["blocks-legit","permits-bad","none","na"])
    and enum(.complexity; ["bugfix","design","brainstorm"])
    and enum(.blocker; ["none","one-decision","spec"])
    and (.depends_on|type=="array")
    and (.depends_on|all(.[]; (type=="number") and (. == floor)))
    and enum(.disposition; ["keep","combine","delete","decompose"])
    and enum(.class; ["work-unit","orchestrator"])
    and (.body_sha|test("^[0-9a-f]{12}$"))
    and (.scored|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and (if .disposition=="combine" then (.anchor|type=="number") and (.anchor == (.anchor|floor)) and (.priority_driver|type=="number") and (.priority_driver == (.priority_driver|floor)) else true end)
  ' >/dev/null 2>&1 || { echo "score: invalid record — schema check failed" >&2; exit 3; }
}

emit_diff() {
  local issues; issues="$(cat)"
  # Guard: an empty or non-array payload would produce shamap={}, which makes every
  # cached key appear "not open" and evicts the whole cache. Fail fast instead.
  if [ -z "$issues" ]; then
    echo "score-cache --diff: issues stdin is empty — pass a JSON array of open issues" >&2
    return 1
  fi
  if ! printf '%s' "$issues" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "score-cache --diff: issues stdin is not a JSON array (malformed or non-array JSON)" >&2
    return 1
  fi
  [ -n "$cache" ] && [ -r "$cache" ] || cache=""
  local cache_json="{}"; [ -n "$cache" ] && cache_json="$(cat "$cache")"
  # Guard: a 0-byte file produces an empty string; fall back to empty object so jq doesn't crash.
  [ -n "$cache_json" ] || cache_json="{}"
  # Build number->current_sha map in bash (canonical body hashing; jq cannot hash).
  local shamap="{}" n body sha
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    body="$(printf '%s' "$issues" | jq -r --argjson n "$n" '.[]|select(.number==$n)|.body // ""')"
    sha="$(printf '%s' "$body" | shasum -a 256 | cut -c1-12)"
    shamap="$(printf '%s' "$shamap" | jq --argjson n "$n" --arg s "$sha" '. + {($n|tostring):$s}')"
  done < <(printf '%s' "$issues" | jq -r '.[].number')
  # Use --slurpfile instead of --argjson to avoid ARG_MAX limits on large caches.
  local tmp_cache tmp_shamap
  tmp_cache="$(mktemp)"
  tmp_shamap="$(mktemp)"
  printf '%s' "$cache_json" > "$tmp_cache"
  printf '%s' "$shamap" > "$tmp_shamap"
  local rc
  jq -n --slurpfile cache "$tmp_cache" --slurpfile shamap "$tmp_shamap" '
    ($shamap[0]|keys|map(tonumber)) as $open
    | { stale: [ $open[] | select( ($cache[0][(.|tostring)]|.body_sha // "") != $shamap[0][(.|tostring)] ) ],
        evict: [ $cache[0]|keys[]|tonumber | select( ($shamap[0][(.|tostring)]) == null ) ] }'
  rc=$?
  rm -f "$tmp_cache" "$tmp_shamap"
  return $rc
}

emit_merge() {
  local upd; upd="$(cat)"
  # Guard: malformed or empty-string stdin causes jq 'length' to fail silently and
  # the loop to produce no updates — but the script would exit 0, allowing the caller's
  # "> tmp && mv" to overwrite the cache with stale or partial data. Fail fast instead.
  # (An empty JSON array [] is valid — means no new scores, apply evictions only.)
  if [ -z "$upd" ]; then
    echo "score-cache --merge: update stdin is empty — pass a JSON array (may be [])" >&2
    return 1
  fi
  if ! printf '%s' "$upd" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "score-cache --merge: update stdin is not a JSON array (malformed or non-array JSON)" >&2
    return 1
  fi
  local cache_json="{}"; [ -n "$cache" ] && [ -f "$cache" ] && cache_json="$(cat "$cache")"
  # Guard: a 0-byte file produces an empty string; fall back to empty object so jq doesn't crash.
  [ -n "$cache_json" ] || cache_json="{}"
  local scrubbed="[]" i num rec desc
  local count; count="$(printf '%s' "$upd" | jq 'length')"
  for ((i=0;i<count;i++)); do
    num="$(printf '%s' "$upd" | jq -r ".[$i].number")"
    desc="$(printf '%s' "$upd" | jq -r ".[$i].record.value_description // \"\"" | scrub_control_chars_oneline)"
    rec="$(printf '%s' "$upd" | jq --arg d "$desc" ".[$i].record + {value_description:\$d}")"
    scrubbed="$(printf '%s' "$scrubbed" | jq --argjson n "$num" --argjson r "$rec" '. + [{number:$n,record:$r}]')"
  done
  # Use --slurpfile instead of --argjson to avoid ARG_MAX limits on large caches/update arrays.
  # $evict is a small array of integers — keep on argv.
  local tmp_cache tmp_upd
  tmp_cache="$(mktemp)"
  tmp_upd="$(mktemp)"
  printf '%s' "$cache_json" > "$tmp_cache"
  printf '%s' "$scrubbed" > "$tmp_upd"
  local rc
  jq -n --slurpfile cache "$tmp_cache" --slurpfile upd "$tmp_upd" --argjson evict "$evict" '
    reduce $upd[0][] as $u ($cache[0]; . + {($u.number|tostring): $u.record})
    | delpaths([ $evict[] | [ (.|tostring) ] ])'
  rc=$?
  rm -f "$tmp_cache" "$tmp_upd"
  return $rc
}

emit_arlist() {
  local cache_json="{}"; [ -n "$cache" ] && [ -f "$cache" ] && cache_json="$(cat "$cache")"
  # Guard: a 0-byte file produces an empty string; fall back to empty object so jq doesn't crash.
  [ -n "$cache_json" ] || cache_json="{}"
  printf '%s' "$cache_json" | jq -r '
    to_entries
    | map(select(.value.complexity=="bugfix" and .value.blocker=="none"
                 and .value.disposition=="keep" and .value.class=="work-unit"))
    | sort_by(({"high":0,"medium":1,"low":2}[.value.value] // 3))
    | .[].key'
}

case "$mode" in
  validate) validate_record ;;
  diff)     emit_diff ;;
  merge)    emit_merge ;;
  arlist)   emit_arlist ;;
  *) echo "score-cache: mode not yet implemented: $mode" >&2; exit 2 ;;
esac
