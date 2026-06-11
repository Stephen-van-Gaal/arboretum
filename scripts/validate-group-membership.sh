#!/usr/bin/env bash
# owner: document-taxonomy
# validate-group-membership.sh — group-spec layer integrity (#681).
#
# Enforces, over docs/groups/*.md and the specs/groups they reference:
#   1. forward contains : group.contains[X] ⇒ X exists AND X.parent == group
#   2. reverse parent   : doc.parent == G   ⇒ docs/groups/G.md exists AND lists doc
#   3. forward glue (D7): group.owns[F]     ⇒ F exists AND F's declared owner == <group>
#   4. reverse glue (D7): file owned by a group ⇒ that group's owns: lists the file
#
# Glue (D7) may be a `.sh` (line-2 `# owner:`) OR a `skills/*/SKILL.md` umbrella
# dispatcher (YAML frontmatter `owner:`) — both glue shapes are validated.
#
# Frontmatter is parsed by the shared scripts/lib/yaml-lite.sh (flow AND block
# lists); a doc whose frontmatter does not parse is a violation, not a mid-run
# `set -e` abort. Read-only; vacuous (exit 0) when no docs/groups/ exists.
#
# Hardening (B4 review): parsed tokens are never trusted into globs, grep regexes,
# or paths — iterate with `while read`, exact string-equality membership, charset-gate
# names, reject `..`/leading-`/` in owns paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/yaml-lite.sh
source "$HERE/lib/yaml-lite.sh"
PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GROUPS_DIR="$PROJECT_DIR/docs/groups"
SPECS_DIR="$PROJECT_DIR/docs/specs"
errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

# parse a doc's frontmatter via the shared yaml-lite parser; nonzero on parse failure.
# Output is the flat `key=value` / `key[]=item` form yaml-lite emits.
parse_fm() { yaml_lite_parse frontmatter "$1" 2>/dev/null; }
# first scalar <key> from a captured dump
dump_scalar() { printf '%s\n' "$1" | awk -v k="$2=" 'index($0,k)==1 { print substr($0, length(k)+1); exit }'; }
# every list item for <key> from a captured dump (one per line; flow or block)
dump_list() { printf '%s\n' "$1" | awk -v k="$2[]=" 'index($0,k)==1 { print substr($0, length(k)+1) }'; }
# exact (non-regex, non-glob) membership of <needle> in a dump's <key> list
dump_has() {
  local needle="$1" dump="$2" key="$3" m
  while IFS= read -r m; do [ "$m" = "$needle" ] && return 0; done < <(dump_list "$dump" "$key")
  return 1
}
# doc name: frontmatter `name:` else basename
doc_name() { local n; n="$(dump_scalar "$1" name)"; [ -n "$n" ] && { printf '%s\n' "$n"; return; }
  local b; b="$(basename "$2")"; printf '%s\n' "${b%.spec.md}" | sed 's/\.md$//'; }
