#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# ci-parallel: safe
# _smoke-test-contract-roadmap-lib.sh — Contract test for
# docs/contracts/roadmap-lib.contract.md. Asserts RL-1..RL-40f against
# scripts/roadmap/lib.sh.
#
# The library resolves the project root via `git rev-parse --show-toplevel`,
# so each case runs inside a throwaway git repo (mktemp + git init) that
# carries a fixture roadmap.config.yaml. Functions are exercised in a
# subshell that cd's into the fixture root and sources the lib, so the
# real lib.sh is the unit under test. Covers the load-bearing helpers
# (root/config resolution, the scalar/list getters, pulse round-trip,
# backend selection, and the GitHub tracker adapter dispatch).
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }
assert_raw_ado_tags() {
  local label="$1" tags="$2" rc="${3:-0}" rc2="${4:-0}" detail="${5:-}"
  local reason=""
  [ "$rc" = 0 ] || reason="${reason} normalize_rc=$rc"
  [ "$rc2" = 0 ] || reason="${reason} merge_rc=$rc2"
  case "$tags" in *\"*) reason="${reason} contains_double_quote" ;; esac
  case "$tags" in *"component:docs"*) ;; *) reason="${reason} missing_component" ;; esac
  case "$tags" in *"horizon:later"*) ;; *) reason="${reason} missing_horizon" ;; esac
  case "$tags" in *";"*) ;; *) reason="${reason} missing_semicolon" ;; esac
  if [ -z "$reason" ]; then
    pass "$label"
  else
    fail_case "$label" "tags=[$tags]$reason ${detail}"
  fi
}

# Build a git-repo fixture with a block-style config.
git -C "$FIX" init -q
cat > "$FIX/roadmap.config.yaml" <<'YAML'
wip_limit: "3"   # inline comment must be stripped
profile: lean
component_values:
  - skills
  - workflows
  - hooks
YAML

# Helper: run a function inside the fixture root with the lib sourced.
# shellcheck source=scripts/roadmap/lib.sh
inlib() { ( cd "$FIX" && source "$LIB" && "$@" ); }

# RL-1 — project root resolves to the fixture repo toplevel
root=$(inlib roadmap_project_root)
# macOS /tmp symlinks to /private/tmp; compare basenames-resolved paths.
if [ -n "$root" ] && [ "$(cd "$root" && pwd -P)" = "$(cd "$FIX" && pwd -P)" ]; then pass RL-1
else fail_case RL-1 "root=$root fix=$FIX"; fi

# RL-2 — config path present, then absent
cpath=$(inlib roadmap_config_path)
[ -n "$cpath" ] && pass "RL-2 (present)" || fail_case "RL-2 (present)" "cpath empty"
mv "$FIX/roadmap.config.yaml" "$FIX/roadmap.config.yaml.bak"
cpath_absent=$(inlib roadmap_config_path)
[ -z "$cpath_absent" ] && pass "RL-2 (absent)" || fail_case "RL-2 (absent)" "got=$cpath_absent"
mv "$FIX/roadmap.config.yaml.bak" "$FIX/roadmap.config.yaml"

# RL-3 — scalar getter: quotes + inline comment stripped
wip=$(inlib roadmap_config_get wip_limit)
[ "$wip" = "3" ] && pass RL-3 || fail_case RL-3 "wip=[$wip]"

# RL-4 — malformed key name → nonzero, no value
badout=$(inlib roadmap_config_get 'bad key' 2>/dev/null); rc=$?
[ "$rc" != 0 ] && [ -z "$badout" ] && pass RL-4 || fail_case RL-4 "rc=$rc out=[$badout]"

# RL-5 — list getter: block style, flow style, and missing key, asserted on
# BOTH the python3 fallback path (yq hidden) and the real mikefarah-yq path.
# The two paths must produce identical output (one element per line; nothing for
# a missing key). The yq-path cases are skipped-with-reason when yq is absent.
NOYQ_BIN="$FIX/.noyq-bin"; mkdir -p "$NOYQ_BIN"
IFS=':' read -ra _pdirs <<< "$PATH"
for _d in "${_pdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b=${_f##*/}
    [ "$_b" = yq ] && continue
    [ -e "$NOYQ_BIN/$_b" ] || ln -s "$_f" "$NOYQ_BIN/$_b" 2>/dev/null || true
  done
done
# shellcheck source=scripts/roadmap/lib.sh
inlib_noyq() { ( cd "$FIX" && PATH="$NOYQ_BIN" && source "$LIB" && "$@" ); }

# Fixtures for the block and flow styles, written fresh per case so the two
# paths see identical input.
write_block() { cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values:
  - skills
  - workflows
  - hooks
YAML
}
write_flow() { cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values: [skills, workflows, hooks]
YAML
}

# --- python3 fallback path (yq hidden) ---
write_block
list_block=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',' )
[ "$list_block" = "skills,workflows,hooks," ] && pass "RL-5 (python3 block)" || fail_case "RL-5 (python3 block)" "got=[$list_block]"
write_flow
list_flow=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',')
[ "$list_flow" = "skills,workflows,hooks," ] && pass "RL-5 (python3 flow)" || fail_case "RL-5 (python3 flow)" "got=[$list_flow]"
miss_py=$(inlib_noyq roadmap_config_list nonexistent_key | tr '\n' ',')
[ -z "$miss_py" ] && pass "RL-5 (python3 missing key)" || fail_case "RL-5 (python3 missing key)" "got=[$miss_py]"

# --- real mikefarah-yq path (exercises the yq expression directly) ---
if command -v yq >/dev/null 2>&1; then
  write_block
  list_yq_block=$(inlib roadmap_config_list component_values | tr '\n' ',')
  [ "$list_yq_block" = "skills,workflows,hooks," ] && pass "RL-5 (yq block)" || fail_case "RL-5 (yq block)" "got=[$list_yq_block]"
  write_flow
  list_yq_flow=$(inlib roadmap_config_list component_values | tr '\n' ',')
  [ "$list_yq_flow" = "skills,workflows,hooks," ] && pass "RL-5 (yq flow)" || fail_case "RL-5 (yq flow)" "got=[$list_yq_flow]"
  miss_yq=$(inlib roadmap_config_list nonexistent_key | tr '\n' ',')
  [ -z "$miss_yq" ] && pass "RL-5 (yq missing key)" || fail_case "RL-5 (yq missing key)" "got=[$miss_yq]"
else
  echo "SKIP: RL-5 (yq block/flow/missing) — mikefarah yq not installed; yq path not live-verified"
fi
# Restore the block fixture for downstream cases.
write_block

# RL-6 — pulse readers fail-silent when pulse file is missing
[ ! -f "$FIX/.arboretum/roadmap-pulse.json" ] || rm -f "$FIX/.arboretum/roadmap-pulse.json"
pf=$(inlib roadmap_pulse_get_field last_maintain_run); rc=$?
pn=$(inlib roadmap_pulse_get_nag maintain-overdue); rc2=$?
[ "$rc" = 0 ] && [ -z "$pf" ] && [ "$rc2" = 0 ] && [ -z "$pn" ] && pass RL-6 || fail_case RL-6 "rc=$rc pf=[$pf] rc2=$rc2 pn=[$pn]"

