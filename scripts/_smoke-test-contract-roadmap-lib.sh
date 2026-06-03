#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-lib.sh — Contract test for
# docs/contracts/roadmap-lib.contract.md. Asserts RL-1..RL-9 against
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

# RL-5 — list getter: block style, flow style, and yq-failure fallback.
# Hide yq for the first two cases so the portable python3 path is asserted on
# every platform, then install a fake failing yq to pin fallback behaviour when
# a runner has a yq binary that rejects the expression dialect.
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

list_block=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',' )
[ "$list_block" = "skills,workflows,hooks," ] && pass "RL-5 (block)" || fail_case "RL-5 (block)" "got=[$list_block]"
# flow style
cat > "$FIX/roadmap.config.yaml" <<'YAML'
component_values: [skills, workflows, hooks]
YAML
list_flow=$(inlib_noyq roadmap_config_list component_values | tr '\n' ',')
[ "$list_flow" = "skills,workflows,hooks," ] && pass "RL-5 (flow)" || fail_case "RL-5 (flow)" "got=[$list_flow]"
YQFAIL_BIN="$FIX/.yqfail-bin"; mkdir -p "$YQFAIL_BIN"
cat > "$YQFAIL_BIN/yq" <<'YQ'
#!/usr/bin/env bash
echo "fake yq parser failure" >&2
exit 2
YQ
chmod +x "$YQFAIL_BIN/yq"
# shellcheck source=scripts/roadmap/lib.sh
inlib_yqfail() { ( cd "$FIX" && PATH="$YQFAIL_BIN:$PATH" && source "$LIB" && "$@" ); }
list_yqfail=$(inlib_yqfail roadmap_config_list component_values | tr '\n' ',')
[ "$list_yqfail" = "skills,workflows,hooks," ] && pass "RL-5 (yq failure fallback)" || fail_case "RL-5 (yq failure fallback)" "got=[$list_yqfail]"

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

ado_created=$(PATH="$AZ_BIN:$PATH" inlib roadmap_tracker_issue_create --title "Captured idea" --label "horizon:later,component:skills" --body "Body")
if printf '%s' "$ado_created" | jq -e '.number == 77 and (.labels | map(.name) | index("component:skills"))' >/dev/null \
   && grep -q 'boards work-item create --title Captured idea --type Issue' "$AZ_STUB_LOG"; then
  pass RL-17
else
  fail_case RL-17 "out=[$ado_created] log=$(cat "$AZ_STUB_LOG" 2>/dev/null)"
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

[ "$fail" = 0 ] && echo "roadmap-lib contract: ALL PASS" || exit 1