# a component/group name: lowercase alnum + hyphen
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]]; }
# an owns-path must be repo-relative with no traversal
safe_relpath() { case "$1" in ""|/*|*..*) return 1 ;; *) return 0 ;; esac; }
# the declared owner of a glue file: SKILL.md / *.md via frontmatter `owner:`, else line-2 `# owner:`
file_owner() {
  case "$1" in
    *.md) parse_fm "$1" | awk -v k="owner=" 'index($0,k)==1 { print substr($0, length(k)+1); exit }' ;;
    *)    local l2; l2="$(sed -n '2p' "$1")"; case "$l2" in "# owner: "*) printf '%s\n' "${l2#\# owner: }" ;; esac ;;
  esac
}

[ -d "$GROUPS_DIR" ] || { echo "group-membership: OK (no docs/groups/)"; exit 0; }

# ── 1 & 3: forward checks over each group ──
for g in "$GROUPS_DIR"/*.md; do
  [ -e "$g" ] || continue
  [ "$(basename "$g")" = "README.md" ] && continue
  if ! gdump="$(parse_fm "$g")"; then fail "group '$(basename "$g")': unparseable frontmatter (yaml-lite)"; continue; fi
  gname="$(doc_name "$gdump" "$g")"
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    if ! valid_name "$child"; then fail "group '$gname' contains invalid name '$child' (must match [a-z][a-z0-9-]*)"; continue; fi
    cspec="$SPECS_DIR/$child.spec.md"; cgrp="$GROUPS_DIR/$child.md"
    if [ -f "$cspec" ]; then cdoc="$cspec"; elif [ -f "$cgrp" ]; then cdoc="$cgrp"; else
      fail "group '$gname' contains '$child' but no docs/specs/$child.spec.md or docs/groups/$child.md (orphan contains)"; continue; fi
    if ! cdump="$(parse_fm "$cdoc")"; then fail "child '$child': unparseable frontmatter"; continue; fi
    [ "$(dump_scalar "$cdump" parent)" = "$gname" ] || fail "child '$child' does not declare parent: $gname (missing parent)"
  done < <(dump_list "$gdump" contains)
  while IFS= read -r glue; do
    [ -n "$glue" ] || continue
    if ! safe_relpath "$glue"; then fail "group '$gname' owns unsafe path '$glue' (no '..' or leading '/')"; continue; fi
    gf="$PROJECT_DIR/$glue"
    [ -f "$gf" ] || { fail "group '$gname' owns '$glue' but file is missing"; continue; }
    [ "$(file_owner "$gf")" = "$gname" ] || fail "glue '$glue' does not declare owner '$gname' (forward glue)"
  done < <(dump_list "$gdump" owns)
done

# ── 2: reverse parent over specs + groups ──
for doc in "$SPECS_DIR"/*.spec.md "$GROUPS_DIR"/*.md; do
  [ -e "$doc" ] || continue
  [ "$(basename "$doc")" = "README.md" ] && continue
  # This scan sweeps ALL specs/groups; an unparseable/frontmatter-less doc declares no
  # parent we can read and is not a group-layer participant (e.g. a mislocated proposal
  # doc). Skip it — malformed specs are other validators' concern. Group docs are still
  # parse-checked in the forward loop above.
  ddump="$(parse_fm "$doc")" || continue
  # no-dual-parent (#742 D1): parent must be a single scalar; a list form means two (or zero) owning groups.
  # dump_list catches populated lists (flow + block). An empty flow list `parent: []` is dropped silently by
  # yaml-lite, so also reject any flow-list value from the raw frontmatter (value begins with '[').
  parent_raw="$(sed -n '/^---[[:space:]]*$/,/^---[[:space:]]*$/p' "$doc" | sed -n 's/^parent:[[:space:]]*//p' | head -1)"
  if [ -n "$(dump_list "$ddump" parent)" ] || [ "${parent_raw#\[}" != "$parent_raw" ]; then
    fail "doc '$(basename "$doc")' declares parent as a list — a component has exactly one owning group (no dual parents)"; continue
  fi
  parent="$(dump_scalar "$ddump" parent)"; [ -z "$parent" ] && continue
  if ! valid_name "$parent"; then fail "doc '$(basename "$doc")' has invalid parent '$parent'"; continue; fi
  pg="$GROUPS_DIR/$parent.md"
  if [ ! -f "$pg" ]; then
    # a group's parent may be the project root (no group doc) — tolerate; a spec's must not dangle.
    # KNOWN LIMITATION (#681 B4): for a GROUP this tolerates a typo'd/deleted parent name too,
    # because the validator has no project-root identifier to compare against. Harmless while no
    # real sub-groups exist (none ship with #681); tighten when nesting lands — follow-up #712.
    case "$doc" in "$GROUPS_DIR"/*) continue ;; *) fail "doc '$(basename "$doc")' has parent: $parent but no docs/groups/$parent.md (dangling parent)"; continue ;; esac
  fi
  if ! pgdump="$(parse_fm "$pg")"; then fail "parent group '$parent': unparseable frontmatter"; continue; fi
  dname="$(doc_name "$ddump" "$doc")"
  dump_has "$dname" "$pgdump" contains || fail "group '$parent' does not list '$dname' in contains: (reverse parent)"
done

# ── 4: reverse glue — any file owned by a group must be in that group's owns: ──
reverse_glue_check() {
  local f="$1" rel="$2" ownr
  ownr="$(file_owner "$f")"
  [ -n "$ownr" ] || return 0
  valid_name "$ownr" || return 0
  [ -f "$GROUPS_DIR/$ownr.md" ] || return 0            # owner is not a group
  local pgdump
  if ! pgdump="$(parse_fm "$GROUPS_DIR/$ownr.md")"; then fail "group '$ownr': unparseable frontmatter"; return 0; fi
  dump_has "$rel" "$pgdump" owns || fail "glue '$rel' declares owner '$ownr' but group '$ownr' does not list it in owns: (reverse glue)"
}
if [ -d "$PROJECT_DIR/scripts" ]; then
  while IFS= read -r sf; do
    [ -n "$sf" ] || continue
    reverse_glue_check "$sf" "${sf#"$PROJECT_DIR"/}"
  done < <(find "$PROJECT_DIR/scripts" -type d \( -name _archived -o -name _fixtures \) -prune -o -type f -name '*.sh' -print 2>/dev/null)
fi
if [ -d "$PROJECT_DIR/skills" ]; then
  while IFS= read -r sf; do
    [ -n "$sf" ] || continue
    reverse_glue_check "$sf" "${sf#"$PROJECT_DIR"/}"
  done < <(find "$PROJECT_DIR/skills" -type f -name 'SKILL.md' -print 2>/dev/null)
fi

if [ "$errors" -gt 0 ]; then echo "group-membership: $errors violation(s)"; exit 1; fi
echo "group-membership: OK"; exit 0