# RL-7 — pulse round-trip: bootstrap, update a field, read it back
inlib roadmap_pulse_bootstrap
inlib roadmap_pulse_update_field last_maintain_run "2026-05-30T12:00:00Z"
got=$(inlib roadmap_pulse_get_field last_maintain_run)
[ "$got" = "2026-05-30T12:00:00Z" ] && pass RL-7 || fail_case RL-7 "got=[$got] pulse=$(cat "$FIX/.arboretum/roadmap-pulse.json" 2>/dev/null)"

# RL-8 — backend resolution: default GitHub; roadmap.config.yaml value accepted;
# .arboretum.yml takes precedence when both are present.
rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
profile: lean
YAML
backend_default=$(inlib roadmap_backend)
[ "$backend_default" = "github" ] && pass "RL-8 (default)" || fail_case "RL-8 (default)" "got=[$backend_default]"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
YAML
backend_roadmap=$(inlib roadmap_backend)
[ "$backend_roadmap" = "azure-devops" ] && pass "RL-8 (roadmap config)" || fail_case "RL-8 (roadmap config)" "got=[$backend_roadmap]"
cat > "$FIX/.arboretum.yml" <<'YAML'
backend: github
YAML
backend_arbo=$(inlib roadmap_backend)
[ "$backend_arbo" = "github" ] && pass "RL-8 (.arboretum precedence)" || fail_case "RL-8 (.arboretum precedence)" "got=[$backend_arbo]"

# RL-8b — ADO tag merging emits raw System.Tags text in the normal bash path.
# This pins the #506 regression even on systems without zsh.
ado_label_args="$(inlib roadmap_ado_normalize_label_args "horizon:later,component:docs")"; rc=$?
ado_tags="$(inlib roadmap_ado_merge_tags "" "$ado_label_args" "")"; rc2=$?
assert_raw_ado_tags "RL-8b (ADO merged tags are raw)" "$ado_tags" "$rc" "$rc2"

# RL-8z — sourceable shell portability: skill snippets may source lib.sh from
# zsh, so backend selection and small parser helpers must keep their bash
# contract under zsh too.
if command -v zsh >/dev/null 2>&1; then
  rm -f "$FIX/.arboretum.yml"
  cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
azure_devops_closed_states: Closed,Done
YAML
  zsh_backend=$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_backend' _ "$LIB" 2>"$FIX/zsh-backend.err"); rc=$?
  [ "$rc" = 0 ] && [ "$zsh_backend" = "azure-devops" ] \
    && pass "RL-8z (zsh roadmap backend)" \
    || fail_case "RL-8z (zsh roadmap backend)" "rc=$rc got=[$zsh_backend] err=$(cat "$FIX/zsh-backend.err")"

  cat > "$FIX/.arboretum.yml" <<'YAML'
backend: azure-devops
YAML
  cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
YAML
  zsh_arbo_backend=$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_backend' _ "$LIB" 2>"$FIX/zsh-arbo.err"); rc=$?
  [ "$rc" = 0 ] && [ "$zsh_arbo_backend" = "azure-devops" ] \
    && pass "RL-8z (zsh .arboretum precedence)" \
    || fail_case "RL-8z (zsh .arboretum precedence)" "rc=$rc got=[$zsh_arbo_backend] err=$(cat "$FIX/zsh-arbo.err")"

  cat > "$FIX/roadmap.config.yaml" <<'YAML'
azure_devops_closed_states: Closed,Done
YAML
  zsh_closed=$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_ado_closed_states_joined' _ "$LIB" 2>"$FIX/zsh-closed.err"); rc=$?
  [ "$rc" = 0 ] && [ "$zsh_closed" = "'Closed','Done'" ] \
    && pass "RL-8z (zsh closed states)" \
    || fail_case "RL-8z (zsh closed states)" "rc=$rc got=[$zsh_closed] err=$(cat "$FIX/zsh-closed.err")"

  if (cd "$FIX" && zsh -fc 'source "$1"; roadmap_csv_has_field "number,comments" comments' _ "$LIB" 2>"$FIX/zsh-csv.err"); then
    pass "RL-8z (zsh CSV field detection)"
  else
    fail_case "RL-8z (zsh CSV field detection)" "err=$(cat "$FIX/zsh-csv.err")"
  fi

  rm -f "$FIX/zsh-csv-marker"
  zsh_csv_data=$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_ado_normalize_label_args "safe,\$(touch zsh-csv-marker),done"' _ "$LIB" 2>"$FIX/zsh-csv-data.err"); rc=$?
  if [ "$rc" = 0 ] \
     && [ "$zsh_csv_data" = $'safe\n$(touch zsh-csv-marker)\ndone' ] \
     && [ ! -e "$FIX/zsh-csv-marker" ]; then
    pass "RL-8z (zsh CSV shell-looking data)"
  else
    fail_case "RL-8z (zsh CSV shell-looking data)" "rc=$rc got=[$zsh_csv_data] err=$(cat "$FIX/zsh-csv-data.err") marker=$(test -e "$FIX/zsh-csv-marker" && echo present || echo absent)"
  fi

  ado_label_args="$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_ado_normalize_label_args "horizon:later,component:docs"' _ "$LIB" 2>"$FIX/zsh-ado-labels.err")"; rc=$?
  ado_tags="$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_ado_merge_tags "" "$2" ""' _ "$LIB" "$ado_label_args" 2>"$FIX/zsh-ado-tags.err")"; rc2=$?
  assert_raw_ado_tags "RL-8z (zsh ADO merged tags are raw)" "$ado_tags" "$rc" "$rc2" "labels_err=$(cat "$FIX/zsh-ado-labels.err") tags_err=$(cat "$FIX/zsh-ado-tags.err")"

  mkdir -p "$FIX/.arboretum"
  cat > "$FIX/.arboretum/roadmap-pulse.json" <<'JSON'
{"last_maintain_run":"old","nag_last_fired":{"maintain-overdue":"old"}}
JSON
  zsh_pulse=$(cd "$FIX" && zsh -fc 'source "$1"; roadmap_pulse_update_field last_maintain_run new; roadmap_pulse_get_field last_maintain_run' _ "$LIB" 2>"$FIX/zsh-pulse.err"); rc=$?
  [ "$rc" = 0 ] && [ "$zsh_pulse" = "new" ] \
    && pass "RL-8z (zsh pulse read/write)" \
    || fail_case "RL-8z (zsh pulse read/write)" "rc=$rc got=[$zsh_pulse] err=$(cat "$FIX/zsh-pulse.err")"
else
  echo "SKIP: RL-8z (zsh not available)"
fi

rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
YAML

# RL-9 — GitHub tracker adapter delegates issue-list through gh while keeping
# the caller on the backend-neutral function.
GH_BIN="$FIX/.gh-bin"; mkdir -p "$GH_BIN"
cat > "$GH_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [ "$1 $2" = "issue list" ]; then
  printf '[]'
  exit 0
fi
if [ "$1 $2" = "issue close" ]; then exit 0; fi
if [ "$1" = "api" ]; then printf '[]'; exit 0; fi
if [ "$1 $2" = "pr list" ]; then printf '[]'; exit 0; fi
if [ "$1 $2" = "pr view" ]; then
  shift 2
  fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) fields="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  : "${GH_STUB_PR_BODY:=$(printf '## Tracker\nCloses #484')}"
  : "${GH_STUB_PR_STATE:=MERGED}"
  : "${GH_STUB_PR_MERGED_AT:=2026-06-03T00:00:00Z}"
  export GH_STUB_PR_BODY GH_STUB_PR_STATE GH_STUB_PR_MERGED_AT
  python3 - "$fields" <<'PY'
import json
import os
import sys

fields = [field.strip() for field in sys.argv[1].split(",") if field.strip()]
data = {
    "number": 42,
    "body": os.environ["GH_STUB_PR_BODY"],
    "state": os.environ["GH_STUB_PR_STATE"],
    "mergedAt": os.environ["GH_STUB_PR_MERGED_AT"],
}
if fields:
    data = {field: data[field] for field in fields if field in data}
print(json.dumps(data, separators=(",", ":")), end="")
PY
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
GH
chmod +x "$GH_BIN/gh"
export GH_STUB_LOG="$FIX/gh.log"
: > "$GH_STUB_LOG"
tracker_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_issue_list --label next-up --state open --limit 1)
if [ "$tracker_out" = "[]" ] && grep -q 'issue list --label next-up --state open --limit 1' "$FIX/gh.log"; then
  pass RL-9
else
  fail_case RL-9 "out=[$tracker_out] log=$(cat "$FIX/gh.log" 2>/dev/null)"
fi

# RL-10 — Additional GitHub adapter wrappers delegate close/comment-list/PR-list
# through the same backend-neutral surface used by stage and maintain scripts.
PATH="$GH_BIN:$PATH" inlib roadmap_tracker_issue_close 42 --reason completed >/dev/null \
  || fail_case "RL-10 (close)" "close helper failed"
comments_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_issue_comments 42 --paginate)
prs_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_list --state merged --limit 1)
if [ "$comments_out" = "[]" ] \
   && [ "$prs_out" = "[]" ] \
   && grep -q 'issue close 42 --reason completed' "$FIX/gh.log" \
   && grep -q 'api repos/{owner}/{repo}/issues/42/comments --paginate' "$FIX/gh.log" \
   && grep -q 'pr list --state merged --limit 1' "$FIX/gh.log"; then
  pass RL-10
else
  fail_case RL-10 "comments=[$comments_out] prs=[$prs_out] log=$(cat "$FIX/gh.log" 2>/dev/null)"
fi

# RL-21..RL-23 — PR detail and closure-status helpers stay behind the
# roadmap backend seam. The closure helper emits controlled key=value lines
# rather than raw provider body text.
pr_show_filtered_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_show 42 --json number,body,state)
if [ "$pr_show_filtered_out" = '{"number":42,"body":"## Tracker\nCloses #484","state":"MERGED"}' ] \
   && grep -q 'pr view 42 --json number,body,state' "$FIX/gh.log"; then
  pass "RL-21 (github pr show projection)"
else
  fail_case "RL-21 (github pr show projection)" "out=[$pr_show_filtered_out] log=$(cat "$FIX/gh.log" 2>/dev/null)"
fi

pr_show_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_show 42 --json number,body,state,mergedAt)
if [ "$pr_show_out" = '{"number":42,"body":"## Tracker\nCloses #484","state":"MERGED","mergedAt":"2026-06-03T00:00:00Z"}' ] \
   && grep -q 'pr view 42 --json number,body,state,mergedAt' "$FIX/gh.log"; then
  pass RL-21
else
  fail_case RL-21 "out=[$pr_show_out] log=$(cat "$FIX/gh.log" 2>/dev/null)"
fi

closure_out=$(PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 42 484)
if printf '%s\n' "$closure_out" | grep -qx 'provider=github' \
   && printf '%s\n' "$closure_out" | grep -qx 'intent=close' \
   && printf '%s\n' "$closure_out" | grep -qx 'verification=supported' \
   && printf '%s\n' "$closure_out" | grep -qx 'evidence=Merged PR #42 declares close intent for #484'; then
  pass RL-22
else
  fail_case RL-22 "out=[$closure_out]"
fi

closure_reference_out=$(GH_STUB_PR_BODY='See #484 for the tracker.' PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 42 484)
if printf '%s\n' "$closure_reference_out" | grep -qx 'provider=github' \
   && printf '%s\n' "$closure_reference_out" | grep -qx 'intent=reference' \
   && printf '%s\n' "$closure_reference_out" | grep -qx 'verification=supported' \
   && printf '%s\n' "$closure_reference_out" | grep -qx 'evidence=Merged PR #42 references #484 without close intent'; then
  pass "RL-22 (reference)"
else
  fail_case "RL-22 (reference)" "out=[$closure_reference_out]"
fi

closure_none_out=$(GH_STUB_PR_BODY='Tracker issue intentionally omitted.' PATH="$GH_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 42 484)
if printf '%s\n' "$closure_none_out" | grep -qx 'provider=github' \
   && printf '%s\n' "$closure_none_out" | grep -qx 'intent=none' \
   && printf '%s\n' "$closure_none_out" | grep -qx 'verification=supported' \
   && printf '%s\n' "$closure_none_out" | grep -qx 'evidence=Merged PR #42 does not reference #484'; then
  pass "RL-22 (none)"
else
  fail_case "RL-22 (none)" "out=[$closure_none_out]"
fi

# RL-11..RL-17 — Azure DevOps tracker adapter maps the same neutral helper
# surface onto az boards/devops calls and normalizes work-item JSON into the
# GitHub-shaped fields consumed by existing roadmap scripts.
cat > "$FIX/.arboretum.yml" <<'YAML'
backend: azure-devops
azure_devops_organization: https://dev.azure.com/example
azure_devops_project: Demo
azure_devops_work_item_type: Issue
azure_devops_done_state: Closed
YAML
cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values:
  - skills
YAML

AZ_BIN="$FIX/.az-bin"; mkdir -p "$AZ_BIN"
cat > "$AZ_BIN/az" <<'AZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AZ_STUB_LOG:?}"
if [ "$1 $2" = "devops -h" ] || [ "$1 $2" = "boards -h" ] || [ "$1 $2" = "repos -h" ]; then
  exit 0
fi
if [ "$1 $2 $3" = "devops configure --list" ]; then
  printf 'organization = https://dev.azure.com/example\nproject = Demo\n'
  exit 0
fi
if [ "$1 $2" = "boards query" ]; then
  printf '%s\n' '[{"id":42,"fields":{"System.Title":"Ship ADO adapter","System.Description":"## Goal\nUse ADO","System.Tags":"next-up; horizon:next","System.CreatedDate":"2026-05-29T00:00:00Z","System.ChangedDate":"2026-05-30T00:00:00Z","System.State":"Active"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/42"}}}]'
  exit 0
fi
if [ "$1 $2 $3" = "boards work-item show" ]; then
  if printf '%s\n' "$*" | grep -q -- '--id 484'; then
    printf '%s\n' '{"id":484,"fields":{"System.Title":"Open linked ADO work item","System.State":"Active","System.ChangedDate":"2026-06-03T12:00:00Z"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/484"}}}'
    exit 0
  elif printf '%s\n' "$*" | grep -q -- '--id 485'; then
    printf '%s\n' '{"id":485,"fields":{"System.Title":"Closed linked ADO work item","System.State":"Closed","Microsoft.VSTS.Common.ClosedDate":"2026-06-03T12:00:00Z"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/485"}}}'
    exit 0
  elif printf '%s\n' "$*" | grep -q -- '--id 486'; then
    printf '%s\n' '{"id":486,"fields":{"System.Title":"Whitespace-normalized ADO work item","System.State":" Done "},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/486"}}}'
    exit 0
  fi
  if printf '%s\n' "$*" | grep -q -- '--id 47'; then
    if printf '%s\n' "$*" | grep -q -- '--fields System.Tags'; then
      printf '%s\n' '{"id":47,"fields":{"System.Tags":"stage:build; agent-ready"}}'
    else
      printf '%s\n' '{"id":47,"fields":{"System.Title":"Stage label swap","System.Description":"Body","System.Tags":"stage:build; agent-ready","System.CreatedDate":"2026-05-29T00:00:00Z","System.ChangedDate":"2026-05-30T00:00:00Z","System.State":"Active"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/47"}}}'
    fi
    exit 0
  fi
  if printf '%s\n' "$*" | grep -q -- '--fields System.Tags'; then
    printf '%s\n' '{"id":42,"fields":{"System.Tags":"agent-ready; horizon:next"}}'
  else
    printf '%s\n' '{"id":42,"fields":{"System.Title":"Ship ADO adapter","System.Description":"## Goal\nUse ADO","System.Tags":"agent-ready; horizon:next","System.CreatedDate":"2026-05-29T00:00:00Z","System.ChangedDate":"2026-05-30T00:00:00Z","System.State":"Active"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/42"}}}'
  fi
  exit 0
fi
if [ "$1 $2" = "devops invoke" ]; then
  if printf '%s\n' "$*" | grep -q -- '--http-method PATCH'; then
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--in-file" ]; then
        cp "$arg" "${AZ_STUB_PATCH_LOG:?}"
      fi
      prev="$arg"
    done
    exit 0
  fi
  printf '%s\n' '{"value":[{"text":"agent-prep:verified date=2026-05-30 body-sha=abc123","createdDate":"2026-05-30T01:00:00Z"}]}'
  exit 0
fi
if [ "$1 $2 $3" = "boards work-item update" ]; then
  exit 0
fi
if [ "$1 $2 $3" = "boards work-item create" ]; then
  printf '%s\n' '{"id":77,"fields":{"System.Title":"Captured idea","System.Description":"Body","System.Tags":"component:skills; horizon:later","System.CreatedDate":"2026-05-31T00:00:00Z","System.ChangedDate":"2026-05-31T00:00:00Z","System.State":"New"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/77"}}}'
  exit 0
fi
if [ "$1 $2 $3" = "repos pr show" ]; then
  printf '%s\n' '{"pullRequestId":42,"title":"ADO PR","description":"Linked work item: #484","status":"completed","closedDate":"2026-06-03T00:00:00Z"}'
  exit 0
fi
if [ "$1 $2 $3 $4" = "repos pr work-item list" ]; then
  if printf '%s\n' "$*" | grep -q -- '--id 42'; then
    printf '%s\n' '[{"id":484,"fields":{"System.Title":"Open linked ADO work item","System.State":"Active"},"url":"https://dev.azure.com/example/Demo/_apis/wit/workItems/484"}]'
    exit 0
  fi
  if printf '%s\n' "$*" | grep -q -- '--id 43'; then
    printf '%s\n' '[{"id":485,"fields":{"System.Title":"Closed linked ADO work item","System.State":"Closed"},"url":"https://dev.azure.com/example/Demo/_apis/wit/workItems/485"}]'
    exit 0
  fi
  if printf '%s\n' "$*" | grep -q -- '--id 44'; then
    printf '%s\n' '[]'
    exit 0
  fi
  if printf '%s\n' "$*" | grep -q -- '--id 45'; then
    echo "simulated work-item list failure" >&2
    exit 1
  fi
  if printf '%s\n' "$*" | grep -q -- '--id 46'; then
    printf '%s\n' '[{"id":486,"fields":{"System.Title":"Whitespace-normalized ADO work item","System.State":" Done "},"url":"https://dev.azure.com/example/Demo/_apis/wit/workItems/486"}]'
    exit 0
  fi
fi
echo "unexpected az call: $*" >&2
exit 2
AZ
chmod +x "$AZ_BIN/az"
export AZ_STUB_LOG="$FIX/az.log"
export AZ_STUB_PATCH_LOG="$FIX/az.patch.json"
: > "$AZ_STUB_LOG"
: > "$AZ_STUB_PATCH_LOG"

PATH="$AZ_BIN:$PATH" inlib roadmap_require_backend azure-devops >/dev/null \
  && pass RL-11 || fail_case RL-11 "azure-devops backend guard failed"

ado_list=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_list --label next-up --state open --limit 1 --json number,title,labels,updatedAt)
if printf '%s' "$ado_list" | jq -e '.[0].number == 42 and (.[0].labels | map(.name) | index("next-up")) and .[0].updatedAt == "2026-05-30T00:00:00Z"' >/dev/null \
   && grep -q 'boards query --wiql' "$AZ_STUB_LOG"; then
  pass RL-12
else
  fail_case RL-12 "out=[$ado_list] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi
ado_list_unfiltered=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_list --state open --limit 1 --json number)
if printf '%s' "$ado_list_unfiltered" | jq -e '.[0].number == 42' >/dev/null; then
  pass "RL-12 (no label filters)"
else
  fail_case "RL-12 (no label filters)" "out=[$ado_list_unfiltered] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

ado_show=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_show 42 --json number,title,body,labels,comments)
if printf '%s' "$ado_show" | jq -e '.number == 42 and .comments[0].authorAssociation == "MEMBER" and (.labels | map(.name) | index("agent-ready"))' >/dev/null \
   && grep -q 'devops invoke --area wit --resource workItemComments' "$AZ_STUB_LOG"; then
  pass RL-13
else
  fail_case RL-13 "out=[$ado_show] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_update 42 --add-label next-up --remove-label agent-ready >/dev/null \
  || fail_case RL-14 "update helper failed"
if jq -e '.[] | select(.path == "/fields/System.Tags" and .op == "replace" and (.value | contains("next-up")) and ((.value | contains("agent-ready")) | not))' "$AZ_STUB_PATCH_LOG" >/dev/null; then
  pass RL-14
else
  fail_case RL-14 "patch=$(cat "$AZ_STUB_PATCH_LOG" 2>/dev/null)"
fi
PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_update 42 --add-label next-up >/dev/null \
  && pass "RL-14 (add-only labels)" \
  || fail_case "RL-14 (add-only labels)" "add-only update helper failed"

ado_markdown_body=$'## Summary\n\nThis keeps **bold** and `code` while escaping <unsafe>.\n\n- one\n- two'
: > "$AZ_STUB_PATCH_LOG"
PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_update 42 --body "$ado_markdown_body" >/dev/null \
  || fail_case "RL-28 (ADO body update renders Markdown)" "body update helper failed"
if jq -e '
  .[]
  | select(
      .path == "/fields/System.Description"
      and (.value | contains("<h2>Summary</h2>"))
      and (.value | contains("<strong>bold</strong>"))
      and (.value | contains("<code>code</code>"))
      and (.value | contains("&lt;unsafe&gt;"))
      and (.value | contains("<ul>"))
    )
' "$AZ_STUB_PATCH_LOG" >/dev/null; then
  pass "RL-28 (ADO body update renders Markdown)"
else
  fail_case "RL-28 (ADO body update renders Markdown)" "patch=$(cat "$AZ_STUB_PATCH_LOG" 2>/dev/null)"
fi
if grep -q 'sys.stdin.read()' "$LIB" \
   && ! grep -q 'python3 - "$1"' "$LIB"; then
  pass "RL-28 (ADO renderer reads body from stdin)"
else
  fail_case "RL-28 (ADO renderer reads body from stdin)" "renderer still appears to use argv payloads"
fi

ado_html_existing_body=$'<!-- pipeline-state:current-stage -->\n**Current stage:** /land\n<!-- /pipeline-state:current-stage -->\n\n<h2>Summary</h2><p>Already stored as ADO HTML.</p>'
: > "$AZ_STUB_PATCH_LOG"
PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_update 42 --body "$ado_html_existing_body" >/dev/null \
  || fail_case "RL-28 (ADO body update preserves existing HTML)" "body update helper failed"
if jq -e '
  .[]
  | select(
      .path == "/fields/System.Description"
      and (.value | contains("<!-- pipeline-state:current-stage -->"))
      and (.value | contains("<strong>Current stage:</strong> /land"))
      and (.value | contains("<!-- /pipeline-state:current-stage -->"))
      and (.value | contains("<h2>Summary</h2><p>Already stored as ADO HTML.</p>"))
      and ((.value | contains("&lt;h2&gt;")) | not)
    )
' "$AZ_STUB_PATCH_LOG" >/dev/null; then
  pass "RL-28 (ADO body update preserves existing HTML)"
else
  fail_case "RL-28 (ADO body update preserves existing HTML)" "patch=$(cat "$AZ_STUB_PATCH_LOG" 2>/dev/null)"
fi

PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_comment 42 --body "hello from roadmap" >/dev/null \
  || fail_case "RL-15 (comment)" "comment helper failed"
PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_close 42 --reason completed --comment "done from roadmap" >/dev/null \
  || fail_case "RL-15 (close)" "close helper failed"
ado_prs=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_list --state merged --limit 1 --json number,title)
if [ "$ado_prs" = "[]" ] \
   && grep -q 'boards work-item update --id 42 --discussion hello from roadmap' "$AZ_STUB_LOG" \
   && grep -q 'boards work-item update --id 42 --state Closed' "$AZ_STUB_LOG"; then
  pass RL-15
else
  fail_case RL-15 "prs=[$ado_prs] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

ado_labels=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_label_list --limit 100 --json name --jq '.[].name' | sort)
if printf '%s\n' "$ado_labels" | grep -Fxq "type:feature" \
   && printf '%s\n' "$ado_labels" | grep -Fxq "horizon:now" \
   && printf '%s\n' "$ado_labels" | grep -Fxq "component:skills"; then
  pass RL-16
else
  fail_case RL-16 "labels=[$ado_labels]"
fi

ado_created=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_create --title "Captured idea" --label "horizon:later,component:skills" --body "$ado_markdown_body")
if printf '%s' "$ado_created" | jq -e '.number == 77 and (.labels | map(.name) | index("component:skills"))' >/dev/null \
   && grep -q 'boards work-item create --title Captured idea --type Issue' "$AZ_STUB_LOG"; then
  pass RL-17
else
  fail_case RL-17 "out=[$ado_created] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi
if grep -Fq '<h2>Summary</h2>' "$AZ_STUB_LOG" \
   && grep -Fq '<strong>bold</strong>' "$AZ_STUB_LOG" \
   && grep -Fq '&lt;unsafe&gt;' "$AZ_STUB_LOG"; then
  pass "RL-29 (ADO create renders Markdown body)"
else
  fail_case "RL-29 (ADO create renders Markdown body)" "log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

# RL-20 — Cedar-shaped Azure DevOps config: no .arboretum.yml, backend in
# roadmap.config.yaml, provider knobs under the namespaced azure_devops block.
rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
azure_devops:
  organization: VCH-DataAnalytics
  project: Advanced_Data_Analytics
  default_work_item_type: Issue
  default_assigned_to: Stephen.Vangaal@vch.ca
  marker_tag: cedar
YAML
cedar_backend=$(inlib roadmap_backend)
cedar_org=$(inlib roadmap_ado_organization)
cedar_project=$(inlib roadmap_ado_project)
cedar_type=$(inlib roadmap_ado_work_item_type)
if [ "$cedar_backend" = "azure-devops" ] \
   && [ "$cedar_org" = "https://dev.azure.com/VCH-DataAnalytics" ] \
   && [ "$cedar_project" = "Advanced_Data_Analytics" ] \
   && [ "$cedar_type" = "Issue" ]; then
  pass RL-20
else
  fail_case RL-20 "backend=[$cedar_backend] org=[$cedar_org] project=[$cedar_project] type=[$cedar_type]"
fi

ado_pr_show=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_show 42 --json number,body,state,mergedAt)
if printf '%s' "$ado_pr_show" | jq -e '.number == 42 and .state == "completed" and .body == "Linked work item: #484"' >/dev/null \
   && grep -q 'repos pr show --id 42' "$AZ_STUB_LOG"; then
  pass "RL-21 (azure-devops pr show)"
else
  fail_case "RL-21 (azure-devops pr show)" "out=[$ado_pr_show] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

ado_closure_open=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 42 484)
if printf '%s\n' "$ado_closure_open" | grep -qx 'provider=azure-devops' \
   && printf '%s\n' "$ado_closure_open" | grep -qx 'intent=unknown' \
   && printf '%s\n' "$ado_closure_open" | grep -qx 'verification=unknown' \
   && printf '%s\n' "$ado_closure_open" | grep -qx 'evidence=Azure DevOps PR #42 links work item #484 but the work item is not closed' \
   && grep -q 'repos pr work-item list --id 42' "$AZ_STUB_LOG" \
   && grep -q 'boards work-item show --id 484' "$AZ_STUB_LOG"; then
  pass "RL-23 (ADO linked work item open)"
else
  fail_case "RL-23 (ADO linked work item open)" "out=[$ado_closure_open] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
fi

ado_closure_closed=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 43 485)
if printf '%s\n' "$ado_closure_closed" | grep -qx 'provider=azure-devops' \
   && printf '%s\n' "$ado_closure_closed" | grep -qx 'intent=close' \
   && printf '%s\n' "$ado_closure_closed" | grep -qx 'verification=supported' \
   && printf '%s\n' "$ado_closure_closed" | grep -qx 'evidence=Azure DevOps PR #43 links work item #485 and the work item is closed'; then
  pass "RL-24 (ADO linked work item closed)"
else
  fail_case "RL-24 (ADO linked work item closed)" "out=[$ado_closure_closed]"
fi

ado_closure_none=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 44 484)
if printf '%s\n' "$ado_closure_none" | grep -qx 'provider=azure-devops' \
   && printf '%s\n' "$ado_closure_none" | grep -qx 'intent=none' \
   && printf '%s\n' "$ado_closure_none" | grep -qx 'verification=unknown' \
   && printf '%s\n' "$ado_closure_none" | grep -qx 'evidence=Azure DevOps PR #44 does not link work item #484'; then
  pass "RL-25 (ADO no linked target work item)"
else
  fail_case "RL-25 (ADO no linked target work item)" "out=[$ado_closure_none]"
fi

ado_closure_failure=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 45 484)
if printf '%s\n' "$ado_closure_failure" | grep -qx 'provider=azure-devops' \
   && printf '%s\n' "$ado_closure_failure" | grep -qx 'intent=unknown' \
   && printf '%s\n' "$ado_closure_failure" | grep -qx 'verification=unknown' \
   && printf '%s\n' "$ado_closure_failure" | grep -qx 'evidence=Azure DevOps PR #45 linked work-item lookup failed'; then
  pass "RL-26 (ADO PR work-item list failure unknown)"
else
  fail_case "RL-26 (ADO PR work-item list failure unknown)" "out=[$ado_closure_failure]"
fi

cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
azure_devops:
  organization: VCH-DataAnalytics
  project: Advanced_Data_Analytics
  default_work_item_type: Issue
  closed_states: " , , "
YAML
ado_closure_trimmed_default=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_pr_closure_status 46 486)
if printf '%s\n' "$ado_closure_trimmed_default" | grep -qx 'provider=azure-devops' \
   && printf '%s\n' "$ado_closure_trimmed_default" | grep -qx 'intent=close' \
   && printf '%s\n' "$ado_closure_trimmed_default" | grep -qx 'verification=supported' \
   && printf '%s\n' "$ado_closure_trimmed_default" | grep -qx 'evidence=Azure DevOps PR #46 links work item #486 and the work item is closed'; then
  pass "RL-27 (ADO closed-state trim + empty-config fallback)"
else
  fail_case "RL-27 (ADO closed-state trim + empty-config fallback)" "out=[$ado_closure_trimmed_default]"
fi

# RL-30..RL-33 — roadmap_set_prefix_exclusive_label: within-issue exclusive
# swap on the GitHub backend. The helper reads current labels, removes every
# other <prefix>:* token, ensures the target exists, and applies one edit.
# Reset the fixture to the GitHub backend (prior ADO blocks left an
# azure-devops config in place).
rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values:
  - skills
YAML
SX_BIN="$FIX/.sx-bin"; mkdir -p "$SX_BIN"
cat > "$SX_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [ "$1 $2" = "issue view" ]; then printf '%s\n' ${SX_STUB_LABELS:-}; exit 0; fi
if [ "$1 $2" = "label create" ]; then exit 0; fi
if [ "$1 $2" = "issue edit" ]; then exit 0; fi
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$SX_BIN/gh"

: > "$GH_STUB_LOG"
SX_STUB_LABELS="stage:start agent-ready" PATH="$SX_BIN:$PATH" inlib roadmap_set_prefix_exclusive_label 42 stage design >/dev/null
if grep -q 'issue edit 42 --add-label stage:design --remove-label stage:start' "$GH_STUB_LOG" \
   && ! grep -q 'remove-label agent-ready' "$GH_STUB_LOG"; then
  pass RL-30
else
  fail_case RL-30 "log=$(cat "$GH_STUB_LOG")"
fi

: > "$GH_STUB_LOG"
SX_STUB_LABELS="agent-ready" PATH="$SX_BIN:$PATH" inlib roadmap_set_prefix_exclusive_label 42 stage build >/dev/null
if grep -q 'issue edit 42 --add-label stage:build' "$GH_STUB_LOG" \
   && ! grep -q 'remove-label' "$GH_STUB_LOG"; then
  pass RL-31
else
  fail_case RL-31 "log=$(cat "$GH_STUB_LOG")"
fi

: > "$GH_STUB_LOG"
SX_STUB_LABELS="stage:build stage:design" PATH="$SX_BIN:$PATH" inlib roadmap_set_prefix_exclusive_label 42 stage finish >/dev/null
if grep -Eq 'issue edit 42 --add-label stage:finish --remove-label (stage:build,stage:design|stage:design,stage:build)' "$GH_STUB_LOG"; then
  pass RL-32
else
  fail_case RL-32 "log=$(cat "$GH_STUB_LOG")"
fi

: > "$GH_STUB_LOG"
SX_STUB_LABELS="stage:design" PATH="$SX_BIN:$PATH" inlib roadmap_set_prefix_exclusive_label 42 stage design >/dev/null
if grep -q 'issue edit 42 --add-label stage:design' "$GH_STUB_LOG" \
   && ! grep -q 'remove-label' "$GH_STUB_LOG"; then
  pass RL-33
else
  fail_case RL-33 "log=$(cat "$GH_STUB_LOG")"
fi

# RL-34 — roadmap_set_prefix_exclusive_label on the Azure DevOps backend swaps
# the stage family in the resulting System.Tags JSON-patch: target tag present,
# prior stage tag gone, non-stage tags preserved.
cat > "$FIX/.arboretum.yml" <<'YAML'
backend: azure-devops
azure_devops_organization: https://dev.azure.com/example
azure_devops_project: Demo
azure_devops_work_item_type: Issue
azure_devops_done_state: Closed
YAML
: > "$AZ_STUB_PATCH_LOG"
PATH="$AZ_BIN:$PATH" inlib roadmap_set_prefix_exclusive_label 47 stage finish >/dev/null \
  || fail_case "RL-34 (ADO stage swap)" "helper failed"
if jq -e '
  .[]
  | select(
      .path == "/fields/System.Tags"
      and (.value | contains("stage:finish"))
      and ((.value | contains("stage:build")) | not)
      and (.value | contains("agent-ready"))
    )
' "$AZ_STUB_PATCH_LOG" >/dev/null; then
  pass "RL-34 (ADO stage swap)"
else
  fail_case "RL-34 (ADO stage swap)" "patch=$(cat "$AZ_STUB_PATCH_LOG" 2>/dev/null)"
fi

# RL-35 — roadmap_set_globally_exclusive_label clears the label from every other
# open holder (never the target), ensures the label exists, and applies it to the
# target. The tracker primitives are overridden at the function boundary so the
# real composite is the unit under test.
EXCL_LOG="$FIX/excl.log"; : > "$EXCL_LOG"
# shellcheck source=scripts/roadmap/lib.sh
( cd "$FIX" && source "$LIB"
  roadmap_tracker_issue_list() { printf '%s\n' 11 22 574; }
  roadmap_label_exists() { return 1; }   # label absent → exercise the create path
  roadmap_tracker_label_create() { echo "label_create $*" >> "$EXCL_LOG"; }
  roadmap_tracker_issue_update() { echo "issue_update $*" >> "$EXCL_LOG"; }
  roadmap_set_globally_exclusive_label 574 next-up
)
if grep -qx 'issue_update 11 --remove-label next-up' "$EXCL_LOG" \
   && grep -qx 'issue_update 22 --remove-label next-up' "$EXCL_LOG" \
   && ! grep -qx 'issue_update 574 --remove-label next-up' "$EXCL_LOG" \
   && grep -qx 'label_create next-up' "$EXCL_LOG" \
   && grep -qx 'issue_update 574 --add-label next-up' "$EXCL_LOG"; then
  pass RL-35
else
  fail_case RL-35 "log=$(cat "$EXCL_LOG" 2>/dev/null)"
fi

# RL-35b — with DRY_RUN=1 the helper performs no mutation (no issue_update,
# no label_create) and prints a plan naming the cleared holder and the target.
EXCL_DRY_LOG="$FIX/excl-dry.log"; : > "$EXCL_DRY_LOG"
# shellcheck source=scripts/roadmap/lib.sh
dry_out=$( cd "$FIX" && source "$LIB"
  roadmap_tracker_issue_list() { printf '%s\n' 11 574; }
  roadmap_label_exists() { return 1; }
  roadmap_tracker_label_create() { echo "label_create $*" >> "$EXCL_DRY_LOG"; }
  roadmap_tracker_issue_update() { echo "issue_update $*" >> "$EXCL_DRY_LOG"; }
  DRY_RUN=1 roadmap_set_globally_exclusive_label 574 next-up
)
if [ ! -s "$EXCL_DRY_LOG" ] \
   && printf '%s\n' "$dry_out" | grep -qxF "would remove 'next-up' from #11" \
   && printf '%s\n' "$dry_out" | grep -qxF "would add 'next-up' to #574"; then
  pass RL-35b
else
  fail_case RL-35b "mutations=$(cat "$EXCL_DRY_LOG" 2>/dev/null) out=[$dry_out]"
fi

# RL-35c — a failed holder clear is not silently ignored: the sweep still applies
# the label to the target (best-effort), but the function returns nonzero so the
# caller never reads success while exclusivity was not actually achieved.
EXCL_FAIL_LOG="$FIX/excl-fail.log"; : > "$EXCL_FAIL_LOG"
# shellcheck source=scripts/roadmap/lib.sh
( cd "$FIX" && source "$LIB"
  roadmap_tracker_issue_list() { printf '%s\n' 11 574; }
  roadmap_label_exists() { return 0; }   # label exists → skip create
  roadmap_tracker_issue_update() {
    echo "issue_update $*" >> "$EXCL_FAIL_LOG"
    case "$*" in *"11 --remove-label"*) return 1 ;; esac   # holder 11 clear fails
  }
  roadmap_set_globally_exclusive_label 574 next-up
); excl_rc=$?
if [ "$excl_rc" != 0 ] \
   && grep -qx 'issue_update 11 --remove-label next-up' "$EXCL_FAIL_LOG" \
   && grep -qx 'issue_update 574 --add-label next-up' "$EXCL_FAIL_LOG"; then
  pass RL-35c
else
  fail_case RL-35c "rc=$excl_rc log=$(cat "$EXCL_FAIL_LOG" 2>/dev/null)"
fi

# RL-35d — when the holder *list* itself fails, exclusivity is unverifiable: no
# clear is attempted (nothing enumerated), the target is still applied, and the
# helper returns nonzero rather than claiming a success it cannot back.
EXCL_LIST_LOG="$FIX/excl-list.log"; : > "$EXCL_LIST_LOG"
# shellcheck source=scripts/roadmap/lib.sh
( cd "$FIX" && source "$LIB"
  roadmap_tracker_issue_list() { return 1; }   # cannot enumerate holders
  roadmap_label_exists() { return 0; }
  roadmap_tracker_issue_update() { echo "issue_update $*" >> "$EXCL_LIST_LOG"; }
  roadmap_set_globally_exclusive_label 574 next-up
); excl_list_rc=$?
if [ "$excl_list_rc" != 0 ] \
   && grep -qx 'issue_update 574 --add-label next-up' "$EXCL_LIST_LOG" \
   && ! grep -q 'remove-label' "$EXCL_LIST_LOG"; then
  pass RL-35d
else
  fail_case RL-35d "rc=$excl_list_rc log=$(cat "$EXCL_LIST_LOG" 2>/dev/null)"
fi

# RL-36 — roadmap_inflight_board_graph (GitHub) assembles a board graph from a
# stubbed GraphQL issues page + a stubbed `gh pr list`: epic flag from
# type:epic, stage from a stage:* label, has_open_pr from the closing-issues
# map, and assignees/author normalized to logins.
rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
YAML
BG_BIN="$FIX/.bg-bin"; mkdir -p "$BG_BIN"
cat > "$BG_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
if [ "$1 $2" = "repo view" ]; then
  case "$*" in
    *owner*) printf 'octo\n' ;;
    *name*)  printf 'board\n' ;;
  esac
  exit 0
fi
if [ "$1 $2" = "api graphql" ]; then
  cat <<'JSON'
{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"number":516,"title":"Epic: Slipstream","state":"OPEN","labels":{"nodes":[{"name":"type:epic"}]},"author":{"login":"stvangaal"},"assignees":{"nodes":[]},"parent":null,"subIssues":{"nodes":[{"number":677}]}},
  {"number":677,"title":"child active","state":"OPEN","labels":{"nodes":[{"name":"stage:build"}]},"author":{"login":"stvangaal"},"assignees":{"nodes":[{"login":"stvangaal"}]},"parent":{"number":516},"subIssues":{"nodes":[]}},
  {"number":305,"title":"naked pr","state":"OPEN","labels":{"nodes":[]},"author":{"login":"bob"},"assignees":{"nodes":[]},"parent":null,"subIssues":{"nodes":[]}}
]}}}}
JSON
  exit 0
fi
if [ "$1 $2" = "pr list" ]; then
  printf '%s' '[{"number":900,"closingIssuesReferences":[{"number":305}]}]'
  exit 0
fi
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$BG_BIN/gh"
bg_out=$(PATH="$BG_BIN:$PATH" inlib roadmap_inflight_board_graph)
if printf '%s' "$bg_out" | python3 -c 'import json,sys;n=json.load(sys.stdin)["nodes"];assert "516" in n and n["516"]["is_epic"] is True;assert n["677"]["stage"]=="/build";assert n["677"]["assignees"]==["stvangaal"];assert n["516"]["children"]==[677];assert n["305"]["has_open_pr"] is True;assert n["305"]["author"]=="bob"'; then
  pass RL-36
else
  fail_case RL-36 "out=[$bg_out]"
fi

# RL-38 — roadmap_inflight_board_graph (GitHub) synthesizes nodes for CLOSED
# sub-issue children. The top-level issues query is OPEN-only, so a closed child
# never appears there; without synthesis an epic's done/total are always wrong
# (#703). Stub one OPEN epic whose subIssues are [991:OPEN, 992:CLOSED] and assert
# the emitted graph carries node 992 with state=="closed" so done can be counted.
rm -f "$FIX/.arboretum.yml"
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
YAML
CG_BIN="$FIX/.cg-bin"; mkdir -p "$CG_BIN"
cat > "$CG_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
if [ "$1 $2" = "repo view" ]; then
  case "$*" in
    *owner*) printf 'octo\n' ;;
    *name*)  printf 'board\n' ;;
  esac
  exit 0
fi
if [ "$1 $2" = "api graphql" ]; then
  cat <<'JSON'
{"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"number":990,"title":"Epic","state":"OPEN","labels":{"nodes":[{"name":"type:epic"}]},"author":{"login":"stvangaal"},"assignees":{"nodes":[]},"parent":null,"subIssues":{"nodes":[{"number":991,"state":"OPEN"},{"number":992,"state":"CLOSED"}]}},
  {"number":991,"title":"open child","state":"OPEN","labels":{"nodes":[{"name":"stage:build"}]},"author":{"login":"stvangaal"},"assignees":{"nodes":[]},"parent":{"number":990},"subIssues":{"nodes":[]}}
]}}}}
JSON
  exit 0
fi
if [ "$1 $2" = "pr list" ]; then
  printf '%s' '[]'
  exit 0
fi
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$CG_BIN/gh"
cg_out=$(PATH="$CG_BIN:$PATH" inlib roadmap_inflight_board_graph)
if printf '%s' "$cg_out" | python3 -c 'import json,sys;n=json.load(sys.stdin)["nodes"];assert "992" in n, "closed child missing";assert n["992"]["state"]=="closed", n["992"]["state"];assert n["992"]["parent"]==990;assert n["991"]["state"]=="open";assert n["990"]["children"]==[991,992]'; then
  pass RL-38
else
  fail_case RL-38 "out=[$cg_out]"
fi

# RL-37 — roadmap_current_user (GitHub) returns the gh api user login;
# unauthenticated (gh api fails) → non-zero.
CU_BIN="$FIX/.cu-bin"; mkdir -p "$CU_BIN"
cat > "$CU_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
if [ "$1" = "api" ] && [ "$2" = "user" ]; then printf 'stvangaal\n'; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$CU_BIN/gh"
cu_out=$(PATH="$CU_BIN:$PATH" inlib roadmap_current_user)
if [ "$cu_out" = "stvangaal" ]; then pass RL-37; else fail_case RL-37 "out=[$cu_out]"; fi

CUF_BIN="$FIX/.cuf-bin"; mkdir -p "$CUF_BIN"
cat > "$CUF_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
exit 1
GH
chmod +x "$CUF_BIN/gh"
if PATH="$CUF_BIN:$PATH" inlib roadmap_current_user >/dev/null 2>&1; then
  fail_case "RL-37 (unauth should fail)"
else
  pass "RL-37 (unauth → non-zero)"
fi

# RL-39 — epic_list delegates to gh issue list filtered to open type:epic and
# returns [{number,title}]. Uses a dedicated stub so the shaped query is pinned.
EPIC_BIN="$FIX/.epic-bin"; mkdir -p "$EPIC_BIN"
cat > "$EPIC_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
if [ "$1 $2" = "issue list" ]; then
  printf '[{"number":516,"title":"Epic: Pipeline Slipstream"}]'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
GH
chmod +x "$EPIC_BIN/gh"
: > "$GH_STUB_LOG"
epic_out=$(PATH="$EPIC_BIN:$PATH" inlib roadmap_tracker_epic_list)
if [ "$epic_out" = '[{"number":516,"title":"Epic: Pipeline Slipstream"}]' ]    && grep -q 'issue list --label type:epic --state open --json number,title --limit 200' "$GH_STUB_LOG"; then
  pass RL-39
else
  fail_case RL-39 "out=[$epic_out] log=$(cat "$GH_STUB_LOG" 2>/dev/null)"
fi

# RL-39b — epic_list degrades to [] on azure-devops without ever calling the
# tracker. Reuse the sibling ADO az stub ($AZ_BIN) so roadmap_require_backend
# passes its guard; the ADO branch only printf '[]' and never invokes az.
ado_epic_out=$(PATH="$AZ_BIN:$PATH" ROADMAP_BACKEND=azure-devops inlib roadmap_tracker_epic_list)
if [ "$ado_epic_out" = '[]' ]; then pass RL-39b; else fail_case RL-39b "got=[$ado_epic_out]"; fi

# RL-39c — epic_list scrubs control chars from author-controlled epic titles
# at the source (titles feed Claude context in later /idea-reframe slices).
# The stub emits \u0007 as a JSON unicode escape (matching real gh API output).
# Without scrubbing, the passthrough preserves the \u0007 escape in output.
# With scrubbing, python decodes and strips the bell; visible text must remain.
SCRUB_BIN="$FIX/.scrub-epic-bin"; mkdir -p "$SCRUB_BIN"
cat > "$SCRUB_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
if [ "$1 $2" = "issue list" ]; then
  printf '[{"number":516,"title":"Epic:\\u0007 Slipstream"}]'
  exit 0
fi
exit 2
GH
chmod +x "$SCRUB_BIN/gh"
scrub_out=$(PATH="$SCRUB_BIN:$PATH" inlib roadmap_tracker_epic_list)
# \u0007 JSON unicode escape must be absent from output (scrub decoded and removed it);
# visible text must remain. Use $'\\u0007' (ANSI-C quoting) for the literal 6-char
# escape sequence, since bash 5.x interprets '\u0007' as a BEL byte.
_scrub_escape_pat=$'\\u0007'
if printf '%s' "$scrub_out" | grep -qF "$_scrub_escape_pat"; then
  fail_case RL-39c "control char unicode escape survived in output: [$scrub_out]"
elif printf '%s' "$scrub_out" | grep -q 'Epic: Slipstream'; then
  pass RL-39c
else
  fail_case RL-39c "unexpected output: [$scrub_out]"
fi

# RL-40 — link_subissue (GitHub): resolve child database id, POST it to the
# parent's sub_issues collection. Gated on sub_issues_enabled=true.
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
sub_issues_enabled: true
YAML
LINK_BIN="$FIX/.link-bin"; mkdir -p "$LINK_BIN"
cat > "$LINK_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "$*" in
  "api repos/{owner}/{repo}/issues/748 --jq .id") printf '4649261078'; exit 0 ;;
esac
case "$1 $2" in
  "api -X") exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 2
GH
chmod +x "$LINK_BIN/gh"
: > "$GH_STUB_LOG"
PATH="$LINK_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue 516 748
rc=$?
if [ "$rc" = 0 ] \
   && grep -q 'api repos/{owner}/{repo}/issues/748 --jq .id' "$GH_STUB_LOG" \
   && grep -q 'api -X POST repos/{owner}/{repo}/issues/516/sub_issues -F sub_issue_id=4649261078' "$GH_STUB_LOG"; then
  pass RL-40
else
  fail_case RL-40 "rc=$rc log=$(cat "$GH_STUB_LOG" 2>/dev/null)"
fi

# RL-40b — Azure DevOps unsupported for the writer (nonzero + stderr note).
# AZ_BIN must be on PATH so roadmap_require_backend passes and we reach the
# azure-devops) case that emits the "not supported" diagnostic.
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
sub_issues_enabled: true
YAML
err40b=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue 516 748 2>&1 >/dev/null)
rc=$?
if [ "$rc" != 0 ] && printf '%s' "$err40b" | grep -qi 'not supported'; then
  pass RL-40b
else
  fail_case RL-40b "rc=$rc err=[$err40b]"
fi

# RL-40c — gate: sub_issues_enabled not true → soft no-op (return 0, no POST).
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
sub_issues_enabled: false
YAML
: > "$GH_STUB_LOG"
PATH="$LINK_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue 516 748 2>/dev/null
rc=$?
if [ "$rc" = 0 ] && ! grep -q 'sub_issues' "$GH_STUB_LOG"; then
  pass RL-40c
else
  fail_case RL-40c "rc=$rc log=$(cat "$GH_STUB_LOG" 2>/dev/null)"
fi

# RL-40d — argument guard: missing child → return 2, no tracker call.
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: github
sub_issues_enabled: true
YAML
: > "$GH_STUB_LOG"
PATH="$LINK_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue 516 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && [ ! -s "$GH_STUB_LOG" ]; then
  pass RL-40d
else
  fail_case RL-40d "rc=$rc log=$(cat "$GH_STUB_LOG" 2>/dev/null)"
fi

# RL-40e — argument guard: missing parent → return 2, no tracker call.
: > "$GH_STUB_LOG"
PATH="$LINK_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue "" 748 2>/dev/null
rc=$?
if [ "$rc" = 2 ] && [ ! -s "$GH_STUB_LOG" ]; then
  pass RL-40e
else
  fail_case RL-40e "rc=$rc log=$(cat "$GH_STUB_LOG" 2>/dev/null)"
fi

# RL-40f — gate precedence on ADO: sub_issues_enabled false soft-no-ops on
# azure-devops too (return 0), never reaching the "not supported" diagnostic.
# Pins the gate-before-backend ordering for the ADO path (RL-40c covers github).
cat > "$FIX/roadmap.config.yaml" <<'YAML'
backend: azure-devops
sub_issues_enabled: false
YAML
err40f=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_link_subissue 516 748 2>&1 >/dev/null)
rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$err40f" | grep -qi 'not supported'; then
  pass RL-40f
else
  fail_case RL-40f "rc=$rc err=[$err40f]"
fi

[ "$fail" = 0 ] && echo "roadmap-lib contract: ALL PASS" || exit 1
